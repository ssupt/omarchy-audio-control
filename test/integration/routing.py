#!/usr/bin/env python3
"""Native defaults and application routes against private WirePlumber and inert nodes."""
from contextlib import ExitStack
import json
import fcntl
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


with tempfile.TemporaryDirectory(prefix='audio-routing-') as temporary, ExitStack() as cleanup:
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
    fixture = (ROOT/'test/fixtures/pipewire.conf').read_text()
    fixture = fixture.replace('context.spa-libs = {', 'context.spa-libs = {\n    audiotestsrc = audiotestsrc/libspa-audiotestsrc')
    fixture = fixture.replace('factory.name = support.null-audio-sink\n        node.name = audio_test_input', 'factory.name = audiotestsrc\n        node.name = audio_test_input')
    fixture = fixture.replace('media.class = Audio/', 'node.virtual = false\n        device.class = sound\n        priority.session = 1000\n        media.class = Audio/')
    fixture = fixture.replace('    { factory = metadata args = { metadata.name = default } }\n', '')
    fixture = fixture.split('    { factory = adapter args = {\n        factory.name = support.null-audio-sink\n        node.name = audio_test_playback')[0]
    endpoints = fixture[fixture.index('    { factory = adapter args = {'):]
    config.write_text(fixture + endpoints.split('    { factory = adapter args = {\n        factory.name = audiotestsrc')[0].replace('audio_test_output', 'audio_test_third_output') + endpoints.replace('audio_test_output', 'audio_test_other_output').replace('audio_test_input', 'audio_test_other_input') + ']\n')

    def launch(command, environment=env):
        process = subprocess.Popen(command, env=environment, stdout=log, stderr=log)
        cleanup.callback(stop, process)
        return process

    def until(predicate):
        deadline = time.monotonic()+10
        while time.monotonic() < deadline:
            if predicate(): return
            time.sleep(.05)
        raise AssertionError('Private routing condition exceeded its deadline')

    def run(*command):
        output = subprocess.check_output(command, env=env, text=True, stderr=log, timeout=5)
        log.write('Command: '+repr(command)+'\n'+output+'\n')
        log.flush()
        return output

    client = None
    try:
        launch(['dbus-daemon', '--nofork', '--config-file='+str(bus)])
        until(lambda: (work/'bus').exists())
        pw = launch(['pipewire', '-c', str(config)])
        until(lambda: (work/'audio-test').exists())
        wp = launch(['wireplumber', '--profile', 'policy'])
        (work/'empty-path').mkdir()
        backend = launch([str(BINARY)], dict(env, PATH=str(work/'empty-path')))
        path = work/'omarchy-audio-control/backend.sock'
        until(path.exists)
        client = Client(path)
        cleanup.callback(client.close)
        client.request('state.subscribe')
        state = client.wait_state(lambda s: s.get('graphReady') and
            '0:default.audio.sink' in s.get('metadata', {}).get('default', {}))

        def node(name):
            client.request('health')
            return next(n for n in client.state['nodes'] if n['name'] == name)

        def identity(name):
            n = node(name)
            return dict(generation=client.state['generation'], id=n['id'], serial=n['serial'])

        def default(direction):
            client.request('health')
            key = '0:default.audio.'+('sink' if direction == 'playback' else 'source')
            return json.loads(client.state['metadata']['default'][key]['value'])['name']

        def select(name, previous=None):
            endpoint = node(name)
            key = '0:default.audio.'+('sink' if endpoint['properties']['media.class'] == 'Audio/Sink' else 'source')
            result = client.request('default.set', dict(identity=identity(name), previous=previous))
            client.wait_state(lambda s: json.loads(s['metadata']['default'][key]['value'])['name'] == name)
            return result

        def route(name, target, mode='override'):
            stream, endpoint = identity(name), identity(target)
            direction = 'playback' if node(name)['properties']['media.class'] == 'Stream/Output/Audio' else 'recording'
            result = client.request('route.set', dict(identity=stream, target=endpoint, mode=mode))
            client.wait_state(lambda s: s.get('routes',{}).get(direction,{}).get(stream['serial'])
                              == dict(target=endpoint['serial'], mode=mode))
            return result

        def linked(name, destination):
            client.request('health')
            nodes = {n['name']:n for n in client.state['nodes']}
            if name not in nodes or destination not in nodes: return False
            a, b = nodes[name], nodes[destination]
            return any({l['inputNode'],l['outputNode']} == {a['id'],b['id']} and l['state'] in ('Active','Paused')
                       for l in client.state['links'])

        def start_stream(name, record=False, extra=''):
            command = ['pw-record' if record else 'pw-play', '--raw', '--rate=48000', '--channels=1' if record else '--channels=2',
                       '--format=s16', '--properties=node.name='+name+' application.name='+name+' '+extra,
                       '/dev/null' if record else '/dev/zero']
            return launch(command)

        def rejected(method, params, codes):
            reply = client.response(client.send(method, params))
            assert reply.get('error', {}).get('code') in codes, reply
            return reply

        assert select('audio_test_output')['outcome'] == 'applied'
        assert select('audio_test_input')['outcome'] == 'applied'
        follow = start_stream('test_follow')
        pinned = start_stream('test_pinned')
        recorder = start_stream('test_record', True)
        until(lambda: linked('test_follow', 'audio_test_output') and linked('test_pinned', 'audio_test_output')
              and linked('test_record', 'audio_test_input'))
        assert route('test_pinned', 'audio_test_output')['outcome'] == 'applied'
        old = identity('audio_test_output')
        assert select('audio_test_other_output', old)['outcome'] == 'applied'
        assert default('playback') == 'audio_test_other_output'
        assert linked('test_follow', 'audio_test_other_output') and linked('test_pinned', 'audio_test_output')
        following = node('test_follow')['serial']
        client.wait_state(lambda s: s['routes']['playback'].get(following,{}).get('mode') == 'default')
        rejected('default.set', dict(identity=identity('audio_test_output'), previous=old), {'conflict'})
        rejected('default.set', dict(identity=dict(old, serial='stale')), {'stale_node'})
        rejected('route.set', dict(identity=identity('test_follow'), target=identity('audio_test_input'), mode='override'), {'invalid_target'})
        rejected('route.set', dict(identity=identity('test_follow'), target=old, mode='default'), {'conflict'})
        assert route('test_pinned', 'audio_test_other_output', 'default')['outcome'] == 'applied'
        assert select('audio_test_output')['outcome'] == 'applied'
        assert linked('test_follow', 'audio_test_output') and linked('test_pinned', 'audio_test_output')
        print('PASS: default followers move; explicit routes stay pinned; default mode clears the pin; stale requests fail', flush=True)

        static = start_stream('test_static', extra='target.object=audio_test_output state.restore-target=false')
        until(lambda: linked('test_static', 'audio_test_output'))
        assert node('test_static')['properties'].get('target.object') == 'audio_test_output', node('test_static')
        # pw-play supplies a legacy target.node=-1 override. Remove it so this
        # case exercises the target declared in the node's own properties.
        static_key = str(node('test_static')['id'])+':target.node'
        run('pw-metadata', '-n', 'default', '-d', str(node('test_static')['id']), 'target.node')
        client.wait_state(lambda s: static_key not in s['metadata']['default'])
        static_serial = node('test_static')['serial']
        assert client.state['routes']['playback'][static_serial]['mode'] == 'override', client.state['metadata']['default']
        assert select('audio_test_other_output')['outcome'] == 'applied'
        assert linked('test_static', 'audio_test_output') and linked('test_follow', 'audio_test_other_output')
        assert route('test_static', 'audio_test_other_output', 'default')['outcome'] == 'applied'
        assert select('audio_test_output')['outcome'] == 'applied'
        assert linked('test_static', 'audio_test_output')
        stop(static)
        client.wait_state(lambda s: all(n['name'] != 'test_static' for n in s['nodes']))
        print('PASS: application-declared targets stay pinned until the user selects follow-default', flush=True)

        assert select('audio_test_other_input')['outcome'] == 'applied'
        assert linked('test_record', 'audio_test_other_input')
        assert route('test_record', 'audio_test_input')['outcome'] == 'applied'
        assert select('audio_test_input')['outcome'] == 'applied'
        assert select('audio_test_other_input')['outcome'] == 'applied'
        assert linked('test_record', 'audio_test_input')
        assert route('test_record', 'audio_test_other_input', 'default')['outcome'] == 'applied'
        assert linked('test_record', 'audio_test_other_input')
        print('PASS: input defaults and recording routes preserve explicit/default behavior', flush=True)

        assert route('test_pinned', 'audio_test_other_output')['outcome'] == 'applied'
        stop(pinned)
        client.wait_state(lambda s: all(n['name'] != 'test_pinned' for n in s['nodes']))
        pinned = start_stream('test_pinned')
        until(lambda: linked('test_pinned', 'audio_test_other_output'))
        print('PASS: WirePlumber restores a manual application route when its stream is recreated', flush=True)

        stream_state = work/'state/wireplumber/stream-properties'
        default_state = work/'state/wireplumber/default-nodes'
        until(lambda: stream_state.exists() and 'test_pinned' in stream_state.read_text()
              and default_state.exists() and 'audio_test_other_input' in default_state.read_text())
        for process in (follow, pinned, recorder): stop(process)
        stop(wp)
        client.wait_state(lambda s: not s.get('metadata', {}).get('default'))
        wp = launch(['wireplumber', '--profile', 'policy'])
        client.wait_state(lambda s: '0:default.audio.source' in s.get('metadata', {}).get('default', {}))
        assert default('playback') == 'audio_test_output' and default('recording') == 'audio_test_other_input'
        follow = start_stream('test_follow')
        pinned = start_stream('test_pinned')
        recorder = start_stream('test_record', True)
        until(lambda: linked('test_follow', 'audio_test_output') and linked('test_pinned', 'audio_test_other_output')
              and linked('test_record', 'audio_test_other_input'))
        print('PASS: saved defaults and application routes survive a WirePlumber restart', flush=True)

        with (work/'omarchy-audio-mutation.lock').open('r+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            client.request('rules.set_app', dict(app='test_follow', direction='playback', target='audio_test_other_output'))
            time.sleep(5.5)
            assert linked('test_follow', 'audio_test_output')
            fcntl.flock(lock, fcntl.LOCK_UN)
        follow_serial, other_serial = node('test_follow')['serial'], node('audio_test_other_output')['serial']
        client.wait_state(lambda s: s.get('routes',{}).get('playback',{}).get(follow_serial,{}).get('target') == other_serial)
        until(lambda: linked('test_follow', 'audio_test_other_output'))
        assert route('test_follow', 'audio_test_output')['outcome'] == 'applied'
        assert any(r['app'] == 'test_follow' and r['target'] == 'audio_test_output' for r in client.state['stores']['rules']['appRules'])
        assert route('test_follow', 'audio_test_output', 'default')['outcome'] == 'applied'
        assert all(r['app'] != 'test_follow' for r in client.state['stores']['rules']['appRules'])
        print('PASS: automatic rules use native routing; manual changes update or remove existing rules', flush=True)

        prefs = work/'config/omarchy/audio-preferences.json'
        saved = prefs.read_bytes()
        prefs.write_text('{broken')
        rejected('default.set', dict(identity=identity('audio_test_other_output')), {'invalid_store'})
        assert default('playback') == 'audio_test_output'
        prefs.write_bytes(saved)
        rules = work/'config/omarchy/audio-rules.json'
        saved_rules = rules.read_bytes()
        rules.write_text('{broken')
        rejected('route.set', dict(identity=identity('test_follow'), target=identity('audio_test_other_output'), mode='override'), {'invalid_store'})
        assert linked('test_follow', 'audio_test_output')
        rules.write_bytes(saved_rules)
        prefs_lock = prefs.with_name(prefs.name+'.lock')
        prefs_lock.unlink()
        prefs_lock.symlink_to(work/'unused-lock')
        assert select('audio_test_other_output')['outcome'] == 'persistence_failed'
        assert default('playback') == 'audio_test_other_output' and prefs.read_bytes() == saved
        prefs_lock.unlink()
        assert select('audio_test_output')['outcome'] == 'applied'
        client.request('rules.set_app', dict(app='test_follow', direction='playback', target='audio_test_output'))
        saved_rules = rules.read_bytes()
        rules_lock = rules.with_name(rules.name+'.lock')
        rules_lock.unlink()
        rules_lock.symlink_to(work/'unused-rule-lock')
        assert route('test_follow', 'audio_test_other_output')['outcome'] == 'persistence_failed'
        assert linked('test_follow', 'audio_test_other_output') and rules.read_bytes() == saved_rules
        rules_lock.unlink()
        assert route('test_follow', 'audio_test_output', 'default')['outcome'] == 'applied'
        print('PASS: invalid stores block audio changes; failed saves report applied defaults/routes without overwriting settings', flush=True)

        run('pw-metadata', '-n', 'sm-settings', '0', 'linking.allow-moving-streams', 'false', 'Spa:String:JSON')
        client.wait_state(lambda s: s['metadata']['sm-settings']['0:linking.allow-moving-streams']['value'] == 'false')
        rejected('route.set', dict(identity=identity('test_follow'), target=identity('audio_test_other_output'), mode='override'), {'unsupported'})
        assert linked('test_follow', 'audio_test_output')
        run('pw-metadata', '-n', 'sm-settings', '0', 'linking.allow-moving-streams', 'true', 'Spa:String:JSON')
        client.wait_state(lambda s: s['metadata']['sm-settings']['0:linking.allow-moving-streams']['value'] == 'true')
        result = client.request('scene.apply', dict(scene=dict(name='Other devices', defaults=dict(output='audio_test_other_output', input='audio_test_input'))))
        assert result['outcome'] == 'applied' and result['applied'] == 2, result
        assert default('playback') == 'audio_test_other_output' and default('recording') == 'audio_test_input'
        assert linked('test_follow', 'audio_test_other_output') and linked('test_record', 'audio_test_input')
        print('PASS: routing respects WirePlumber movement policy; scene defaults share native selection', flush=True)

        # A sink monitor can be the current source, even though the UI must
        # only offer real capture endpoints as the next default.
        stop(recorder)
        client.wait_state(lambda s: all(n['name'] != 'test_record' for n in s['nodes']))
        run('pw-metadata', '-n', 'default', '0', 'default.configured.audio.source', '{"name":"audio_test_output"}', 'Spa:String:JSON')
        until(lambda: default('recording') == 'audio_test_output')
        assert select('audio_test_input')['outcome'] == 'applied'
        assert default('recording') == 'audio_test_input'
        module = start_stream('test_module', extra='pulse.module.id=42')
        client.wait_state(lambda s: any(n['name'] == 'test_module' for n in s['nodes']))
        rejected('route.set', dict(identity=identity('test_module'), target=identity('audio_test_output'), mode='override'), {'invalid_target'})
        assert node('test_module')['serial'] not in client.state['routes']['playback']
        stop(module)
        print('PASS: capture selection can leave a sink monitor; module-owned streams reject application routes', flush=True)

        # The real policy checks above cover user behavior. A second private
        # graph owns its metadata in PipeWire and keeps fixed links, allowing
        # deterministic partial-write and concurrent-client fault injection.
        stop(follow)
        stop(pinned)
        stop(wp)
        stop(pw)
        client.wait_state(lambda s: not s.get('connected'))
        generation = client.state['generation']
        fixture = (ROOT/'test/fixtures/pipewire.conf').read_text()
        fixture = fixture.replace('audio_test_playback', 'test_follow')
        sink_block = fixture[fixture.index('    { factory = adapter args = {'):fixture.index('    { factory = adapter args = {\n        factory.name = support.null-audio-sink\n        node.name = audio_test_input')]
        config.write_text(fixture.rsplit(']',1)[0] + sink_block.replace('audio_test_output','audio_test_other_output') + sink_block.replace('audio_test_output','audio_test_third_output') + ']\n')
        pw = launch(['pipewire', '-c', str(config)])
        client.wait_state(lambda s: s.get('graphReady') and s['generation'] != generation)
        for key in ('default.audio.sink', 'default.configured.audio.sink'):
            run('pw-metadata', '-n', 'default', '0', key, '{"name":"audio_test_other_output"}', 'Spa:String:JSON')
        run('pw-link', 'test_follow:monitor_FL', 'audio_test_other_output:playback_FL')
        until(lambda: linked('test_follow', 'audio_test_other_output'))
        assert route('test_follow', 'audio_test_other_output', 'default')['outcome'] == 'applied'
        stream_id = identity('test_follow')['id']
        other = identity('audio_test_output')
        request = client.send('route.set', dict(identity=identity('test_follow'), target=other, mode='override'))
        key = str(stream_id)+':target.object'
        client.wait_state(lambda s: s['metadata']['default'].get(key,{}).get('value') == other['serial'])
        run('pw-metadata', '-n', 'default', '--', str(stream_id), 'target.node', '-1', 'Spa:Id')
        reply = client.response(request)
        assert reply.get('error',{}).get('code') == 'not_applied', reply
        assert linked('test_follow', 'audio_test_other_output')
        assert client.state['metadata']['default'][key]['value'] == '-1'

        request = client.send('route.set', dict(identity=identity('test_follow'), target=other, mode='override'))
        client.wait_state(lambda s: s['metadata']['default'].get(key,{}).get('value') == other['serial'])
        third = identity('audio_test_third_output')
        run('pw-metadata', '-n', 'default', '--', str(stream_id), 'target.object', third['serial'], 'Spa:Id')
        run('pw-metadata', '-n', 'default', '--', str(stream_id), 'target.node', str(third['id']), 'Spa:Id')
        client.wait_state(lambda s: s['metadata']['default'].get(key,{}).get('value') == third['serial']
            and s['metadata']['default'].get(str(stream_id)+':target.node',{}).get('value') == str(third['id']))
        reply = client.response(request)
        assert reply.get('error',{}).get('outcome') == 'unknown', reply
        assert client.state['metadata']['default'][key]['value'] == third['serial']
        assert linked('test_follow', 'audio_test_other_output')
        assert route('test_follow', 'audio_test_other_output', 'default')['outcome'] == 'applied'
        print('PASS: partial routing rolls back; a third-party target is preserved and reports an unknown outcome', flush=True)

        # Deny the backend metadata writes without changing the private graph.
        objects = json.loads(run('pw-dump'))
        backend_id = next(o['id'] for o in objects if o['type'] == 'PipeWire:Interface:Client'
            and o.get('info',{}).get('props',{}).get('application.id') == 'ssupt.audio-control')
        metadata_id = next(o['id'] for o in objects if o['type'] == 'PipeWire:Interface:Metadata' and o.get('props',{}).get('metadata.name') == 'default')
        run('pw-cli', 'permissions', str(backend_id), str(metadata_id), '0500')
        rejected('route.set', dict(identity=identity('test_follow'), target=identity('audio_test_output'), mode='override'), {'not_applied'})
        assert linked('test_follow', 'audio_test_other_output')
        rejected('default.set', dict(identity=identity('audio_test_output')), {'not_applied'})
        assert default('playback') == 'audio_test_other_output'
        print('PASS: rejected metadata writes do not report success and preserve the previous route/default', flush=True)
        run('pw-cli', 'permissions', str(backend_id), str(metadata_id), '0777')
        request = client.send('default.set', dict(identity=identity('audio_test_output')))
        client.wait_state(lambda s: json.loads(s['metadata']['default']['0:default.configured.audio.sink']['value'])['name'] == 'audio_test_output')
        run('pw-metadata', '-n', 'default', '0', 'default.configured.audio.sink', '{"name":"audio_test_third_output"}', 'Spa:String:JSON')
        client.wait_state(lambda s: json.loads(s['metadata']['default']['0:default.configured.audio.sink']['value'])['name'] == 'audio_test_third_output')
        reply = client.response(request)
        assert reply.get('error',{}).get('outcome') == 'unknown', reply
        assert json.loads(client.state['metadata']['default']['0:default.configured.audio.sink']['value'])['name'] == 'audio_test_third_output'
        run('pw-metadata', '-n', 'default', '0', 'default.audio.sink', '{"name":"audio_test_third_output"}', 'Spa:String:JSON')
        run('pw-link', '-d', 'test_follow:monitor_FL', 'audio_test_other_output:playback_FL')
        run('pw-link', 'test_follow:monitor_FL', 'audio_test_third_output:playback_FL')
        until(lambda: default('playback') == 'audio_test_third_output')
        until(lambda: linked('test_follow', 'audio_test_third_output'))
        print('PASS: a concurrent default selection is not overwritten by rollback', flush=True)

        other = identity('audio_test_output')
        request = client.send('route.set', dict(identity=identity('test_follow'), target=other, mode='override'))
        client.wait_state(lambda s: s['metadata']['default'].get(key,{}).get('value') == other['serial'])
        stop(pw)
        reply = client.response(request)
        assert reply.get('error',{}).get('outcome') == 'unknown', reply
        print('PASS: server loss during an admitted route reports an unknown outcome', flush=True)
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read()[-16000:], file=sys.stderr)
        if client is not None: print(json.dumps(dict(routes=client.state.get('routes'), metadata=client.state.get('metadata',{}).get('default'), replies=client.replies)), file=sys.stderr)
        raise
