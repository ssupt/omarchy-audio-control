#!/usr/bin/env python3
"""Real socket, native PipeWire, and QML tests in a private dummy audio graph."""
import fcntl
import json
import os
import select
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

from client import Client

ROOT = Path(__file__).resolve().parents[2]
BINARY = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'backend/target/debug/omarchy-audio-service'
PACKAGED = BINARY == (ROOT/'bin/omarchy-audio-service').resolve()
ENTRY_POINTS = json.loads((ROOT/('manifest.json' if PACKAGED else 'packaging/manifest.json')).read_text())['entryPoints']


def until(predicate, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.025)
    raise AssertionError('Condition did not become true before its deadline')


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)
            raise AssertionError('Process did not shut down cleanly')


with tempfile.TemporaryDirectory(prefix='audio-integration-') as temporary:
    work = Path(temporary)
    helpers = work / 'helpers'
    helpers.mkdir()
    shutil.copy(ROOT / 'scripts/.audio-common', helpers / '.audio-common')
    for name in ('audio-profiles', 'audio-ports'):
        (helpers / name).write_text("printf '[]\\n'\n")
    (helpers / 'audio-diagnostics').write_text('''printf 'sample\\n' >>"$AUDIO_INTEGRATION_LOG.diagnostics"
printf '%s\\n' '{"version":1,"graph":{"rate":48000},"services":[],"devices":[],"routes":[],"warnings":[]}'
''')
    (helpers / 'audio-profile-set').write_text('''set -eu
source "$(dirname "$0")/.audio-common"
audio_acquire_mutation_lock
printf 'start %s\\n' "$1" >>"$AUDIO_INTEGRATION_LOG"
sleep .2
printf 'finish %s\\n' "$1" >>"$AUDIO_INTEGRATION_LOG"
''')
    (helpers / 'audio-stream-route-set').write_text('''set -eu
source "$(dirname "$0")/.audio-common"
audio_acquire_mutation_lock
printf 'routed\\n' >>"$AUDIO_INTEGRATION_LOG.routes"
''')
    binaries = work / 'bin'
    binaries.mkdir()
    (binaries / 'pw-record').write_text("""#!/usr/bin/env python3
import os, time
with open(os.environ['AUDIO_INTEGRATION_LOG']+'.capture','a') as log: log.write('record\\n')
with open(os.environ['AUDIO_INTEGRATION_LOG']+'.capture.pid','w') as log: log.write(str(os.getpid()))
for _ in range(500):
    os.write(1, b'\\0' * 960)
    time.sleep(.01)
""")
    (binaries / 'pw-play').write_text("""#!/usr/bin/env python3
import os, sys
with open(os.environ['AUDIO_INTEGRATION_LOG']+'.capture','a') as log: log.write('play\\n')
assert len(sys.stdin.buffer.read()) > 0
""")
    for path in binaries.iterdir(): path.chmod(0o755)
    env = dict(os.environ, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
               PIPEWIRE_REMOTE='audio-test', XDG_CONFIG_HOME=str(work / 'config'),
               PULSE_SERVER='unix:'+str(work/'audio-test-pulse'),
               XDG_STATE_HOME=str(work / 'state'), XDG_CACHE_HOME=str(work / 'cache'),
               AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary, OMARCHY_AUDIO_HELPERS_DIR=str(helpers),
               AUDIO_INTEGRATION_LOG=str(work / 'operations'), PATH=str(binaries)+os.pathsep+os.environ['PATH'])
    # Remove inherited per-store overrides so tests cannot touch user documents.
    for key in ('OMARCHY_AUDIO_CONTROL_FILE', 'OMARCHY_AUDIO_PREFERENCES_FILE', 'OMARCHY_AUDIO_RULES_FILE', 'OMARCHY_AUDIO_SCENES_FILE'):
        env.pop(key, None)
    # Exercise the real store watcher and mutations through a dotfiles layout.
    (work/'dotfiles').mkdir()
    (work/'config').mkdir()
    (work/'config/omarchy').symlink_to(work/'dotfiles', target_is_directory=True)
    processes = []
    clients = []
    log = open(work / 'runtime.log', 'w+')
    def pipewire():
        process = subprocess.Popen(['pipewire', '-c', str(ROOT / 'test/fixtures/pipewire.conf')], env=env, stdout=log, stderr=log)
        processes.append(process)
        until(lambda: (work / 'audio-test').exists())
        return process
    try:
        pw = pipewire()
        backend = subprocess.Popen([str(BINARY)], env=env, stdout=log, stderr=log)
        processes.append(backend)
        path = work / 'omarchy-audio-control/backend.sock'
        until(path.exists)
        assert path.stat().st_mode & 0o777 == 0o600
        a, b = Client(path), Client(path)
        clients.extend((a,b))
        a.request('state.subscribe')
        state = a.wait_state(lambda s: s.get('graphReady') and s.get('stores'))
        node = next(n for n in state['nodes'] if n['name'] == 'audio_test_output')
        identity = dict(generation=state['generation'], id=node['id'], serial=node['serial'])
        playback = next(n for n in state['nodes'] if n['name'] == 'audio_test_playback')
        playback_identity = dict(generation=state['generation'], id=playback['id'], serial=playback['serial'])
        b.request('node.level', dict(identity=playback_identity, volume=1.0))
        for method, patch in (
            ('node.level', dict(volume=1.1)),
            ('node.audio', dict(patch=dict(volumes=[.8, 1.1]))),
        ):
            failure = b.response(b.send(method, dict(identity=playback_identity, **patch)))
            assert failure.get('error', {}).get('code') == 'volume_limit', failure
        b.request('settings.set', dict(key='outputOverdrive', value=True))
        b.request('node.audio', dict(identity=playback_identity, patch=dict(volumes=[1.2, 1.5])))
        b.request('settings.set', dict(key='outputOverdrive', value=False))
        # Mute must still work if an external client left a boosted level behind.
        b.request('node.level', dict(identity=playback_identity, muted=True))
        assert b.response(b.send('node.level', dict(identity=playback_identity, volume=1.01)))['error']['code'] == 'volume_limit'
        b.request('node.level', dict(identity=playback_identity, volume=.5, muted=False))
        capture = next(n for n in state['nodes'] if n['name'] == 'audio_test_input')
        capture_identity = dict(generation=state['generation'], id=capture['id'], serial=capture['serial'])
        b.request('node.level', dict(identity=capture_identity, volume=1.2))
        b.request('node.level', dict(identity=capture_identity, volume=1.0))
        a.request('node.audio', dict(identity=identity, patch=dict(muted=True, volumes=[.3,.4])))
        assert not a.state['busy'], 'completion state must precede the command reply'
        b.request('node.level', dict(identity=identity, volume=.6))
        a.wait_state(lambda s: any(n['id'] == node['id'] and abs(n['audio']['volumes'][1]-.6)<.015 for n in s['nodes']))
        assert 'error' in b.response(b.send('node.level',dict(identity=identity,volume=1.1)))
        b.request('settings.set', dict(key='outputOverdrive',value=True))
        b.request('node.level', dict(identity=identity,volume=1.1))
        b.request('settings.set', dict(key='outputOverdrive',value=False))
        a.request('devices.alias', dict(node='audio_test_output',label='Cuffie 🎧'))
        assert a.state['stores']['rules']['devices']['aliases']['audio_test_output'] == 'Cuffie 🎧'
        a.wait_state(lambda s: s['stores']['rules']['devices']['aliases'].get('audio_test_output') == 'Cuffie 🎧')
        settings = work / 'config/omarchy/audio-control.json'
        replacement = settings.with_suffix('.temporary')
        replacement.write_text('{"version":1,"outputOverdrive":true}')
        replacement.replace(settings)
        a.wait_state(lambda s: s['stores']['settings']['outputOverdrive'] is True)
        settings.write_text('{broken')
        a.wait_state(lambda s: 'settings' in s['storeErrors'])
        assert a.state['stores']['settings']['outputOverdrive'] is True
        failure = b.response(b.send('settings.set',dict(key='outputOverdrive',value=False)))
        assert failure['error']['code'] == 'invalid_store' and settings.read_text() == '{broken'
        settings.write_text('{"version":1,"outputOverdrive":false}')
        a.wait_state(lambda s: 'settings' not in s['storeErrors'])
        scene = dict(name='Privacy', devices=[dict(name='audio_test_output',direction='output',volume=.4,balance=.5,muted=True)])
        result = b.request('scene.apply',dict(scene=scene))
        assert result['applied'] == 1 and not result['errors'], result
        captured = b.request('scene.capture',dict(name='Captured'))
        device = next(d for d in captured['devices'] if d['name'] == 'audio_test_output')
        assert device['muted'] is False and abs(device['balance']-.5)<.02, device
        # A private source identity exercises job ownership with fake sample
        # producers. No real microphone or speaker is opened by this test.
        source = next(n for n in a.state['nodes'] if n['name'] == 'audio_test_input')
        source_identity = dict(generation=a.state['generation'],id=source['id'],serial=source['serial'])
        b.request('microphone.start',dict(owner='test-window',record=True,identity=source_identity))
        until(lambda: (work/'operations.capture').exists())
        time.sleep(.15)
        b.request('microphone.stop',dict(owner='test-window',discard=False))
        a.wait_state(lambda s: s.get('microphone',{}).get('state') == 'ready')
        assert (work/'operations.capture').read_text().splitlines() == ['record']
        # Another window cannot play or discard this window's saved clip.
        other = b.response(b.send('microphone.start', dict(owner='other-window', record=False)))
        assert other['error']['code'] == 'no_clip', other
        b.request('microphone.stop', dict(owner='other-window', discard=True))
        b.request('microphone.start',dict(owner='test-window',record=False))
        a.wait_state(lambda s: s.get('microphone',{}).get('state') == 'playing')
        a.wait_state(lambda s: s.get('microphone',{}).get('state') == 'ready')
        assert (work/'operations.capture').read_text().splitlines() == ['record','play']
        # An old release or companion can keep the shared lock beyond its
        # acquisition deadline. Rules must retry before admission, then apply
        # once, without waiting for another topology change.
        with (work/'omarchy-audio-mutation.lock').open('r+') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            b.request('rules.set_app',dict(app='audio test client',direction='playback',target='audio_test_output'))
            time.sleep(5.5)
            assert not (work/'operations.routes').exists()
            fcntl.flock(lock,fcntl.LOCK_UN)
        until(lambda: (work/'operations.routes').exists())
        assert (work/'operations.routes').read_text().splitlines() == ['routed']
        b.request('rules.delete_app',dict(app='audio test client',direction='playback'))
        b.request('microphone.stop',dict(owner='test-window',discard=True))
        a.wait_state(lambda s: s.get('microphone',{}).get('state') == 'idle')
        assert b.response(b.send('microphone.start',dict(owner='test-window',record=False)))['error']['code'] == 'no_clip'
        # Closing a window while waiting on a companion's mutation lock must
        # withdraw the pending capture before any recorder process is launched.
        with (work/'omarchy-audio-mutation.lock').open('r+') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            pending = b.send('microphone.start',dict(owner='closed-window',record=True,identity=source_identity))
            a.wait_state(lambda s: s.get('microphone',{}).get('owner') == 'closed-window' and s['microphone']['state'] == 'starting')
            b.request('microphone.stop',dict(owner='closed-window',discard=True))
            fcntl.flock(lock,fcntl.LOCK_UN)
        assert b.response(pending)['error']['code'] == 'cancelled'
        assert (work/'operations.capture').read_text().splitlines() == ['record','play']
        # Two clients serialize through the complete native + helper lock boundary.
        one = a.send('adapter.run',dict(helper='audio-profile-set',generation=identity['generation'],args=['one','profile']))
        until(lambda: (work/'operations').exists())
        health = a.send('health')
        assert a.response(health)['result']['status'] == 'ok'
        assert one not in a.replies, 'A long command blocked health/cancellation on the same connection'
        two = b.send('adapter.run',dict(helper='audio-profile-set',generation=identity['generation'],args=['two','profile']))
        assert a.response(one)['result']['exitCode'] == 0
        assert b.response(two)['result']['exitCode'] == 0
        assert (work/'operations').read_text().splitlines() == ['start one','finish one','start two','finish two']
        # Admitted operations are not cancelled by a lost requesting connection.
        c = Client(path)
        c.send('adapter.run',dict(helper='audio-profile-set',generation=identity['generation'],args=['disconnected','profile']))
        until(lambda: 'start disconnected' in (work/'operations').read_text())
        c.close()
        until(lambda: 'finish disconnected' in (work/'operations').read_text())
        # A PipeWire restart changes the identity generation even when IDs repeat.
        previous = identity['generation']
        stop(pw)
        a.wait_state(lambda s: not s['connected'])
        pw = pipewire()
        a.wait_state(lambda s: s.get('graphReady') and s['generation'] != previous)
        stale = b.response(b.send('node.level',dict(identity=identity,volume=.7)))
        assert stale['error']['code'] == 'stale_graph', stale
        # Stalled unauthenticated clients are bounded; a rejected seventeenth
        # connection cannot create another dedicated OS thread.
        idle = []
        try:
            for _ in range(20):
                client = socket.socket(socket.AF_UNIX)
                client.settimeout(1)
                client.connect(str(path))
                idle.append(client)
            time.sleep(.1)
            assert len(list(Path(f'/proc/{backend.pid}/task').iterdir())) < 12
        finally:
            for client in idle: client.close()
        # Exercise the actual Service.qml against the real backend, not a JS mock.
        if shutil.which('quickshell'):
            shell_root = Path(os.environ.get('AUDIO_TEST_OMARCHY_SHELL','/usr/share/omarchy/shell'))
            weston = os.environ.get('AUDIO_TEST_WESTON') or shutil.which('weston')
            full_ui = shell_root.is_dir() and bool(weston)
            if not full_ui and os.environ.get('AUDIO_REQUIRE_QML') == '1':
                raise AssertionError('The Omarchy shell and Weston are required for the full QML runtime job')
            if not full_ui:
                print('SKIP: QML entry points (the Omarchy shell or Weston is unavailable)')
            if full_ui:
                compositor = subprocess.Popen([weston,'--backend=headless','--renderer=pixman',
                    '--shell=kiosk-shell.so','--socket=audio-test-wayland','--idle-time=0','--no-config'],
                    env=env,stdout=log,stderr=log)
                processes.append(compositor)
                until(lambda: (work/'audio-test-wayland').exists())
            if full_ui:
                # Model a stream restored above 100% before the panel is loaded.
                # With boost disabled, discovering it must restore the ceiling.
                playback = next(n for n in a.state['nodes'] if n['name'] == 'audio_test_playback')
                b.request('settings.set', dict(key='outputOverdrive', value=True))
                b.request('node.level', dict(identity=dict(generation=a.state['generation'],
                    id=playback['id'], serial=playback['serial']), volume=1.25))
                b.request('settings.set', dict(key='outputOverdrive', value=False))
                for directory in ('Ui','Commons'):
                    (work/directory).symlink_to(shell_root/directory,target_is_directory=True)
            shutil.copy(ROOT/'test/fixtures/ui-controls.qml', work/'ui-controls.qml')
            qml = work/'shell.qml'
            qml.write_text('''import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  id: root
  property var client: null
  property bool sent: false
  property bool aliasDone: false
  property bool finishing: false
  property bool sharedVerified: false
  property bool disconnected: false
  property var diagnosticsA: null
  property var diagnosticsB: null
  property var uiProbe: null
  QtObject {
    id: testBar
    property color foreground: "#eeeeee"
    property color background: "#222222"
    property color barForeground: foreground
    property color urgent: "#ff7777"
    property string fontFamily: "Sans"
    property string position: "top"
    property int barSize: 32
    property int sizeHorizontal: 32
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property var clickTargets: []
    property var activePopout: null
    property var shell: null
    function requestPopout(item) { activePopout = item }
    function releasePopout(item) { if (activePopout === item) activePopout = null }
  }
  Component.onCompleted: {
    var pathsComponent = Qt.createComponent(RUNTIME_URL)
    if (pathsComponent.status !== Component.Ready) { console.log("RUNTIME_FAILURE",pathsComponent.errorString()); Qt.quit(); return }
    var paths = pathsComponent.createObject(root)
    if (!paths || paths.scriptsDir !== SCRIPTS_PATH) { console.log("RUNTIME_FAILURE helper paths"); Qt.quit(); return }
    var component = Qt.createComponent(SERVICE_URL)
    if (component.status !== Component.Ready) { console.log("RUNTIME_FAILURE",component.errorString()); Qt.quit(); return }
    client = component.createObject(root, BACKEND_PROPERTIES)
  }
  Timer {
    interval: 50; repeat: true; running: true
    onTriggered: {
      if (root.client && root.client.ready && !root.sent) {
        root.sent = true
        UI_PROBE
        var component = Qt.createComponent(DIAGNOSTICS_URL)
        if (component.status !== Component.Ready) { console.log("RUNTIME_FAILURE", component.errorString()); Qt.quit(); return }
        var properties = {service: root.client, sessionActive: true,
          diagnosticsPath: "/must-not-launch-snapshot", speakerTestPath: "/unused", recoveryPath: "/unused"}
        root.diagnosticsA = component.createObject(root, properties)
        root.diagnosticsB = component.createObject(root, properties)
        if (!root.diagnosticsA || !root.diagnosticsB) { console.log("RUNTIME_FAILURE diagnostics creation"); Qt.quit(); return }
        root.diagnosticsA.refresh()
        root.diagnosticsB.refresh()
        root.client.request("devices.alias", {node:"qml-test",label:"QML ✓"}, function(_result,error) {
          if (error) { console.log("RUNTIME_FAILURE", JSON.stringify(error)); Qt.quit(); return }
          root.aliasDone = true
        })
      }
      if ((!root.uiProbe || root.uiProbe.done) && root.aliasDone && !root.finishing && root.diagnosticsA.loaded && root.diagnosticsB.loaded
          && !root.diagnosticsA.refreshing && !root.diagnosticsB.refreshing) {
        if (root.diagnosticsA.error || root.diagnosticsB.error
            || root.diagnosticsA.snapshot.graph.rate !== 48000 || root.diagnosticsB.snapshot.graph.rate !== 48000) {
          if (!root.sharedVerified) {
            console.log("RUNTIME_FAILURE shared diagnostics", root.diagnosticsA.error, root.diagnosticsB.error)
            Qt.quit(); return
          }
        } else if (!root.sharedVerified) {
          root.sharedVerified = true
          crashProc.command = ["/bin/kill", "-KILL", String(root.client.client.info.pid)]
          crashProc.running = true
        } else if (root.disconnected && root.client.ready) {
          root.finishing = true
          console.log("RUNTIME_SUCCESS shared diagnostics, controls and reconnect")
          quitTimer.start()
        }
        if (root.sharedVerified && !root.client.ready && !root.disconnected) {
          if (!root.diagnosticsA.error || !root.diagnosticsB.error) {
            console.log("RUNTIME_FAILURE missing disconnected diagnostic status")
            Qt.quit(); return
          }
          root.disconnected = true
        }
      }
    }
  }
  Timer { id: quitTimer; interval: 500; onTriggered: Qt.quit() }
  Process { id: crashProc }
  Timer { interval: 25000; running: true; onTriggered: { console.log("RUNTIME_FAILURE timeout"); Qt.quit() } }
}
'''.replace('DIAGNOSTICS_URL', json.dumps(((ROOT/ENTRY_POINTS['service']).parent.parent/'diagnostics/AudioDiagnosticsController.qml').as_uri())).replace('BACKEND_PROPERTIES', json.dumps({} if PACKAGED else {'backendCommand':[str(BINARY),'--plugin']})).replace('RUNTIME_URL', json.dumps((ROOT/ENTRY_POINTS['service']).with_name('AudioRuntime.qml').as_uri())).replace('SCRIPTS_PATH', json.dumps(str(ROOT/'scripts'))).replace('SERVICE_URL', json.dumps((ROOT/ENTRY_POINTS['service']).as_uri())).replace('UI_PROBE',
    ('var panel = Qt.createComponent('+json.dumps((ROOT/ENTRY_POINTS['barWidget']).as_uri())+'); '
     'var advanced = Qt.createComponent('+json.dumps((ROOT/ENTRY_POINTS['panel']).as_uri())+'); '
     'if (panel.status !== Component.Ready || advanced.status !== Component.Ready) { '
     'console.log("RUNTIME_FAILURE",panel.errorString(),advanced.errorString()); Qt.quit(); return } '
     'var panelObject = panel.createObject(root,{service:root.client,bar:testBar,manageIpc:false}); '
     'var advancedObject = advanced.createObject(root,{service:root.client}); '
     'var probe = Qt.createComponent("ui-controls.qml"); '
     'if (!panelObject || !advancedObject || probe.status !== Component.Ready) {'
     'console.log("RUNTIME_FAILURE entry point creation",probe.errorString()); Qt.quit(); return } '
     'root.uiProbe = probe.createObject(root,{panel:panelObject,advanced:advancedObject}); '
     'if (!root.uiProbe) { console.log("RUNTIME_FAILURE UI probe creation"); Qt.quit(); return }') if full_ui else ''))
            qmlenv = dict(env,QT_QPA_PLATFORM='wayland' if full_ui else 'offscreen',QT_QUICK_BACKEND='software')
            qmlenv.pop('HYPRLAND_INSTANCE_SIGNATURE',None)
            qmlenv.pop('WAYLAND_DISPLAY',None)
            if full_ui: qmlenv['WAYLAND_DISPLAY']='audio-test-wayland'
            run = subprocess.run(['dbus-run-session','--','quickshell','--no-color','--path',str(qml)], env=qmlenv, capture_output=True,text=True,timeout=28)
            output = run.stdout + run.stderr
            assert run.returncode == 0 and 'RUNTIME_SUCCESS' in output and 'RUNTIME_FAILURE' not in output and 'ReferenceError:' not in output and 'TypeError:' not in output and 'Binding loop' not in output, output
            assert (work/'operations.diagnostics').read_text().splitlines() == ['sample', 'sample'], output
            if full_ui:
                assert 'RUNTIME_UI_SUCCESS' in output, output
                print('PASS: volume limits, boost reset, deferred tabs, shared scenes and pointer cancellation')
                print('PASS: actual Service.qml and both QML entry points on a private headless compositor')
            # Disabling/removing the QML service closes its relay. The private
            # daemon must retire without an installed systemd service.
            info = json.loads(subprocess.check_output([str(BINARY),'--build-info']))
            plugin_socket = work/'omarchy-audio-control'/('backend-'+info['buildId'][:24]+'.sock')
            until(lambda: not plugin_socket.exists(), timeout=36)
        elif os.environ.get('AUDIO_REQUIRE_QML') == '1':
            raise AssertionError('Quickshell is required for this runtime job')
        else:
            print('SKIP: actual QML runtime (Quickshell is not installed)')
        # A hard daemon crash must kill an active recorder in the kernel; a
        # five-second sample limit alone does not establish immediate cleanup.
        source = next(n for n in a.state['nodes'] if n['name'] == 'audio_test_input')
        pidfile = work/'operations.capture.pid'
        pidfile.unlink(missing_ok=True)
        b.request('microphone.start',dict(owner='crash-test',record=True,
            identity=dict(generation=a.state['generation'],id=source['id'],serial=source['serial'])))
        until(lambda: pidfile.exists() and pidfile.read_text().strip())
        recorder = os.pidfd_open(int(pidfile.read_text()))
        try:
            backend.kill()
            backend.wait(timeout=3)
            assert select.select([recorder],[],[],2)[0], 'Recorder survived its supervisor crash'
        finally:
            os.close(recorder)
        for client in clients: client.close()
        clients.clear()
        backend = subprocess.Popen([str(BINARY)], env=env, stdout=log, stderr=log)
        processes.append(backend)
        def restarted():
            try:
                probe = Client(path)
                probe.close()
                return True
            except (OSError, AssertionError): return False
        until(restarted)
        stop(backend)
        assert not path.exists(), 'Standalone socket was not cleaned up'
        print('PASS: private native graph, identity restart, shared transactions, file watches, and QML IPC')
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read()[-10000:], file=sys.stderr)
        raise
    finally:
        for client in clients: client.close()
        for process in reversed(processes): stop(process)
        log.close()
