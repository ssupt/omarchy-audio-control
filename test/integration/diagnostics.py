#!/usr/bin/env python3
"""Shared diagnostic reads, helper parity and failure isolation on private audio."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from client import Client

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(sys.argv[1]).resolve()


def until(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.025)
    raise AssertionError('Diagnostics condition exceeded its deadline')


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
            raise AssertionError('Private diagnostics process did not stop cleanly')


with tempfile.TemporaryDirectory(prefix='audio-diagnostics-') as temporary, ExitStack() as cleanup:
    work = Path(temporary)
    log = cleanup.enter_context((work/'runtime.log').open('w+'))
    env = {key: os.environ[key] for key in ('PATH', 'LANG') if key in os.environ}
    env.update(HOME=temporary, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
               PIPEWIRE_REMOTE='audio-test', XDG_CONFIG_HOME=str(work/'config'),
               XDG_STATE_HOME=str(work/'state'), XDG_CACHE_HOME=str(work/'cache'),
               AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary,
               PULSE_SERVER='unix:'+str(work/'unused-pulse'),
               DBUS_SESSION_BUS_ADDRESS='unix:path='+str(work/'unused-bus'),
               DBUS_SYSTEM_BUS_ADDRESS='unix:path='+str(work/'unused-bus'),
               AUDIO_CONTROL_DIAGNOSTICS_FIXTURE_DIR=str(ROOT/'test/fixtures/diagnostics'))
    gate, calls, response = (work/name for name in ('gate', 'calls', 'response'))
    hook = work/'bash-env'
    hook.write_text('''case "$0" in */audio-diagnostics)
  printf 'sample\\n' >>"$AUDIO_DIAGNOSTICS_TEST_DIR/calls"
  while test -e "$AUDIO_DIAGNOSTICS_TEST_DIR/gate"; do sleep .025; done
  if test -e "$AUDIO_DIAGNOSTICS_TEST_DIR/response"; then
    cat "$AUDIO_DIAGNOSTICS_TEST_DIR/response"
    exit 0
  fi
esac
''')
    env.update(BASH_ENV=str(hook), AUDIO_DIAGNOSTICS_TEST_DIR=temporary)

    def launch(command):
        process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        cleanup.callback(stop, process)
        return process

    def client(path):
        value = Client(path)
        cleanup.callback(value.close)
        return value

    def count():
        return len(calls.read_text().splitlines()) if calls.exists() else 0

    def phase(revision):
        state = observer.wait_state(lambda s: s.get('diagnostics', {}).get('revision') == str(revision)
                                    and not s['diagnostics']['refreshing'])
        return state['diagnostics']

    def expire():
        # Drain the subscription while waiting for the sample's five-second TTL.
        # A slow/non-reading client must not be mistaken for a sampler failure.
        deadline = time.monotonic() + 5.1
        while time.monotonic() < deadline:
            observer.request('health')
            time.sleep(.1)

    try:
        # Exercise the actual embedded helper. The hook only adds a deterministic
        # barrier/counter until later failure cases supply an explicit response.
        expected = json.loads(subprocess.check_output(
            ['/bin/bash', str(ROOT/'scripts/audio-diagnostics'), 'snapshot'],
            env=env, text=True, stderr=log, timeout=30))
        expected['versions']['plugin'] = json.loads((ROOT/'packaging/manifest.json').read_text())['version']
        calls.unlink()
        launch(['pipewire', '-c', str(ROOT/'test/fixtures/pipewire.conf')])
        until(lambda: (work/'audio-test').exists())
        launch([str(BINARY)])
        socket = work/'omarchy-audio-control/backend.sock'
        until(socket.exists)
        observer, a, b, control = (client(socket) for _ in range(4))
        observer.request('state.subscribe')
        state = observer.wait_state(lambda s: s.get('graphReady'))
        sink = next(n for n in state['nodes'] if n['name'] == 'audio_test_output')
        identity = dict(generation=state['generation'], id=sink['id'], serial=sink['serial'])
        assert count() == 0, 'Diagnostics sampled without a request'
        gate.touch()
        first = a.send('diagnostics.refresh')
        until(lambda: count() == 1)
        second = b.send('diagnostics.refresh')
        state = observer.wait_state(lambda s: s.get('diagnostics', {}).get('refreshing'))
        assert not state['busy'], 'Read-only sampling claimed audio mutation ownership'
        before = time.monotonic()
        control.request('node.level', dict(identity=identity, volume=.43))
        control.request('health')
        assert time.monotonic() - before < 1, 'Sampling blocked native controls'
        source = next(n for n in state['nodes'] if n['name'] == 'audio_test_input')
        before = time.monotonic()
        control.request('microphone.start', dict(owner='diagnostics-test', record=True,
            identity=dict(generation=state['generation'], id=source['id'], serial=source['serial'])))
        control.request('microphone.stop', dict(owner='diagnostics-test', discard=True))
        observer.wait_state(lambda s: s.get('microphone', {}).get('state') == 'idle')
        assert time.monotonic() - before < 1, 'Sampling blocked microphone admission or cancellation'
        assert gate.exists() and count() == 1
        gate.unlink()
        assert a.response(first)['result'] == {'cached': False}
        assert b.response(second)['result'] == {'cached': True}
        report = phase(1)
        snapshot = report['snapshot']
        assert not report['error']
        assert {k: v for k, v in snapshot.items() if k != 'generatedAt'} == {
            k: v for k, v in expected.items() if k != 'generatedAt'}
        assert control.request('diagnostics.refresh') == {'cached': True}
        assert count() == 1
        print('PASS: embedded helper parity, concurrent sample sharing and independent audio controls', flush=True)

        # The diagnostic report can exceed one protocol frame. The normal state
        # subscription must deliver it intact without disconnecting controls.
        large = dict(expected, warnings=['Synthetic report 🧪 ' * 20000])
        response.write_text(json.dumps(large))
        expire()
        a.request('diagnostics.refresh')
        snapshot = phase(2)['snapshot']
        assert snapshot == large and len(json.dumps(snapshot)) > 262144
        assert count() == 2
        print('PASS: a report larger than one frame arrives through bounded snapshot chunks', flush=True)

        for revision, raw, code in (
            (3, '{broken', 'invalid_diagnostics'),
            (4, json.dumps(dict(expected, warnings=['x' * (2 * 1024 * 1024)])), 'diagnostics_too_large'),
            (5, 'x' * (8 * 1024 * 1024 + 1), 'diagnostics_failed'),
        ):
            response.write_text(raw)
            expire()
            before = count()
            failure = a.response(a.send('diagnostics.refresh'))
            assert failure['error']['code'] == code and failure['error']['outcome'] == 'rejected', failure
            report = phase(revision)
            assert report['snapshot'] == snapshot and report['error']
            assert b.response(b.send('diagnostics.refresh'))['error'] == failure['error']
            assert count() == before + 1, 'A failed sample caused a retry storm'
            control.request('node.level', dict(identity=identity, volume=.41))
            assert control.request('health')['audioConnected']
        print('PASS: malformed and oversized reports preserve the last sample and working controls', flush=True)

        response.unlink()
        expire()
        a.request('diagnostics.refresh')
        report = phase(6)
        assert not report['error'] and report['snapshot']['warnings'] == expected['warnings']
        before = count()
        expire()
        assert count() == before, 'Sampling continued after clients stopped requesting it'
        for params in ({'force': True}, {'command': 'copy-report'}):
            assert control.response(control.send('diagnostics.refresh', params))['error']['code'] == 'invalid_params'
        for action in ('snapshot', 'report', 'copy-report'):
            failure = control.response(control.send('adapter.run', dict(helper='audio-diagnostics', args=[action])))
            assert 'error' in failure, failure
        assert count() == before
        print('PASS: later reads recover; idle subscriptions never sample or invoke diagnostic actions', flush=True)
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read()[-10000:], file=sys.stderr)
        raise
