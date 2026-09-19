#!/usr/bin/env python3
"""Native diagnostic samples, bounded commands and independent audio controls."""
from contextlib import ExitStack
import json
import os
import shutil
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
               PULSE_SERVER='unix:'+str(work/'pulse/native'),
               DBUS_SESSION_BUS_ADDRESS='unix:path='+str(work/'unused-bus'),
               DBUS_SYSTEM_BUS_ADDRESS='unix:path='+str(work/'unused-bus'))
    gate, calls, mode = (work/name for name in ('gate', 'calls', 'mode'))
    commands = work/'commands'
    commands.mkdir()
    real_top = shutil.which('pw-top')
    (commands/'pw-top').write_text('''#!/usr/bin/env python3
import os, pathlib, sys, time
work = pathlib.Path(os.environ['AUDIO_DIAGNOSTICS_TEST_DIR'])
with (work/'calls').open('a') as out: out.write('sample\\n')
while (work/'gate').exists(): time.sleep(.025)
mode = (work/'mode').read_text() if (work/'mode').exists() else ''
if mode == 'oversize':
    print('x' * (1024 * 1024 + 1))
    raise SystemExit(0)
if mode == 'malformed':
    print('invalid statistics')
    raise SystemExit(0)
if mode == 'slow': time.sleep(30)
import subprocess
result = subprocess.run([os.environ['AUDIO_DIAGNOSTICS_REAL_TOP'], *sys.argv[1:]], capture_output=True)
(work/'top-output').write_bytes(result.stdout)
sys.stdout.buffer.write(result.stdout)
raise SystemExit(result.returncode)
''')
    (commands/'wl-copy').write_text('''#!/usr/bin/env python3
import os, pathlib, sys
pathlib.Path(os.environ['AUDIO_DIAGNOSTICS_TEST_DIR'], 'clipboard').write_bytes(sys.stdin.buffer.read())
''')
    for command in commands.iterdir(): command.chmod(0o755)
    env.update(PATH=str(commands)+':'+env['PATH'], AUDIO_DIAGNOSTICS_TEST_DIR=temporary,
               AUDIO_DIAGNOSTICS_REAL_TOP=real_top)

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
        config = work/'pipewire.conf'
        config.write_text((ROOT/'test/fixtures/pipewire.conf').read_text().replace(
            'context.modules = [', 'context.modules = [\n    { name = libpipewire-module-profiler }'))
        launch(['pipewire', '-c', str(config)])
        until(lambda: (work/'audio-test').exists())
        pulse = launch(['pipewire-pulse'])
        until(lambda: (work/'pulse/native').exists())
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
        assert snapshot['versions']['pipewire']
        assert snapshot['versions']['plugin'] == json.loads((ROOT/'packaging/manifest.json').read_text())['version']
        assert snapshot['capabilities']['topology']
        assert any(d['name'] == 'audio_test_output' and d['channels'] == 2 for d in snapshot['devices']), snapshot
        assert any(d['name'] == 'audio_test_input' for d in snapshot['devices'])
        assert not any(d['name'].endswith('.monitor') for d in snapshot['devices'])
        assert not (work/'clipboard').exists(), 'Collection copied private data without an explicit action'
        assert control.request('diagnostics.refresh') == {'cached': True}
        assert count() == 1
        print('PASS: native formats and graph, shared samples and independent audio controls', flush=True)
        assert control.request('diagnostics.copy') == {'copied': True}
        report = (work/'clipboard').read_text()
        assert report.startswith('Advanced Audio Control support report')
        assert 'audio_test_output' not in report and 'audio_test_input' not in report
        assert count() == 1, 'Copy ignored the fresh shared sample'

        for revision, failure_mode in enumerate(('malformed', 'oversize', 'slow'), 2):
            mode.write_text(failure_mode)
            expire()
            before = time.monotonic()
            a.request('diagnostics.refresh')
            report = phase(revision)
            assert time.monotonic() - before < 4, 'Failed sampler exceeded its deadline'
            assert not report['error'] and report['snapshot']['devices'] == snapshot['devices']
            assert not report['snapshot']['healthy']
            assert 'Live PipeWire processing statistics could not be read.' in report['snapshot']['warnings']
            assert report['snapshot']['graph']['loadPercent'] == -1
            assert control.request('diagnostics.refresh') == {'cached': True}
            assert count() == revision, 'A failed command caused a retry storm'
            control.request('node.level', dict(identity=identity, volume=.41))
            assert control.request('health')['audioConnected']
        print('PASS: malformed, oversized and stalled commands preserve native data and remain bounded', flush=True)

        mode.unlink()
        expire()
        a.request('diagnostics.refresh')
        report = phase(5)
        assert not report['error']
        assert 'Live PipeWire processing statistics could not be read.' not in report['snapshot']['warnings'], (work/'top-output').read_text()
        before = count()
        expire()
        assert count() == before, 'Sampling continued without a request'
        for params in ({'force': True}, {'command': 'copy-report'}):
            assert control.response(control.send('diagnostics.refresh', params))['error']['code'] == 'invalid_params'
            assert control.response(control.send('diagnostics.copy', params))['error']['code'] == 'invalid_params'
        for action in ('snapshot', 'report', 'copy-report'):
            failure = control.response(control.send('adapter.run', dict(helper='audio-diagnostics', args=[action])))
            assert 'error' in failure, failure
        assert count() == before
        print('PASS: later reads recover; idle subscriptions never sample or invoke clipboard actions', flush=True)
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read()[-10000:], file=sys.stderr)
        raise
