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
            device_process = start([str(fixture)])
            start([str(BINARY)])
            path = work/'omarchy-audio-control/backend.sock'
            until(path.exists)
            client = Client(path)
            client.request('state.subscribe')
            state = client.wait_state(lambda s: s.get('graphReady') and
                any(n['name'] == 'audio_test_routed_input' and n['audio']['volumes'] for n in s['nodes']))
            identities = {}
            for direction, expected in [('output', [.2, .3]), ('input', [.4, .5])]:
                node = next(n for n in state['nodes'] if n['name'] == 'audio_test_routed_'+direction)
                identities[direction] = dict(generation=state['generation'], id=node['id'], serial=node['serial'])
                assert all(abs(a-b) < .001 for a, b in zip(node['audio']['volumes'], expected)), node
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
            client.request('node.level', dict(identity=identities['output'], volume=.3))
            device_process.terminate()
            device_process.wait(timeout=5)
            client.wait_state(lambda s: all(n['id'] != identities['output']['id'] for n in s['nodes']))
            reply = client.response(client.send('node.level', dict(identity=identities['output'], volume=.2)))
            assert reply['error']['code'] == 'stale_node', reply
            print('PASS: hardware route volume, balance, mute, delayed confirmation, route refresh and removal')
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
