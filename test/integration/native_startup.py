#!/usr/bin/env python3
"""Start packaged Service.qml normally and after a slow native preparation."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile

plugin = Path(sys.argv[1]).resolve()
entry = json.loads((plugin/'manifest.json').read_text())['entryPoints']['service']
binary = plugin/'bin/omarchy-audio-service'
if not shutil.which('quickshell'):
    raise SystemExit('Quickshell is required for the native startup regression test')

for delayed in (False, True):
    with tempfile.TemporaryDirectory(prefix='audio-native-startup-') as temporary:
        work = Path(temporary)
        env = dict(os.environ, XDG_RUNTIME_DIR=temporary, PIPEWIRE_RUNTIME_DIR=temporary,
                   PIPEWIRE_REMOTE='absent-native-test', PULSE_SERVER='unix:'+str(work/'absent-pulse'),
                   XDG_CONFIG_HOME=str(work/'config'), XDG_STATE_HOME=str(work/'state'),
                   XDG_CACHE_HOME=str(work/'cache'), AUDIO_CONTROL_PRIVATE_RUNTIME_DIR=temporary,
                   QT_QPA_PLATFORM='offscreen', QT_QUICK_BACKEND='software',
                   PATH=os.defpath+os.pathsep+os.environ['PATH'])
        for key in ('OMARCHY_AUDIO_CONTROL_FILE', 'OMARCHY_AUDIO_PREFERENCES_FILE',
                    'OMARCHY_AUDIO_RULES_FILE', 'OMARCHY_AUDIO_SCENES_FILE',
                    'HYPRLAND_INSTANCE_SIGNATURE', 'WAYLAND_DISPLAY'):
            env.pop(key, None)
        properties = ({'backendPreparationCommand': [sys.executable, '-c',
                       'import time; time.sleep(6); print('+repr(str(binary))+')']}
                      if delayed else {})
        qml = work/'shell.qml'
        qml.write_text('''import QtQuick
import Quickshell
ShellRoot {
  id: root
  property var client: null
  property double started: Date.now()
  Component.onCompleted: {
    var component = Qt.createComponent(SERVICE_URL)
    if (component.status !== Component.Ready) {
      console.log("STARTUP_FAILURE", component.errorString()); Qt.quit(); return
    }
    client = component.createObject(root, BACKEND_PROPERTIES)
  }
  Timer {
    interval: 50; repeat: true; running: true
    onTriggered: if (root.client && root.client.ready) {
      console.log("STARTUP_SUCCESS", Date.now() - root.started, root.client.client.info.pid)
      Qt.quit()
    }
  }
  Timer { interval: 20000; running: true; onTriggered: {
    console.log("STARTUP_FAILURE", root.client ? root.client.error : "no client"); Qt.quit()
  } }
}
'''.replace('SERVICE_URL', json.dumps((plugin/entry).as_uri()))
            .replace('BACKEND_PROPERTIES', json.dumps(properties)))
        result = subprocess.run(['dbus-run-session', '--', 'quickshell', '--no-color', '--path', str(qml)],
                                env=env, capture_output=True, text=True, timeout=25)
        output = result.stdout + result.stderr
        success = next((line.split('STARTUP_SUCCESS ', 1)[1].split()
                        for line in output.splitlines() if 'STARTUP_SUCCESS ' in line), None)
        try:
            assert result.returncode == 0 and success and 'STARTUP_FAILURE' not in output, output
            assert 'ReferenceError:' not in output and 'TypeError:' not in output and 'Binding loop' not in output, output
            if delayed:
                assert float(success[0]) >= 5900, 'Slow preparation was bypassed'
        finally:
            if success:
                # This PID comes from hello on the private temporary daemon.
                try:
                    os.kill(int(success[1]), signal.SIGTERM)
                except ProcessLookupError:
                    pass
print('PASS: packaged native startup and preparation beyond the hello deadline')
