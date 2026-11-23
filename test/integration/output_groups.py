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

    def player_sink(app='Group Test Player'):
        streams = json.loads(run('pactl', '-f', 'json', 'list', 'sink-inputs'))
        return next((s['sink'] for s in streams
                     if s['properties'].get('application.name') == app), None)

    def group_inputs(group_name):
        group = next(s for s in sinks() if s['name'] == group_name)
        streams = json.loads(run('pactl', '-f', 'json', 'list', 'sink-inputs'))
        return [s for s in streams if s['owner_module'] == str(group['owner_module'])
                and s['properties'].get('target.object') in
                ('audio_test_left', 'audio_test_right')]

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
        backend = launch([str(BINARY)])
        path = work/'omarchy-audio-control/backend.sock'
        until(path.exists)
        client = Client(path)
        cleanup.callback(client.close)
        client.request('state.subscribe')
        state = client.wait_state(lambda s: s.get('graphReady') and
            any(n['name'] == 'audio_test_right' for n in s['nodes']))

        def change(action, **params):
            reply = client.response(client.send('groups.'+action, dict(
                generation=state['generation'], **params)))
            if reply.get('error', {}).get('code') == 'busy':
                return False
            assert 'error' not in reply, reply
            return reply['result']['id']

        group_id = until(lambda: change('create', name='Desk',
            members=['audio_test_left', 'audio_test_right']))
        group_name = 'omarchy_audio_group_'+group_id
        group = until(lambda: next((s for s in sinks() if s['name'] == group_name), None))
        rules_path = work/'config/omarchy/audio-rules.json'
        original_rules = rules_path.read_bytes()

        def rejected(action, **params):
            reply = client.response(client.send('groups.'+action,
                dict(generation=state['generation'], **params)))
            assert 'error' in reply and reply['error']['outcome'] == 'rejected', reply
            return reply['error']['code']

        for name, members in [('Solo', ['audio_test_left']),
                ('Duplicate', ['audio_test_left', 'audio_test_left']),
                ('Recursive', ['audio_test_left', group_name]),
                ('Virtual', ['audio_test_left', 'audio_test_output']),
                ('desk', ['audio_test_left', 'audio_test_right'])]:
            rejected('create', name=name, members=members)
        assert rules_path.read_bytes() == original_rules
        assert client.response(client.send('groups.delete', dict(id=group_id,
            generation='previous-server')))['error']['code'] == 'stale_target'
        assert rules_path.read_bytes() == original_rules

        third = member('audio_test_third')
        until(lambda: any(s['name'] == 'audio_test_third' for s in sinks()))
        client.wait_state(lambda s: any(n['name'] == 'audio_test_third' and n['state'] for n in s['nodes']))
        # Rapid replacements race native subscriptions to disappearing nodes.
        # Their ENOENT replies must not reconnect the service or invalidate the
        # generation used by the following rollback and routing operations.
        for _ in range(8):
            for other in ('audio_test_third', 'audio_test_right'):
                members = ['audio_test_left', other]
                change('update', id=group_id, name='Desk', members=members)
                assert json.loads(rules_path.read_text())['outputGroups'][0]['members'] == members
                assert client.state['generation'] == state['generation']
        run('pactl', 'set-default-sink', 'audio_test_left')
        saved = rules_path.read_bytes()
        lock = rules_path.with_suffix('.json.lock')
        lock.unlink(missing_ok=True)
        lock.symlink_to(work/'foreign-lock')
        try:
            rejected('update', id=group_id, name='Changed', members=['audio_test_left', 'audio_test_third'])
            assert rules_path.read_bytes() == saved
            restored = until(lambda: next((s for s in sinks() if s['name'] == group_name), None))
            modules = json.loads(run('pactl', '-f', 'json', 'list', 'modules'))
            arguments = next(m['argument'] for m in modules if 'sink_name='+group_name in m.get('argument', ''))
            assert 'sinks=audio_test_left,audio_test_right' in arguments, arguments
            rejected('delete', id=group_id)
            assert rules_path.read_bytes() == saved and any(s['name'] == group_name for s in sinks())
            rejected('create', name='Failed save', members=['audio_test_right', 'audio_test_third'])
            assert len([s for s in sinks() if s['name'].startswith('omarchy_audio_group_')]) == 1
            assert not (work/'foreign-lock').exists()
        finally:
            lock.unlink()
        print('PASS: typed group validation, member updates and create/update/delete persistence rollback', flush=True)

        current_group = next(s for s in sinks() if s['name'] == group_name)
        current_serial = str(current_group['properties']['object.serial'])
        group_node = client.wait_state(lambda s: any(n['name'] == group_name and n['state']
            and n['serial'] == current_serial for n in s['nodes']))
        group_node = next(n for n in group_node['nodes'] if n['name'] == group_name and n['serial'] == current_serial)
        assert client.request('default.set', dict(identity=dict(generation=state['generation'],
            id=group_node['id'], serial=group_node['serial'])))['outcome'] == 'applied'
        until(lambda: run('pactl', 'get-default-sink').strip() == group_name)
        rejected('update', id=group_id, name='Busy', members=['audio_test_left', 'audio_test_third'])
        rejected('delete', id=group_id)
        module_before_rename = next(s for s in sinks() if s['name'] == group_name)['owner_module']
        change('update', id=group_id, name='Renamed desk', members=['audio_test_left', 'audio_test_right'])
        assert next(s for s in sinks() if s['name'] == group_name)['owner_module'] == module_before_rename
        group = next(s for s in sinks() if s['name'] == group_name)
        stop(third)
        client.request('rules.set_app', dict(app='offline player', direction='playback', target=group_name))
        run('pactl', 'set-default-sink', 'audio_test_left')
        rejected('delete', id=group_id)
        client.request('rules.delete_app', dict(app='offline player', direction='playback'))
        run('pactl', 'set-default-sink', group_name)
        print('PASS: active groups allow renaming but reject replacement/deletion; saved routes protect offline groups', flush=True)
        zero = cleanup.enter_context(open('/dev/zero', 'rb'))
        player = launch(['pw-play', '--raw', '--rate=48000', '--channels=2', '--format=s16',
            '--properties=application.name="Group Test Player" node.name=audio_test_player', '-'], stdin=zero)
        until(lambda: player_sink() == group['index'])
        documents = {p.name: p.read_bytes() for p in (work/'config/omarchy').glob('audio-*.json')}

        outputs = until(lambda: group_inputs(group_name) if len(group_inputs(group_name)) == 2 else None)
        for output in outputs:
            run('pactl', 'set-sink-input-mute', str(output['index']), '1')
        assert all(s['mute'] for s in group_inputs(group_name))

        module_before_restart = next(s for s in sinks() if s['name'] == group_name)['owner_module']
        client.close()
        client = None
        stop(backend)
        assert next(s for s in sinks() if s['name'] == group_name)['owner_module'] == module_before_restart
        assert player_sink() == group['index'] and player.poll() is None
        backend = launch([str(BINARY)])
        until(path.exists)
        client = Client(path)
        cleanup.callback(client.close)
        client.request('state.subscribe')
        state = client.wait_state(lambda s: s.get('graphReady') and any(n['name'] == group_name for n in s['nodes']))
        assert next(s for s in sinks() if s['name'] == group_name)['owner_module'] == module_before_restart
        until(lambda: len(group_inputs(group_name)) == 2
              and all(not s['mute'] for s in group_inputs(group_name)))
        assert all((work/'config/omarchy'/name).read_bytes() == data for name, data in documents.items())
        print('PASS: service restart preserves group playback and unmutes its internal outputs', flush=True)

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
        until(lambda: len(group_inputs(group_name)) == 2
              and all(not s['mute'] for s in group_inputs(group_name)))
        assert player.poll() is None
        assert all((work/'config/omarchy'/name).read_bytes() == data for name, data in documents.items())
        print('PASS: reconnect restores the selected group and playback without rewriting saved settings', flush=True)

        # Finding 6: scenes capture and restore a healthy owned output group,
        # and report it as skipped when the saved group is unavailable.
        captured_group_scene = client.request('scene.capture', dict(name='Group Scene'))
        assert captured_group_scene['defaults']['output'] == group_name, captured_group_scene
        left_node = next(n for n in client.state['nodes'] if n['name'] == 'audio_test_left')
        assert client.request('default.set', dict(identity=dict(generation=client.state['generation'],
            id=left_node['id'], serial=left_node['serial'])))['outcome'] == 'applied'
        until(lambda: run('pactl', 'get-default-sink').strip() == 'audio_test_left')
        applied_group_scene = client.request('scene.apply', dict(scene=captured_group_scene))
        assert applied_group_scene['outcome'] == 'applied' and not applied_group_scene['errors'], applied_group_scene
        assert not applied_group_scene['skipped'], applied_group_scene
        until(lambda: run('pactl', 'get-default-sink').strip() == group_name
              and player_sink() == group['index'])

        stop(right)
        until(lambda: all(s['name'] != group_name for s in sinks()))
        skipped_group_scene = client.request('scene.apply', dict(scene=captured_group_scene))
        assert group_name in skipped_group_scene['skipped'], skipped_group_scene
        print('PASS: scenes round-trip an owned output group and skip it when unavailable', flush=True)
        # An explicit selection during fallback replaces the remembered group.
        run('pactl', 'set-default-sink', 'audio_test_output')
        other = next(s for s in sinks() if s['name'] == 'audio_test_output')
        until(lambda: player_sink() == other['index'])
        right = member('audio_test_right')
        until(lambda: any(s['name'] == group_name for s in sinks()))
        assert run('pactl', 'get-default-sink').strip() == other['name']
        assert player_sink() == other['index'] and player.poll() is None
        print('PASS: reconnect preserves an output explicitly selected during fallback', flush=True)
        stop(player)
        client.request('devices.alias', dict(node=group_name, label='Desk alias'))
        client.request('devices.flag', dict(node=group_name, flag='favorite', value=True))
        client.request('devices.flag', dict(node=group_name, flag='hidden', value=True))
        change('delete', id=group_id)
        until(lambda: all(s['name'] != group_name for s in sinks()))
        assert json.loads(rules_path.read_text())['outputGroups'] == []
        print('PASS: unused groups delete both the server module and saved definition', flush=True)
        final_rules = json.loads(rules_path.read_text())
        assert group_name not in final_rules['devices']['aliases']
        assert group_name not in final_rules['devices']['favorites']
        assert group_name not in final_rules['devices']['hidden']

        # Finding 4: explicitly selecting the current fallback output after a
        # preferred device disconnects must replace WirePlumber's configured default.
        dock = member('audio_test_dock')
        until(lambda: any(s['name'] == 'audio_test_dock' for s in sinks()))
        client.wait_state(lambda s: any(n['name'] == 'audio_test_dock' and n['state'] for n in s['nodes']))
        dock_node = next(n for n in client.state['nodes'] if n['name'] == 'audio_test_dock')
        assert client.request('default.set', dict(identity=dict(generation=client.state['generation'],
            id=dock_node['id'], serial=dock_node['serial'])))['outcome'] == 'applied'
        until(lambda: run('pactl', 'get-default-sink').strip() == 'audio_test_dock')
        stop(dock)
        until(lambda: all(s['name'] != 'audio_test_dock' for s in sinks()))
        until(lambda: run('pactl', 'get-default-sink').strip() != 'audio_test_dock')
        fallback_name = run('pactl', 'get-default-sink').strip()
        client.wait_state(lambda s: json.loads(s['metadata']['default']['0:default.audio.sink']['value'])['name'] == fallback_name)
        assert json.loads(client.state['metadata']['default']['0:default.configured.audio.sink']['value'])['name'] == 'audio_test_dock'
        fallback_node = next(n for n in client.state['nodes'] if n['name'] == fallback_name)
        assert client.request('default.set', dict(identity=dict(generation=client.state['generation'],
            id=fallback_node['id'], serial=fallback_node['serial'])))['outcome'] == 'applied'
        client.wait_state(lambda s: json.loads(s['metadata']['default']['0:default.configured.audio.sink']['value'])['name'] == fallback_name)
        dock = member('audio_test_dock')
        until(lambda: any(s['name'] == 'audio_test_dock' for s in sinks()))
        time.sleep(0.5)
        assert run('pactl', 'get-default-sink').strip() == fallback_name
        assert json.loads(client.state['metadata']['default']['0:default.configured.audio.sink']['value'])['name'] == fallback_name
        stop(dock)
        until(lambda: all(s['name'] != 'audio_test_dock' for s in sinks()))
        print('PASS: explicit fallback selection replaces WirePlumber preferred default across reconnect', flush=True)

        # Finding 5: restoring a rules file with changed group members must rebuild
        # an unused group to match the actual destinations and report pending when in use.
        third = member('audio_test_third')
        until(lambda: any(s['name'] == 'audio_test_third' for s in sinks()))
        client.wait_state(lambda s: any(n['name'] == 'audio_test_third' and n['state'] for n in s['nodes']))
        def actual_group_targets(target_group_name):
            all_sinks = sinks()
            by_index = {s['index']: s['name'] for s in all_sinks}
            group_sink = next((s for s in all_sinks if s['name'] == target_group_name), None)
            if not group_sink:
                return set()
            streams = json.loads(run('pactl', '-f', 'json', 'list', 'sink-inputs'))
            return {by_index.get(s['sink']) for s in streams
                    if s['owner_module'] == str(group_sink['owner_module'])}
        restored_id = until(lambda: change('create', name='Restored group',
            members=['audio_test_left', 'audio_test_right']))
        restored_name = 'omarchy_audio_group_' + restored_id
        until(lambda: actual_group_targets(restored_name) == {'audio_test_left', 'audio_test_right'})
        run('pactl', 'set-default-sink', 'audio_test_left')
        until(lambda: run('pactl', 'get-default-sink').strip() == 'audio_test_left')
        edited = json.loads(rules_path.read_text())
        edited['outputGroups'][0]['members'] = ['audio_test_left', 'audio_test_third']
        rules_path.write_text(json.dumps(edited))
        until(lambda: actual_group_targets(restored_name) == {'audio_test_left', 'audio_test_third'})
        # Now make the group active (in use) and restore rules changing members back.
        run('pactl', 'set-default-sink', restored_name)
        until(lambda: run('pactl', 'get-default-sink').strip() == restored_name)
        edited['outputGroups'][0]['members'] = ['audio_test_left', 'audio_test_right']
        rules_path.write_text(json.dumps(edited))
        client.wait_state(lambda s: restored_id in (s.get('pendingGroups') or []))
        assert actual_group_targets(restored_name) == {'audio_test_left', 'audio_test_third'}
        # Submitting the displayed membership while the running module still has old members must fail while in use.
        rejected('update', id=restored_id, name='Restored group', members=['audio_test_left', 'audio_test_right'])
        assert actual_group_targets(restored_name) == {'audio_test_left', 'audio_test_third'}
        # Once no longer in use, reconciliation rebuilds the group to the saved members.
        run('pactl', 'set-default-sink', 'audio_test_left')
        until(lambda: run('pactl', 'get-default-sink').strip() == 'audio_test_left')
        until(lambda: actual_group_targets(restored_name) == {'audio_test_left', 'audio_test_right'})
        client.wait_state(lambda s: restored_id not in (s.get('pendingGroups') or []))
        change('delete', id=restored_id)
        until(lambda: all(s['name'] != restored_name for s in sinks()))
        stop(third)
        until(lambda: all(s['name'] != 'audio_test_third' for s in sinks()))
        final_rules = json.loads(rules_path.read_text())
        print('PASS: restored group membership rebuilds unused modules and reports pending changes while in use', flush=True)

        for use in ('default', 'stream'):
            deferred_id = until(lambda: change('create', name='Deferred cleanup',
                members=['audio_test_left', 'audio_test_right']))
            deferred_name = 'omarchy_audio_group_'+deferred_id
            deferred_sink = until(lambda: next((s for s in sinks() if s['name'] == deferred_name), None))
            if use == 'default':
                run('pactl', 'set-default-sink', deferred_name)
                until(lambda: run('pactl', 'get-default-sink').strip() == deferred_name)
            else:
                pinned = launch(['pw-play', '--raw', '--rate=48000', '--channels=2', '--format=s16',
                    '--target='+deferred_name,
                    '--properties=application.name="Orphan Test Player" node.name=audio_test_orphan_player',
                    '-'], stdin=zero)
                until(lambda: player_sink('Orphan Test Player') == deferred_sink['index'])
            # External edits and Bluetooth forget can remove a definition while
            # the module is in use. The first cleanup must leave playback alone.
            rules_path.write_text(json.dumps(final_rules))
            client.wait_state(lambda s: s['stores']['rules']['outputGroups'] == [])
            time.sleep(1.5)
            assert any(s['name'] == deferred_name for s in sinks())
            if use == 'default':
                run('pactl', 'set-default-sink', 'audio_test_left')
                until(lambda: run('pactl', 'get-default-sink').strip() == 'audio_test_left')
            else:
                client.request('health')
                stream = next(n for n in client.state['nodes'] if n['name'] == 'audio_test_orphan_player')
                target = next(n for n in client.state['nodes'] if n['name'] == 'audio_test_right')
                def identity(node):
                    return dict(generation=client.state['generation'], id=node['id'], serial=node['serial'])
                client.request('route.set', dict(identity=identity(stream), target=identity(target), mode='override'))
                until(lambda: player_sink('Orphan Test Player') == next(s['index'] for s in sinks()
                    if s['name'] == 'audio_test_right'))
            until(lambda: all(s['name'] != deferred_name for s in sinks()))
            if use == 'stream':
                assert pinned.poll() is None, 'Cleanup stopped the rerouted player'
                stop(pinned)
        print('PASS: orphan cleanup retries after default changes and stream moves without replacing nodes', flush=True)

        foreign_id = 'ffffffffffffffff'
        foreign_name = 'omarchy_audio_group_'+foreign_id
        foreign_module = run('pactl', 'load-module', 'module-null-sink', 'sink_name='+foreign_name).strip()
        until(lambda: any(s['name'] == foreign_name for s in sinks()))
        collision = dict(id=foreign_id, name='Foreign collision', sink=foreign_name,
                         members=['audio_test_left', 'audio_test_right'])
        final_rules['outputGroups'] = [collision]
        rules_path.write_text(json.dumps(final_rules))
        client.wait_state(lambda s: s.get('stores', {}).get('rules', {}).get('outputGroups') == [collision])
        rejected('delete', id=foreign_id)
        assert any(s['name'] == foreign_name for s in sinks())
        run('pactl', 'unload-module', foreign_module)
        final_rules['outputGroups'] = []
        rules_path.write_text(json.dumps(final_rules))
        client.wait_state(lambda s: s.get('stores', {}).get('rules', {}).get('outputGroups') == [])
        orphan_id = 'eeeeeeeeeeeeeeee'
        orphan_name = 'omarchy_audio_group_'+orphan_id
        run('pactl', 'load-module', 'module-combine-sink', 'sink_name='+orphan_name,
            'sinks=audio_test_left,audio_test_right',
            'sink_properties=device.description=Omarchy_Output_Group application.id=ssupt.audio-control '
            'node.virtual=true omarchy.audio.group.id='+orphan_id, 'latency_compensate=true')
        until(lambda: all(s['name'] != orphan_name for s in sinks()))
        assert json.loads(rules_path.read_text())['outputGroups'] == []
        print('PASS: foreign name collisions remain untouched; owned orphan groups are reconciled', flush=True)
        # A speaker-tuning sink has its own identity but controls the hardware
        # downstream. Hide the pinned hardware even while the tuning is idle.
        tuning = launch(['pw-loopback', '--capture-props=media.class=Audio/Sink '
            'node.name=omarchy_speaker_tuning node.virtual=true device.class=filter',
            '--playback-props=node.name=omarchy_speaker_tuning_output '
            'target.object=audio_test_left node.passive=true node.dont-fallback=true node.linger=true'])
        state = client.wait_state(lambda s: s.get('outputs', {}).get('availability', {}).get('audio_test_left') is False
            and any(n['name'] == 'omarchy_speaker_tuning' and n['state'] for n in s['nodes']))
        tuning_node = next(n for n in state['nodes'] if n['name'] == 'omarchy_speaker_tuning')
        assert client.request('default.set', dict(identity=dict(generation=state['generation'],
            id=tuning_node['id'], serial=tuning_node['serial'])))['outcome'] == 'applied'
        player = launch(['pw-play', '--raw', '--rate=48000', '--channels=2', '--format=s16',
            '--properties=application.name="Tuning Test Player" node.name=audio_test_tuning_player', '-'], stdin=zero)
        left = next(n for n in state['nodes'] if n['name'] == 'audio_test_left')
        client.wait_state(lambda s: (s['outputs'].get('volume') or {}).get('source', {}).get('id') == tuning_node['id']
            and s['outputs']['volume']['target']['id'] == left['id'])
        gain_before = next(s for s in sinks() if s['name'] == 'omarchy_speaker_tuning')['volume']
        target = client.state['outputs']['volume']['target']
        client.request('node.level', dict(identity=target, volume=.31))
        client.wait_state(lambda s:any(n['id'] == left['id'] and abs(max(n['audio']['volumes'])-.31)<.01 for n in s['nodes']))
        assert next(s for s in sinks() if s['name'] == 'omarchy_speaker_tuning')['volume'] == gain_before
        run('pactl', 'set-default-sink', 'audio_test_right')
        right_id = next(n['id'] for n in client.state['nodes'] if n['name'] == 'audio_test_right')
        client.wait_state(lambda s:(s['outputs'].get('volume') or {}).get('source', {}).get('id') == right_id
            and s['outputs']['volume']['target']['id'] == right_id)
        assert client.state['outputs']['availability']['audio_test_left'] is False
        stop(player)
        stop(tuning)
        client.wait_state(lambda s:s['outputs']['availability'].get('audio_test_left') is True)
        assert 'adapter.run' not in client.request('hello')['capabilities']
        for helper in ('audio-resolve-output-sink', 'audio-sink-availability'):
            reply = client.response(client.send('adapter.run', dict(helper=helper, args=[])))
            assert reply['error']['code'] == 'method_not_found', reply
        print('PASS: native tuning visibility, physical volume, default changes and helper retirement', flush=True)

        forgotten = 'bluez_output.AA_BB_CC_DD_EE_FF.1'
        paired = 'bluez_output.11_22_33_44_55_66.1'
        forgotten_group = dict(id='abcdef0123456789', name='Forgotten headset',
            sink='omarchy_audio_group_abcdef0123456789',
            members=['audio_test_left', forgotten])
        saved = json.loads(rules_path.read_text())
        saved['outputGroups'] = [forgotten_group]
        saved['appRules'] = [dict(app='old', direction='playback', target=forgotten_group['sink']),
            dict(app='other', direction='playback', target=paired)]
        saved['devices']['aliases'][forgotten] = 'Old headset'
        rules_path.write_text(json.dumps(saved))
        client.wait_state(lambda s: s['stores']['rules']['outputGroups'] == [forgotten_group])
        # An offline member alone preserves its setup; only the confirmed
        # Bluetooth forget request removes the group and its dependent pin.
        assert json.loads(rules_path.read_text())['outputGroups'] == [forgotten_group]
        def forget():
            reply = client.response(client.send('devices.forget',
                dict(address='AA:BB:CC:DD:EE:FF')))
            if reply.get('error', {}).get('code') == 'busy': return False
            assert 'error' not in reply, reply
            return True
        until(forget)
        remaining = json.loads(rules_path.read_text())
        assert remaining['outputGroups'] == []
        assert [rule['app'] for rule in remaining['appRules']] == ['other']
        assert forgotten not in remaining['devices']['aliases']
        print('PASS: explicit Bluetooth forget removes dependent routes; disconnect preserves them', flush=True)
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read()[-10000:], file=sys.stderr)
        raise
