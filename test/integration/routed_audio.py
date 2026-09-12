#!/usr/bin/env python3
"""Hardware route controls on a private server, without ALSA or Bluetooth access."""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time

from client import Client

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT/'backend/target/debug/omarchy-audio-service'


def until(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.025)
    raise AssertionError('Device did not become ready')


with tempfile.TemporaryDirectory(prefix='audio-routes-') as temporary:
    work = Path(temporary)
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'libpipewire-0.3'], text=True))
    fixture = work/'routed-device'
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

        def dump():
            return json.loads(subprocess.check_output(['pw-dump'], env=env, timeout=5))

        try:
            start(['pipewire', '-c', str(ROOT/'test/fixtures/pipewire.conf')])
            until(lambda: (work/'audio-test').exists())
            control = work/'device-control'
            control.write_text('normal')
            device_process = start([str(fixture), str(control)])
            start([str(BINARY)])
            path = work/'omarchy-audio-control/backend.sock'
            until(path.exists)
            client = Client(path)
            client.request('state.subscribe')
            state = client.wait_state(lambda s: s.get('catalogReady') and
                any(n['name'] == 'audio_test_routed_input' and n['audio']['volumes'] for n in s['nodes']))
            def check_catalog(state):
                card, = state['profiles']
                assert card['name'] == 'audio_test_device' and card['activeProfile'] == 'HiFi', card
                assert card['profiles'] == [dict(value='HiFi', label='HiFi', sinks=1, sources=1),
                                            dict(value='off', label='off', sinks=0, sources=0)], card
                assert len(state['ports']) == 2, state['ports']
                assert [p['activePort'] for p in state['ports']] == ['[Out] Speaker', '[In] Mic'], state['ports']
            check_catalog(state)
            scene = client.request('scene.capture', dict(name='Routed devices'))
            assert scene['profiles'] == [dict(card='audio_test_device', profile='HiFi')], scene
            assert {p['value'] for p in scene['ports']} == {'[Out] Speaker', '[In] Mic'}, scene
            identities = {}
            for direction, expected in [('output', [.2, .3]), ('input', [.4, .5])]:
                node = next(n for n in state['nodes'] if n['name'] == 'audio_test_routed_'+direction)
                identities[direction] = dict(generation=state['generation'], id=node['id'], serial=node['serial'])
                assert all(abs(a-b) < .001 for a, b in zip(node['audio']['volumes'], expected)), node
            def port_request(direction, name):
                result = client.request('port.set', dict(identity=identities[direction], port=name))
                client.wait_state(lambda s: any(p['direction'] == direction and p['activePort'] == name for p in s['ports']))
                return result

            def active_port(direction):
                return next(p['activePort'] for p in client.state['ports'] if p['direction'] == direction)

            assert {p['direction']: p['identity'] for p in state['ports']} == identities
            before = (work/'log').read_text().count('PORT ')
            port_request('output', '[Out] Speaker')
            assert (work/'log').read_text().count('PORT ') == before, 'Selecting the active port sent a write'
            for direction, target, original in [('output', '[Out] Headphones', '[Out] Speaker'),
                                                 ('input', '[In] Line', '[In] Mic')]:
                started = time.monotonic()
                port_request(direction, target)
                assert time.monotonic()-started >= .06, 'Port selection returned before the device applied it'
                assert active_port(direction) == target
                observed = dump()
                device = next(n for n in observed if n.get('info', {}).get('props', {}).get('device.name') == 'audio_test_device')
                route = next(r for r in device['info']['params']['Route'] if r['device'] == (4 if direction == 'output' else 0))
                expected = [.008, .027] if direction == 'output' else [.064, .125]
                assert all(abs(a-b) < .00001 for a, b in zip(route['props']['channelVolumes'], expected)), route
                port_request(direction, original)
            before = (work/'log').read_text().count('PORT ')
            for identity, target, code in [
                (dict(identities['output'], serial='stale'), '[Out] Headphones', 'stale_node'),
                (dict(identities['output'], generation='stale'), '[Out] Headphones', 'stale_graph'),
                (identities['output'], '[In] Mic', 'unavailable'),
                (identities['output'], 'missing', 'unavailable'),
                (identities['output'], ' bad\n', 'invalid_params')]:
                reply = client.response(client.send('port.set', dict(identity=identity, port=target)))
                assert reply['error']['code'] == code and reply['error']['outcome'] == 'rejected', reply
            assert (work/'log').read_text().count('PORT ') == before, 'An invalid port request reached the device'
            applied = client.request('scene.apply', dict(scene=dict(name='Ports only', ports=[
                dict(direction='output', endpoint='audio_test_routed_output', value='[Out] Headphones'),
                dict(direction='input', endpoint='missing', value='absent'),
                dict(direction='input', endpoint='audio_test_routed_input', value='absent') ])))
            assert applied['applied'] == 1 and len(applied['skipped']) == 2 and not applied['errors'], applied
            client.wait_state(lambda s: any(p['direction'] == 'output' and p['activePort'] == '[Out] Headphones' for p in s['ports']))
            assert active_port('output') == '[Out] Headphones'
            port_request('output', '[Out] Speaker')
            # The device changes state but withholds its update. Confirmation must
            # time out and wait for a fresh observation of the rollback, not trust
            # the cached original port after only a core roundtrip.
            control.write_text('silent-once')
            reply = client.response(client.send('port.set', dict(identity=identities['output'], port='[Out] Headphones')))
            assert reply['error']['code'] == 'not_applied', reply
            observed = dump()
            device = next(n for n in observed if n.get('info', {}).get('props', {}).get('device.name') == 'audio_test_device')
            assert next(r for r in device['info']['params']['Route'] if r['device'] == 4)['index'] == 2
            control.write_text('ignore')
            reply = client.response(client.send('port.set', dict(identity=identities['output'], port='[Out] Headphones')))
            assert reply['error']['outcome'] == 'unknown', 'Unobserved rollback was reported as verified: '+str(reply)
            control.write_text('normal')
            state = client.state
            catalog = state['catalogRevision']
            for direction in ('output', 'input'):
                identity = identities[direction]
                for level in (.1, .2, .3, .4):
                    started = time.monotonic()
                    client.request('node.level', dict(identity=identity, volume=level))
                    # The exported device applies changes after the core roundtrip.
                    assert time.monotonic()-started >= .06
                    observed = dump()
                    device = next(n for n in observed if n.get('info', {}).get('props', {}).get('device.name') == 'audio_test_device')
                    route = next(r for r in device['info']['params']['Route'] if r['device'] == (4 if direction == 'output' else 0))
                    assert abs(max(route['props']['channelVolumes'])-level**3) < .00001, route
                    node = next(n for n in observed if n['id'] == identity['id'])
                    props = next(p for p in node['info']['params']['Props'] if 'channelVolumes' in p)
                    assert props['channelVolumes'] == [1.0, 1.0], 'Hardware control wrote the software node'
                client.request('node.level', dict(identity=identity, balance=.5, muted=True))
                client.wait_state(lambda s: any(n['id'] == identity['id'] and n['audio']['muted'] is True for n in s['nodes']))
                node = next(n for n in client.state['nodes'] if n['id'] == identity['id'])
                assert node['audio']['muted'] is True and abs(node['audio']['volumes'][0]-.2) < .001, node
                client.request('node.level', dict(identity=identity, muted=False))
            assert client.state['catalogRevision'] == catalog, 'Volume changes triggered a device catalog refresh'
            # An empty Route enumeration must remove old routes atomically.
            device_process.send_signal(signal.SIGUSR1)
            client.wait_state(lambda s: all(n['audio']['volumes'] == [1.0, 1.0]
                for n in s['nodes'] if n['name'].startswith('audio_test_routed_')))
            device_process.send_signal(signal.SIGUSR1)
            client.wait_state(lambda s: all(abs(max(n['audio']['volumes'])-.4) < .001
                for n in s['nodes'] if n['name'].startswith('audio_test_routed_')))
            # Publish profile, port availability and active route changes together.
            device_process.send_signal(signal.SIGUSR2)
            changed = client.wait_state(lambda s: s.get('catalogReady') and s['profiles'][0]['activeProfile'] == 'headset')
            assert [p['value'] for p in changed['profiles'][0]['profiles']] == ['headset', 'off'], changed['profiles']
            port, = changed['ports']
            assert port['direction'] == 'output' and port['activePort'] == '[Out] Headphones', port
            assert len(port['ports']) == 2, 'An unavailable active port must remain visible'
            port_request('output', '[Out] Headphones')
            client.request('port.set', dict(identity=identities['output'], port='[Out] Speaker'))
            client.wait_state(lambda s: not any(p['direction'] == 'output' for p in s['ports']))
            reply = client.response(client.send('port.set', dict(identity=identities['output'], port='[Out] Headphones')))
            assert reply['error']['code'] == 'unavailable', reply
            device_process.send_signal(signal.SIGUSR2)
            restored = client.wait_state(lambda s: s.get('catalogReady') and s['profiles'][0]['activeProfile'] == 'HiFi')
            check_catalog(restored)
            client.request('node.level', dict(identity=identities['output'], volume=.3))
            writes = (work/'log').read_text().count('PORT ')
            pending = client.send('port.set', dict(identity=identities['output'], port='[Out] Headphones'))
            until(lambda: (work/'log').read_text().count('PORT ') > writes)
            device_process.terminate()
            device_process.wait(timeout=5)
            reply = client.response(pending)
            assert reply['error']['outcome'] == 'unknown', reply
            client.wait_state(lambda s: all(n['id'] != identities['output']['id'] for n in s['nodes']))
            assert not client.state['profiles'] and not client.state['ports'], client.state
            reply = client.response(client.send('node.level', dict(identity=identities['output'], volume=.2)))
            assert reply['error']['code'] == 'stale_node', reply
            reply = client.response(client.send('port.set', dict(identity=identities['output'], port='[Out] Headphones')))
            assert reply['error']['code'] == 'stale_node', reply
            print('PASS: native port selection, scene ports, stale/unavailable targets, delayed confirmation and rollback')
            print('PASS: native profiles, ports, scene capture, hardware levels, delayed confirmation and removal')
        except Exception:
            log.flush()
            print((work/'log').read_text()[-5000:], file=sys.stderr)
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
                        process.wait(timeout=5)
