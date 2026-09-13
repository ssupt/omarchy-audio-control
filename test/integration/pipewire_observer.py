"""Independent, read-only volume observations from a private PipeWire server."""
from collections import deque
import codecs
import json
import os
import subprocess
import threading
import time


class VolumeObserver:
    def __init__(self, env, node_id, log):
        self.node_id = node_id
        self.events = deque(maxlen=4096)
        self.condition = threading.Condition()
        self.error = None
        self.stopping = False
        self.process = subprocess.Popen(
            ['pw-dump', '--monitor', '--no-colors', str(node_id)],
            env=env, stdout=subprocess.PIPE, stderr=log)
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self):
        decoder = json.JSONDecoder()
        utf8 = codecs.getincrementaldecoder('utf-8')()
        pending = ''
        clock_offset = time.time_ns() - time.monotonic_ns()
        try:
            while chunk := os.read(self.process.stdout.fileno(), 65536):
                observed_ns = time.time_ns()
                monotonic_ns = time.monotonic_ns()
                # Date.now() in the QML fixture uses the same host realtime clock.
                # Reject clock steps rather than reporting misleading durations.
                if abs(observed_ns - monotonic_ns - clock_offset) > 5_000_000:
                    raise AssertionError('Wall clock changed during volume observations')
                pending += utf8.decode(chunk)
                if len(pending) > 8 * 1024 * 1024:
                    raise AssertionError('PipeWire monitor frame exceeded 8 MiB')
                while pending.strip():
                    pending = pending.lstrip()
                    try:
                        batch, end = decoder.raw_decode(pending)
                    except json.JSONDecodeError:
                        break
                    pending = pending[end:]
                    for item in batch:
                        if item.get('id') != self.node_id:
                            continue
                        info = item.get('info')
                        if info is None:
                            raise AssertionError('Observed dummy sink disappeared')
                        for props in info.get('params', {}).get('Props', []):
                            channels = props.get('channelVolumes')
                            if channels:
                                event = {'observedAtMs': observed_ns // 1_000_000,
                                         'monotonicNs': monotonic_ns,
                                         'channelVolumes': channels}
                                with self.condition:
                                    self.events.append(event)
                                    self.condition.notify_all()
            if not self.stopping:
                raise AssertionError('PipeWire monitor exited unexpectedly')
        except Exception as error:
            with self.condition:
                self.error = error
                self.condition.notify_all()

    def wait(self, predicate, timeout=3):
        deadline = time.monotonic() + timeout
        with self.condition:
            while True:
                if self.error:
                    raise self.error
                for event in self.events:
                    if predicate(event):
                        return event
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError('No matching independent PipeWire volume observation')
                self.condition.wait(remaining)

    def level(self, volume, after_ns, timeout=3):
        # The UI exposes perceptual volume; SPA channel volumes are its cube.
        return self.wait(lambda event: event['monotonicNs'] > after_ns
                         and len(event['channelVolumes']) == 2
                         and all(abs(channel - volume ** 3) < 0.00001
                                 for channel in event['channelVolumes']), timeout)

    def close(self):
        self.stopping = True
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=3)
        self.thread.join(timeout=3)
        self.process.stdout.close()
