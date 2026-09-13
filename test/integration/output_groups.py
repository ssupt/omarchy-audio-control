#!/usr/bin/env python3
"""Group hotplug with real Pulse/WirePlumber policy and synthetic outputs."""
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
        if client is not None:
            client.request('health')  # Drain snapshots while external tools inspect the graph.
        value = predicate()
        if value:
            return value
        time.sleep(.05)
    raise AssertionError('Output group condition exceeded its deadline')


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
            raise AssertionError('Private audio process did not stop')


with tempfile.TemporaryDirectory(prefix='audio-groups-') as temporary, ExitStack() as cleanup:
    work = Path(temporary)
    client = None
    log = cleanup.enter_context((work/'runtime.log').open('w+'))
    env = {key: os.environ[key] for key in ('PATH', 'LANG') if key in os.environ}
    env.update(HOME=temporary, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
               PIPEWIRE_REMOTE='audio-test', XDG_CONFIG_HOME=str(work/'config'),
               XDG_STATE_HOME=str(work/'state'), XDG_CACHE_HOME=str(work/'cache'),
               AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary,
               PULSE_SERVER='unix:'+str(work/'pulse/native'),
               DBUS_SESSION_BUS_ADDRESS='unix:path='+str(work/'bus'),
               DBUS_SYSTEM_BUS_ADDRESS='unix:path='+str(work/'bus'),
               WIREPLUMBER_CONFIG_DIR='/usr/share/wireplumber')
    bus = work/'bus.conf'
    bus.write_text('<busconfig><type>session</type><listen>unix:path='+str(work/'bus')+'</listen>'
        '<auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/>'
        '<allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
    config = work/'pipewire.conf'
    # Keep only the fixture's driver and backing sink for this playback test.
    config.write_text((ROOT/'test/fixtures/pipewire.conf').read_text().replace(
        '    { factory = metadata args = { metadata.name = default } }\n', '').split(
        '    { factory = adapter args = {\n        factory.name = support.null-audio-sink\n        node.name = audio_test_input')[0] + ']\n')

    def launch(command, **kwargs):
        process = subprocess.Popen(command, env=env, stdout=log, stderr=log, **kwargs)
        cleanup.callback(stop, process)
        return process

    def run(*command):
        return subprocess.check_output(command, env=env, text=True, stderr=log, timeout=5)

    def sinks():
        return json.loads(run('pactl', '-f', 'json', 'list', 'sinks'))

    def member(name):
        # The backing endpoint is inert. These client sinks model removable
        # physical outputs without loading ALSA/BlueZ monitors or using hardware.
        return launch(['pw-loopback', '--capture-props=media.class=Audio/Sink '
            'node.name='+name+' node.description='+name+' node.virtual=false '
            'device.class=sound priority.session=2000',
            '--playback-props=target.object=audio_test_output node.name='+name+'_render'])

    def player_sink():
        streams = json.loads(run('pactl', '-f', 'json', 'list', 'sink-inputs'))
        return next((s['sink'] for s in streams
                     if s['properties'].get('application.name') == 'Group Test Player'), None)

    try:
        launch(['dbus-daemon', '--nofork', '--config-file='+str(bus)])
        until(lambda: (work/'bus').exists())
        launch(['pipewire', '-c', str(config)])
        until(lambda: (work/'audio-test').exists())
        launch(['wireplumber', '--profile', 'policy'])
        launch(['pipewire-pulse'])
        until(lambda: (work/'pulse/native').exists())
        member('audio_test_left')
        right = member('audio_test_right')
        until(lambda: all(any(s['name'] == name for s in sinks())
                          for name in ('audio_test_left', 'audio_test_right')))
        launch([str(BINARY)])
        path = work/'omarchy-audio-control/backend.sock'
        until(path.exists)
        client = Client(path)
        cleanup.callback(client.close)
        client.request('state.subscribe')
        state = client.wait_state(lambda s: s.get('graphReady') and
            any(n['name'] == 'audio_test_right' for n in s['nodes']))

        def change(helper, args):
            reply = client.response(client.send('adapter.run', dict(
                helper=helper, args=args, generation=state['generation'])))
            if reply.get('error', {}).get('code') == 'busy':
                return False
            assert reply.get('result', {}).get('exitCode') == 0, reply
            return reply['result']['stdout'].strip() or True

        group_id = until(lambda: change('audio-output-groups',
            ['create', 'Desk', json.dumps(['audio_test_left', 'audio_test_right'])]))
        group_name = 'omarchy_audio_group_'+group_id
        group = until(lambda: next((s for s in sinks() if s['name'] == group_name), None))
        group_node = client.wait_state(lambda s: any(n['name'] == group_name for n in s['nodes']))
        group_node = next(n for n in group_node['nodes'] if n['name'] == group_name)
        assert client.request('default.set', dict(identity=dict(generation=state['generation'],
            id=group_node['id'], serial=group_node['serial'])))['outcome'] == 'applied'
        until(lambda: run('pactl', 'get-default-sink').strip() == group_name)
        zero = cleanup.enter_context(open('/dev/zero', 'rb'))
        player = launch(['pw-play', '--raw', '--rate=48000', '--channels=2', '--format=s16',
            '--properties=application.name="Group Test Player" node.name=audio_test_player', '-'], stdin=zero)
        until(lambda: player_sink() == group['index'])
        documents = {p.name: p.read_bytes() for p in (work/'config/omarchy').glob('audio-*.json')}

        stop(right)
        until(lambda: all(s['name'] != group_name for s in sinks()), timeout=6)
        survivor = next(s for s in sinks() if s['name'] == 'audio_test_left')
        until(lambda: run('pactl', 'get-default-sink').strip() == survivor['name']
              and player_sink() == survivor['index'])
        assert player.poll() is None, 'Playback exited during fallback'
        assert all((work/'config/omarchy'/name).read_bytes() == data for name, data in documents.items())
        print('PASS: active group disappears on member loss; default and playback follow the survivor', flush=True)

        right = member('audio_test_right')
        group = until(lambda: next((s for s in sinks() if s['name'] == group_name), None))
        until(lambda: run('pactl', 'get-default-sink').strip() == group_name
              and player_sink() == group['index'])
        assert player.poll() is None
        assert all((work/'config/omarchy'/name).read_bytes() == data for name, data in documents.items())
        print('PASS: reconnect restores the selected group and playback without rewriting saved settings', flush=True)

        stop(right)
        until(lambda: all(s['name'] != group_name for s in sinks()))
        # An explicit selection during fallback replaces the remembered group.
        run('pactl', 'set-default-sink', 'audio_test_output')
        other = next(s for s in sinks() if s['name'] == 'audio_test_output')
        until(lambda: player_sink() == other['index'])
        member('audio_test_right')
        until(lambda: any(s['name'] == group_name for s in sinks()))
        assert run('pactl', 'get-default-sink').strip() == other['name']
        assert player_sink() == other['index'] and player.poll() is None
        print('PASS: reconnect preserves an output explicitly selected during fallback', flush=True)
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read()[-10000:], file=sys.stderr)
        raise
