#!/usr/bin/env python3
"""Exercise the shipped backend through its real shell-owned stdio relay."""
import fcntl
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time

BINARY = Path(sys.argv[1]).resolve()
PREVIOUS = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None


def until(predicate, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.025)
    raise AssertionError('Lifecycle condition exceeded its deadline')


class Relay:
    def __init__(self, binary, env):
        self.process = subprocess.Popen([str(binary), '--plugin'], env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.buffer = b''
        self.sequence = 0
        self.replies = {}
        self.info = self.request('hello')

    def send(self, method, params=None):
        self.sequence += 1
        identity = str(self.sequence)
        data = dict(version=1, id=identity, method=method, params=params or {})
        self.process.stdin.write((json.dumps(data)+'\n').encode())
        self.process.stdin.flush()
        return identity

    def response(self, identity):
        deadline = time.monotonic() + 8
        while identity not in self.replies:
            while b'\n' not in self.buffer:
                left = deadline-time.monotonic()
                assert left > 0 and select.select([self.process.stdout], [], [], left)[0], 'Relay response timed out'
                chunk = os.read(self.process.stdout.fileno(), 8192)
                if not chunk:
                    self.process.wait(timeout=3)
                    raise AssertionError('Relay closed before responding: '
                                         + self.process.stderr.read(4096).decode(errors='replace'))
                self.buffer += chunk
                assert len(self.buffer) < 262144
            line, self.buffer = self.buffer.split(b'\n', 1)
            message = json.loads(line)
            if 'id' in message:
                self.replies[message['id']] = message
        result = self.replies.pop(identity)
        assert 'result' in result, result
        return result['result']

    def request(self, method, params=None):
        return self.response(self.send(method, params))

    def close(self):
        if not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.wait(timeout=3)
        self.process.stdout.close()
        self.process.stderr.close()


with tempfile.TemporaryDirectory(prefix='audio-lifecycle-') as temporary:
    work = Path(temporary)
    plugin = work/'plugin with spaces'
    plugin.mkdir()
    executable = plugin/'omarchy-audio-service'
    shutil.copy2(BINARY, executable)
    commands = work/'commands'
    commands.mkdir()
    availability = commands/'omarchy-audio-sink-availability'
    availability.write_text('#!/bin/bash\nprintf "test-output\\t1\\n"\n')
    availability.chmod(0o755)
    env = dict(os.environ, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
               PIPEWIRE_REMOTE='absent-test-server', PULSE_SERVER='unix:'+str(work/'absent-pulse'),
               XDG_CONFIG_HOME=str(work/'config'), XDG_STATE_HOME=str(work/'state'),
               XDG_CACHE_HOME=str(work/'cache'), AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary,
               PATH=str(commands)+os.pathsep+os.environ['PATH'])
    for key in ('OMARCHY_AUDIO_HELPERS_DIR', 'OMARCHY_AUDIO_CONTROL_FILE', 'OMARCHY_AUDIO_PREFERENCES_FILE',
                'OMARCHY_AUDIO_RULES_FILE', 'OMARCHY_AUDIO_SCENES_FILE', 'LISTEN_PID', 'LISTEN_FDS'):
        env.pop(key, None)
    config = work/'config/omarchy'
    config.mkdir(parents=True)
    preferences = config/'audio-preferences.json'
    original = '{"version":1,"bluetoothProfilePreference":"quality","externalField":"preserve"}\n'
    preferences.write_text(original)
    relays = []
    daemons = {}
    try:
        # A listening socket may accept a connection while its daemon is
        # shutting down. Connecting alone does not establish a usable session.
        build = json.loads(subprocess.check_output([str(executable), '--build-info']))
        socket_dir = work/'omarchy-audio-control'
        socket_dir.mkdir(mode=0o700)
        stale = socket.socket(socket.AF_UNIX)
        stale.bind(str(socket_dir/('backend-'+build['buildId'][:24]+'.sock')))
        stale.listen()
        def close_during_startup():
            stale.settimeout(8)
            try:
                connection, _ = stale.accept()
                with connection:
                    connection.settimeout(8)
                    assert connection.recv(8192)
            finally:
                stale.close()
        with ThreadPoolExecutor(max_workers=1) as pool:
            closing = pool.submit(close_during_startup)
            recovered = Relay(executable, env)
            relays.append(recovered)
            daemons[recovered.info['pid']] = os.pidfd_open(recovered.info['pid'])
            closing.result()
        recovered.close()
        previous = None
        if PREVIOUS:
            previous = Relay(PREVIOUS, env)
            relays.append(previous)
            daemons[previous.info['pid']] = os.pidfd_open(previous.info['pid'])
            previous.request('devices.alias', dict(node='upgrade-device', label='Existing alias'))
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(Relay, executable, env)
            second = pool.submit(Relay, executable, env)
            a, b = first.result(), second.result()
        relays.extend((a, b))
        daemons[a.info['pid']] = os.pidfd_open(a.info['pid'])
        if previous:
            assert previous.info['buildId'] != a.info['buildId'], 'Upgrade test requires two different builds'
            assert previous.info['pid'] != a.info['pid'], 'New release attached to the old executable'
            a.request('settings.set', dict(key='outputOverdrive', value=False))
            assert json.loads((config/'audio-rules.json').read_text())['devices']['aliases']['upgrade-device'] == 'Existing alias'
            previous.close()
        assert a.info['epoch'] == b.info['epoch'], 'Two plugin views started independent coordinators'
        assert preferences.read_text() == original, 'Starting the plugin rewrote a companion document'
        assert a.request('health')['status'] == 'ok'
        a.close()
        c = Relay(executable, env); relays.append(c)
        assert c.info['epoch'] == b.info['epoch'], 'A UI reload replaced the live coordinator'
        signal.pidfd_send_signal(daemons[b.info['pid']], signal.SIGKILL)
        b.process.wait(timeout=3)
        c.process.wait(timeout=3)
        d = Relay(executable, env); relays.append(d)
        daemons[d.info['pid']] = os.pidfd_open(d.info['pid'])
        assert d.info['epoch'] != b.info['epoch'], 'A restarted daemon reused its session epoch'
        assert preferences.read_text() == original
        # Once admitted, a write must finish after the relay is destroyed.
        settings = config/'audio-control.json'
        with (config/'audio-control.json.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            d.send('settings.set', dict(key='outputOverdrive', value=True))
            assert d.request('health')['status'] == 'ok'
            d.close()
            fcntl.flock(lock, fcntl.LOCK_UN)
        until(lambda: settings.exists() and json.loads(settings.read_text()).get('outputOverdrive') is True)
        e = Relay(executable, env); relays.append(e)
        assert e.info['epoch'] == d.info['epoch']
        shutil.rmtree(plugin)
        # The checkout can disappear during removal/update. Embedded helpers
        # and already accepted work remain available to the draining daemon.
        result = e.request('adapter.run', dict(helper='audio-sink-availability', args=[]))
        assert result['exitCode'] == 0, result
        e.close()
        socket_path = work/'omarchy-audio-control'/('backend-'+e.info['buildId'][:24]+'.sock')
        until(lambda: not socket_path.exists(), timeout=36)
        assert preferences.read_text() == original
        assert json.loads(settings.read_text())['outputOverdrive'] is True
        if previous:
            old_socket = work/'omarchy-audio-control'/('backend-'+previous.info['buildId'][:24]+'.sock')
            until(lambda: not old_socket.exists(), timeout=8)
            print('PASS: different release builds use separate daemons, retain settings, and retire the previous daemon')
        print('PASS: startup handshake, shared daemon, UI reload, crash recovery, admitted-write drain, removal, idle exit, and existing preferences')
    finally:
        for relay in relays:
            if relay.process.poll() is None:
                relay.process.terminate()
                relay.process.wait(timeout=3)
            for stream in (relay.process.stdin, relay.process.stdout, relay.process.stderr):
                if not stream.closed:
                    stream.close()
        for descriptor in daemons.values():
            try: signal.pidfd_send_signal(descriptor, signal.SIGTERM)
            except ProcessLookupError: pass
            finally: os.close(descriptor)
