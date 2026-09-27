#!/usr/bin/env python3
"""Profile changes against a private SPA device that recreates its endpoints."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import time

from client import Client

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(sys.argv[1]).resolve()


def until(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if result := predicate():
            return result
        time.sleep(.025)
    raise AssertionError('Profile fixture did not become ready')


with tempfile.TemporaryDirectory(prefix='audio-profiles-') as temporary:
    work = Path(temporary)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libpipewire-0.3'], text=True))
    fixture = work/'profile-device'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter',
                    str(ROOT/'test/fixtures/routed-device.c'), '-o', str(fixture), *flags], check=True)
    env = dict(os.environ, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
               PIPEWIRE_REMOTE='audio-test', XDG_CONFIG_HOME=str(work/'config'),
               XDG_STATE_HOME=str(work/'state'), XDG_CACHE_HOME=str(work/'cache'),
               AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary, PULSE_SERVER='unix:'+str(work/'pulse'))
    for key in ('OMARCHY_AUDIO_HELPERS_DIR', 'OMARCHY_AUDIO_CONTROL_FILE',
                'OMARCHY_AUDIO_PREFERENCES_FILE', 'OMARCHY_AUDIO_RULES_FILE', 'OMARCHY_AUDIO_SCENES_FILE'):
        env.pop(key, None)
    processes = []
    client = None
    with (work/'log').open('w+') as log:
        def start(command):
            process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
            processes.append(process)
            return process

        try:
            start(['pipewire', '-c', str(ROOT/'test/fixtures/pipewire.conf')])
            until(lambda: (work/'audio-test').exists())
            control = work/'control'
            control.write_text('normal')
            fixture_process = start([str(fixture), str(control), '--profiles'])
            start([str(BINARY)])
            path = work/'omarchy-audio-control/backend.sock'
            until(path.exists)
            client = Client(path)
            client.socket.settimeout(30)
            client.request('state.subscribe')
            state = client.wait_state(lambda s: s.get('catalogReady') and len(s.get('ports', [])) == 2)
            card, = state['profiles']
            identity = card['identity']
            assert card['activeProfile'] == 'HiFi', card
            def change(profile, expected=None):
                reply = client.response(client.send('profile.set', dict(identity=identity, profile=profile)))
                response = reply.get('error' if expected else 'result')
                assert response is not None, reply
                if expected:
                    assert response['code'] == expected, response
                else:
                    assert response['outcome'] == 'applied', response
                    client.wait_state(lambda s: s.get('catalogReady') and s['profiles'][0]['activeProfile'] == profile)
                return response

            def assert_audio(output=(.2, .3), input=(.4, .5), muted=(False, False)):
                def matches(s):
                    nodes = {n['name']: n for n in s['nodes']}
                    for i, (direction, expected) in enumerate([('output', output), ('input', input)]):
                        node = nodes.get('audio_test_routed_'+direction)
                        if not node or node['audio']['muted'] != muted[i] or len(node['audio']['volumes']) != len(expected):
                            return False
                        if any(abs(a-b) > .001 for a, b in zip(node['audio']['volumes'], expected)):
                            return False
                    return True
                client.wait_state(matches)

            before = (work/'log').read_text()
            change('HiFi')
            assert (work/'log').read_text() == before, 'Active profile sent a device write'
            change('missing', 'unavailable')
            change('pro-audio', 'unavailable')
            for key in ('generation', 'serial'):
                stale = dict(identity, **{key: 'stale'})
                error = client.response(client.send('profile.set', dict(identity=stale, profile='headset')))['error']
                assert error['code'] in ('stale_graph', 'stale_device'), error
            original_serials = {n['serial'] for n in state['nodes'] if n['name'].startswith('audio_test_routed_')}
            subprocess.run(['pw-link', 'audio_test_playback:monitor_FL', 'audio_test_routed_output:playback_FL'], env=env, check=True)
            client.wait_state(lambda s: bool(s['links']))
            started = time.monotonic()
            change('headset')
            assert time.monotonic()-started >= .08
            assert_audio()
            playback = next(n for n in client.state['nodes'] if n['name'] == 'audio_test_playback')
            assert playback['audio']['muted'] is False, 'Surviving playback stream stayed muted'
            assert original_serials.isdisjoint(n['serial'] for n in client.state['nodes']), 'Fixture did not recreate endpoints'
            change('HiFi')
            assert_audio()
            source = next(n for n in client.state['nodes'] if n['name'] == 'audio_test_routed_input')
            client.request('node.audio', dict(identity=dict(generation=client.state['generation'], id=source['id'], serial=source['serial']), patch=dict(muted=True)))
            change('headset')
            assert_audio(muted=(False, True))
            scene = dict(name='Restore profile', profiles=[dict(card='audio_test_device', profile='HiFi')])
            result = client.request('scene.apply', dict(scene=scene))
            assert result['outcome'] == 'applied' and result['applied'] == 1, result
            assert_audio(muted=(False, True))
            control.write_text('profile-silent-once')
            change('headset', 'not_applied')
            client.wait_state(lambda s: s.get('catalogReady') and s['profiles'][0]['activeProfile'] == 'HiFi')
            assert_audio(muted=(False, True))
            control.write_text('profile-ignore')
            change('headset', 'outcome_unknown')
            control.write_text('normal')
            change('off')
            client.wait_state(lambda s: not any(n['name'].startswith('audio_test_routed_') for n in s['nodes']))
            change('HiFi')
            assert_audio(output=(1, 1), input=(1, 1))
            control.write_text('profile-third')
            change('headset', 'outcome_unknown')
            assert (work/'log').read_text().splitlines()[-1] == 'PROFILE 3', 'Rollback overwrote a third profile'
            fixture_process.terminate()
            fixture_process.wait(timeout=3)
            client.wait_state(lambda s: not s['profiles'])
            change('HiFi', 'stale_device')
            control.write_text('normal')
            fixture_process = start([str(fixture), str(control), '--profiles', '--bluetooth'])
            state = client.wait_state(lambda s: s.get('catalogReady') and s['profiles'] and s['profiles'][0]['bluetooth'])
            identity = state['profiles'][0]['identity']
            config = work/'config/omarchy/audio-preferences.json'
            config.parent.mkdir(parents=True, exist_ok=True)
            config.write_text('{"version":999}')
            before = (work/'log').read_text().count('PROFILE ')
            reply = client.response(client.send('profile.set', dict(identity=identity, profile='headset')))
            assert reply['error']['outcome'] == 'rejected', reply
            assert (work/'log').read_text().count('PROFILE ') == before, 'Invalid preferences did not block hardware changes'
            config.write_text('{"version":1}')
            change('HiFi')
            assert json.loads(config.read_text())['bluetoothProfiles']['aabbccddeeff'] == 'HiFi'
            change('headset')
            assert json.loads(config.read_text())['bluetoothProfiles']['aabbccddeeff'] == 'headset'
            saved_preferences = config.read_bytes()
            lock = config.with_name(config.name+'.lock')
            lock.unlink()
            lock.symlink_to(work/'forbidden-lock-target')
            response = client.request('profile.set', dict(identity=identity, profile='HiFi'))
            assert response['outcome'] == 'persistence_failed', response
            assert config.read_bytes() == saved_preferences
            assert not (work/'forbidden-lock-target').exists()
            lock.unlink()
            control.write_text('normal')
            before = (work/'log').read_text().count('PROFILE ')
            pending = client.send('profile.set', dict(identity=identity, profile='headset'))
            until(lambda: (work/'log').read_text().count('PROFILE ') > before)
            fixture_process.terminate()
            fixture_process.wait(timeout=3)
            reply = client.response(pending)
            assert reply['error']['outcome'] == 'unknown', reply
            print('PASS: native profile changes, endpoint recreation, mute/volume restoration, scenes, stale targets, silent writes, rollback and external profile conflicts')
        except BaseException:
            log.flush()
            print((work/'log').read_text()[-10000:], file=sys.stderr)
            if client:
                print(json.dumps({k: client.state.get(k) for k in ('profiles', 'devices', 'busy', 'operation')}, indent=2), file=sys.stderr)
            raise
        finally:
            if client:
                client.close()
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
