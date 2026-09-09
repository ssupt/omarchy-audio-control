#!/usr/bin/env python3
"""Real recorder/player cancellation on private dummy audio, without hardware."""
from contextlib import ExitStack
import json
import os
from pathlib import Path
import select
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
    raise AssertionError('Microphone condition exceeded its deadline')


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
            raise AssertionError('Private process did not stop cleanly')


with tempfile.TemporaryDirectory(prefix='audio-microphone-') as temporary:
    work = Path(temporary)
    # Only the installed policy profile runs: no hardware monitors, inherited
    # audio/store overrides, desktop bus, or D-Bus service activation directories.
    env = {key: os.environ[key] for key in ('PATH', 'LANG') if key in os.environ}
    env.update(HOME=temporary, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
               PIPEWIRE_REMOTE='audio-test', XDG_CONFIG_HOME=str(work/'config'),
               XDG_STATE_HOME=str(work/'state'), XDG_CACHE_HOME=str(work/'cache'),
               AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary,
               PULSE_SERVER='unix:'+str(work/'unused-pulse'),
               DBUS_SESSION_BUS_ADDRESS='unix:path='+str(work/'bus'),
               DBUS_SYSTEM_BUS_ADDRESS='unix:path='+str(work/'bus'),
               WIREPLUMBER_CONFIG_DIR='/usr/share/wireplumber')
    bus = work/'bus.conf'
    bus.write_text('<busconfig><type>session</type><listen>unix:path='+str(work/'bus')+'</listen>'
                   '<auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/>'
                   '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
    config = work/'pipewire.conf'
    # WirePlumber supplies default metadata. The native-only fixture's inert
    # source becomes a synthetic tone generator so this test transfers samples.
    config.write_text((ROOT/'test/fixtures/pipewire.conf').read_text().replace(
        '    { factory = metadata args = { metadata.name = default } }\n', '').replace(
        'context.spa-libs = {', 'context.spa-libs = {\n    audiotestsrc = audiotestsrc/libspa-audiotestsrc').replace(
        'factory.name = support.null-audio-sink\n        node.name = audio_test_input',
        'factory.name = audiotestsrc\n        node.name = audio_test_input'))
    cleanup = ExitStack()
    log = cleanup.enter_context((work/'runtime.log').open('w+'))

    def launch(command):
        process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        cleanup.callback(stop, process)
        return process

    def run(*command):
        return subprocess.check_output(command, env=env, text=True, stderr=log, timeout=5)

    def graph():
        return json.loads(run('pw-dump'))

    def nodes():
        result = [item for item in graph() if item['type'] == 'PipeWire:Interface:Node']
        assert all(item['info']['props'].get('node.name', '').startswith(
            ('audio_test_', 'Audio-Test-', 'omarchy_audio_test')) for item in result), result
        return result

    def test_stream(direction):
        return next((item for item in nodes()
                     if item['info']['props'].get('application.id') == 'ssupt.audio-control'
                     and item['info']['props'].get('media.class') == 'Stream/'+direction+'/Audio'
                     and item['info']['state'] == 'running'), None)

    def recreate_source():
        run('pw-cli', 'create-node', 'adapter',
            '{ factory.name = audiotestsrc node.name = audio_test_input '
            'node.description = "Audio Test Input" media.class = Audio/Source '
            'audio.position = [ MONO ] object.linger = true '
            'adapter.auto-port-config = { mode = dsp monitor = true position = preserve } }')

    def identity(name='audio_test_input', previous=None):
        state = observer.wait_state(lambda s: s.get('graphReady') and any(
            n['name'] == name and n['serial'] != previous and n['audio']['muted'] is False
            for n in s['nodes']))
        node = next(n for n in state['nodes'] if n['name'] == name)
        return dict(generation=state['generation'], id=node['id'], serial=node['serial'])

    def start_recording(source):
        control.request('microphone.start', dict(owner='private-test', record=True, identity=source))
        observer.wait_state(lambda s: s.get('microphone', {}).get('state') == 'recording')
        stream = until(lambda: test_stream('Input'))
        links = [item['info'] for item in graph() if item['type'] == 'PipeWire:Interface:Link']
        assert any(link['output-node-id'] == source['id'] and link['input-node-id'] == stream['id']
                   and link['state'] == 'active' for link in links), links
        peer = next(item for item in graph() if item['id'] == stream['info']['props']['client.id'])
        pid = int(peer['info']['props']['application.process.id'])
        assert f'PPid:\t{backend.pid}\n' in Path(f'/proc/{pid}/status').read_text()
        return os.pidfd_open(pid)

    def stopped(recorder, changed_at=None):
        try:
            assert select.select([recorder], [], [], 2)[0], 'Recorder survived cancellation'
            if changed_at is not None:
                assert time.monotonic() - changed_at < 3, 'Capture cancellation took over three seconds'
        finally:
            os.close(recorder)

    def discarded(connected=True):
        state = observer.wait_state(lambda s: s.get('microphone', {}).get('state') == 'idle')
        def clip_is_gone():
            reply = control.response(control.send('microphone.start', dict(owner='private-test', record=False)))
            # The final snapshot can arrive before cancellation drops its lock.
            # Retry only rejected admission; an accepted playback still fails.
            if reply.get('error', {}).get('code') == 'busy': return False
            assert reply.get('error', {}).get('code') == 'no_clip', reply
            return True
        until(clip_is_gone, timeout=2)
        if connected:
            assert not any(n['info']['props'].get('application.id') == 'ssupt.audio-control' for n in nodes())
        else:
            observer.wait_state(lambda s: not s['connected'])
        return state

    try:
        launch(['dbus-daemon', '--nofork', '--config-file='+str(bus)])
        until(lambda: (work/'bus').exists())
        pipewire = launch(['pipewire', '-c', str(config)])
        until(lambda: (work/'audio-test').exists())
        launch(['wireplumber', '--profile', 'policy'])
        # pw-dump omits empty metadata objects; inspect the registry here.
        until(lambda: 'metadata.name = "default"' in run('pw-cli', 'ls', 'Metadata'))
        for direction, name in (('sink', 'audio_test_output'), ('source', 'audio_test_input')):
            run('pw-metadata', '-n', 'default', '0', 'default.audio.'+direction,
                json.dumps(dict(name=name)), 'Spa:String:JSON')
        assert len(nodes()) == 4
        backend = launch([str(BINARY)])
        path = work/'omarchy-audio-control/backend.sock'
        until(path.exists)
        observer, control = Client(path), Client(path)
        cleanup.callback(observer.close)
        cleanup.callback(control.close)
        observer.request('state.subscribe')
        source = identity()

        # First prove that actual samples can be captured and explicitly played;
        # an unlinked recorder or a recorder that always fails must not pass.
        recorder = start_recording(source)
        time.sleep(.75)
        control.request('microphone.stop', dict(owner='private-test', discard=False))
        observer.wait_state(lambda s: s.get('microphone', {}).get('state') == 'ready')
        stopped(recorder)
        control.request('microphone.start', dict(owner='private-test', record=False))
        until(lambda: test_stream('Output'))
        observer.wait_state(lambda s: s.get('microphone', {}).get('state') == 'playing')
        observer.wait_state(lambda s: s.get('microphone', {}).get('state') == 'ready')
        control.request('microphone.stop', dict(owner='private-test', discard=True))
        discarded()
        print('PASS: real pw-record samples and explicit pw-play on dummy audio', flush=True)

        started_at = time.monotonic()
        recorder = start_recording(source)
        state = observer.wait_state(lambda s: s.get('microphone', {}).get('state') != 'recording')
        assert state['microphone']['state'] == 'ready' and not state['microphone']['error'], state['microphone']
        assert 4 <= time.monotonic() - started_at < 8, 'Five-second capture did not finish on time'
        stopped(recorder)
        assert not test_stream('Output'), 'Finishing capture started playback automatically'
        control.request('microphone.start', dict(owner='private-test', record=False))
        until(lambda: test_stream('Output'))
        observer.wait_state(lambda s: s.get('microphone', {}).get('state') == 'playing')
        observer.wait_state(lambda s: s.get('microphone', {}).get('state') == 'ready')
        control.request('microphone.stop', dict(owner='private-test', discard=True))
        discarded()
        print('PASS: five-second capture finishes automatically and keeps a replayable clip', flush=True)

        recorder = start_recording(source)
        changed_at = time.monotonic()
        control.request('microphone.stop', dict(owner='private-test', discard=True))
        control.request('microphone.stop', dict(owner='private-test', discard=False))
        discarded()
        stopped(recorder, changed_at)
        print('PASS: explicit discard stops the real recorder despite a late stop request', flush=True)

        recorder = start_recording(source)
        changed_at = time.monotonic()
        run('pw-cli', 'destroy', str(source['id']))
        state = discarded()
        assert state['microphone']['error'], state['microphone']
        stopped(recorder, changed_at)
        recreate_source()
        replacement = identity(previous=source['serial'])
        assert replacement['generation'] == source['generation']
        # Reconnecting an identically named source cannot authorize a new capture.
        time.sleep(.5)
        discarded()
        revision = int(observer.state['revision'])
        control.request('microphone.start', dict(owner='private-test', record=True, identity=source))
        observer.wait_state(lambda s: int(s['revision']) > revision and
                            s.get('microphone', {}).get('state') == 'idle' and s['microphone']['error'])
        assert discarded()['microphone']['error']
        print('PASS: source removal discards capture; replacement rejects the old identity', flush=True)

        recorder = start_recording(replacement)
        # Change the source outside the service's mutation queue while recording.
        changed_at = time.monotonic()
        run('pw-cli', 'set-param', str(replacement['id']), 'Props', '{ mute: true }')
        assert discarded()['microphone']['error']
        stopped(recorder, changed_at)
        run('pw-cli', 'set-param', str(replacement['id']), 'Props', '{ mute: false }')
        replacement = identity()
        time.sleep(.5)
        discarded()
        print('PASS: external source mute cancels capture; unmute does not restart it', flush=True)

        recorder = start_recording(replacement)
        changed_at = time.monotonic()
        stop(pipewire)
        discarded(connected=False)
        stopped(recorder, changed_at)
        pipewire = launch(['pipewire', '-c', str(config)])
        until(lambda: (work/'audio-test').exists())
        observer.wait_state(lambda s: s.get('graphReady') and s['generation'] != replacement['generation'])
        time.sleep(.5)
        discarded()
        print('PASS: server loss cancels capture; reconnect never restores a clip or recorder', flush=True)
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read()[-10000:], file=sys.stderr)
        raise
    finally:
        cleanup.close()
