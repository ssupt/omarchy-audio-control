#!/usr/bin/env python3
"""Native settings against private WirePlumber, including saved-state reload."""
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


def stop(process):
    if process.poll() is None:
        process.terminate()
        process.wait(timeout=5)


with tempfile.TemporaryDirectory(prefix='audio-policy-') as temporary, ExitStack() as cleanup:
    work = Path(temporary)
    log = cleanup.enter_context((work/'runtime.log').open('w+'))
    env = {key: os.environ[key] for key in ('PATH', 'LANG') if key in os.environ}
    env.update(HOME=temporary, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
               PIPEWIRE_REMOTE='audio-test', XDG_CONFIG_HOME=str(work/'config'),
               XDG_STATE_HOME=str(work/'state'), XDG_CACHE_HOME=str(work/'cache'),
               AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary,
               DBUS_SESSION_BUS_ADDRESS='unix:path='+str(work/'bus'),
               DBUS_SYSTEM_BUS_ADDRESS='unix:path='+str(work/'bus'),
               WIREPLUMBER_CONFIG_DIR='/usr/share/wireplumber')
    bus = work/'bus.conf'
    bus.write_text('<busconfig><type>session</type><listen>unix:path='+str(work/'bus')+'</listen>'
        '<auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/>'
        '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
    config = work/'pipewire.conf'
    config.write_text((ROOT/'test/fixtures/pipewire.conf').read_text().split('context.objects =')[0])

    def launch(command, environment=env):
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
        cleanup.callback(stop, process)
        return process

    def until(predicate):
        deadline = time.monotonic()+10
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.05)
        raise AssertionError('Private policy condition exceeded its deadline')

    def run(*command):
        return subprocess.check_output(command, env=env, text=True, stderr=log, timeout=5)

    try:
        launch(['dbus-daemon', '--nofork', '--config-file='+str(bus)])
        until(lambda: (work/'bus').exists())
        launch(['pipewire', '-c', str(config)])
        until(lambda: (work/'audio-test').exists())
        wp = launch(['wireplumber', '--profile', 'policy'])
        # No command-line audio tools are available to the backend in this test.
        (work/'empty-path').mkdir()
        backend = launch([str(BINARY)], dict(env, PATH=str(work/'empty-path')))
        path = work/'omarchy-audio-control/backend.sock'
        until(path.exists)
        client = Client(path)
        cleanup.callback(client.close)
        client.request('state.subscribe')
        state = client.wait_state(lambda s: len(s.get('policies', {})) == 11)
        generation = state['generation']
        mono = 'node.features.audio.mono'
        volume = 'device.routes.default-sink-volume'
        autoswitch = 'bluetooth.autoswitch-to-headset-profile'
        preference = 'bluetooth.profile-preference'
        assert state['policies'][mono] is False
        assert abs(state['policies'][volume]-.4) < .000001

        def change(key, value):
            return client.request('policy.set', dict(generation=generation, key=key, value=value))

        expected = {mono: True, volume: .5, autoswitch: False, preference: 'latency'}
        for key, value in expected.items():
            assert change(key, value)['outcome'] == 'applied'
            state = client.wait_state(lambda s: s.get('policies', {}).get(key) == value and
                s.get('metadata', {}).get('persistent-sm-settings', {}).get('0:'+key, {}).get('value') == json.dumps(.125 if key == volume else value))
            raw = state['metadata']['persistent-sm-settings']['0:'+key]['value']
            assert json.loads(raw) == (.125 if key == volume else value)
            assert not state['busy']
        before = state['metadata']['persistent-sm-settings']
        for key, value in [(volume, 1.5), (volume, -.1), (mono, 'true'),
                           (preference, 'invalid'), ('unknown.audio.setting', True)]:
            reply = client.response(client.send('policy.set', dict(generation=generation, key=key, value=value)))
            assert reply['error']['code'] == 'invalid_params', reply
        reply = client.response(client.send('policy.set', dict(generation='stale', key=mono, value=False)))
        assert reply['error']['code'] == 'stale_graph', reply
        assert client.state['metadata']['persistent-sm-settings'] == before

        # wpctl uses SPA JSON bare strings. Both live and saved external changes
        # arrive without a refresh request from either UI surface.
        run('wpctl', 'settings', '--save', preference, 'quality')
        client.wait_state(lambda s: s.get('policies', {}).get(preference) == 'quality')
        run('wpctl', 'settings', volume, '0.027')
        client.wait_state(lambda s: abs(s.get('policies', {}).get(volume, -1)-.3) < .000001)
        change(volume, .5)
        client.wait_state(lambda s: s.get('policies', {}).get(volume) == .5)
        # Deny writes only to saved settings: the live half can change, but
        # the service must restore it and report failure instead of success.
        objects = json.loads(run('pw-dump'))
        backend_client = next(o['id'] for o in objects if o['type'] == 'PipeWire:Interface:Client'
            and o.get('info', {}).get('props', {}).get('application.id') == 'ssupt.audio-control')
        persistent = next(o['id'] for o in objects if o['type'] == 'PipeWire:Interface:Metadata'
            and o.get('props', {}).get('metadata.name') == 'persistent-sm-settings')
        run('pw-cli', 'permissions', str(backend_client), str(persistent), '0500')
        reply = client.response(client.send('policy.set', dict(generation=generation, key=mono, value=False)))
        assert reply['error']['code'] == 'not_applied', reply
        state = client.wait_state(lambda s: s.get('policies', {}).get(mono) is True)
        assert json.loads(state['metadata']['persistent-sm-settings']['0:'+mono]['value']) is True
        run('pw-cli', 'permissions', str(backend_client), str(persistent), '0710')
        # Wait for WirePlumber's deferred disk write before restarting it.
        saved = work/'state/wireplumber/sm-settings'
        until(lambda: saved.exists() and '0.125' in saved.read_text() and 'quality' in saved.read_text())
        stop(wp)
        client.wait_state(lambda s: s.get('policies') == {})
        reply = client.response(client.send('policy.set', dict(generation=generation, key=mono, value=False)))
        assert reply['error']['code'] == 'unsupported', reply
        wp = launch(['wireplumber', '--profile', 'policy'])
        expected[preference] = 'quality'
        state = client.wait_state(lambda s: all(s.get('policies', {}).get(k) == v for k, v in expected.items()))
        assert state['generation'] == generation, 'WirePlumber restart should not require a PipeWire restart'
        # Malformed or missing capabilities are hidden and cannot be recreated.
        run('pw-metadata', '-n', 'sm-settings', '0', mono, 'invalid', 'Spa:String:JSON')
        client.wait_state(lambda s: mono not in s.get('policies', {}))
        reply = client.response(client.send('policy.set', dict(generation=generation, key=mono, value=True)))
        assert reply['error']['code'] == 'unsupported', reply
        run('pw-metadata', '-n', 'sm-settings', '0', mono, 'false', 'Spa:String:JSON')
        client.wait_state(lambda s: s.get('policies', {}).get(mono) is False)
        assert not Path('/proc', str(backend.pid), 'task', str(backend.pid), 'children').read_text().strip()
        print('PASS: native policies, cubic volumes, validation, partial-write rollback, external updates and persistence across WirePlumber restart')
    except BaseException:
        log.flush()
        print((work/'runtime.log').read_text()[-14000:], file=sys.stderr)
        raise
