#!/usr/bin/env python3
"""Exercise actual Service.qml deadline timers against a silent test process."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]

with tempfile.TemporaryDirectory(prefix='audio-deadlines-') as temporary:
    work = Path(temporary)
    backend = work/'backend.py'
    backend.write_text('''import json, sys
def send(value):
    print(json.dumps(dict(version=1, **value)), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    if sys.argv[1] == 'handshake': continue
    if request['method'] == 'hello':
        send(dict(id=request['id'], result=dict(name='omarchy-audio-service',
            protocolVersion=1, epoch='test', buildId='', transport='jsonl-ascii',
            maxFrameBytes=262144, maxSnapshotBytes=8388608, capabilities=['state.subscribe'])))
    elif request['method'] == 'state.subscribe':
        send(dict(id=request['id'], result=dict(subscribed=True)))
        state = json.dumps(dict(epoch='test', revision='1', nodes=[]))
        send(dict(event='snapshot.begin', data=dict(bytes=len(state), parts=1)))
        send(dict(event='snapshot.part', data=dict(index=0, text=state)))
        send(dict(event='snapshot.end', data={}))
    # Leave health requests unanswered while keeping both pipes open.
''')
    env = dict(os.environ, XDG_RUNTIME_DIR=temporary,
               XDG_CONFIG_HOME=str(work/'config'), XDG_STATE_HOME=str(work/'state'),
               XDG_CACHE_HOME=str(work/'cache'), QT_QPA_PLATFORM='offscreen',
               QT_QUICK_BACKEND='software', QT_NO_XDG_DESKTOP_PORTAL='1')
    for scenario in ('handshake', 'health'):
        qml = work/'shell.qml'
        qml.write_text('''import QtQuick
import Quickshell
import CORE as Core
ShellRoot {
  Core.Service {
    id: service
    backendCommand: COMMAND
    onReadyChanged: if (ready) idleCheck.start()
    onErrorChanged: {
      if (SCENARIO === "handshake" && error.indexOf("timed out") !== -1) {
        console.log("DEADLINE_PASS handshake")
        Qt.quit()
      }
    }
  }
  Timer {
    id: idleCheck
    interval: 200
    onTriggered: {
      if (service.client.deadline !== 0 || Object.keys(service.client.pending).length !== 0) {
        console.log("DEADLINE_FAILURE idle timer remained armed")
        Qt.quit()
        return
      }
      service.request("health", {}, function(_result, error) {
        if (error && error.code === "timeout" && error.outcome === "rejected")
          console.log("DEADLINE_PASS health")
        else console.log("DEADLINE_FAILURE health did not time out")
        Qt.quit()
      }, { mutating: false, timeout: 200 })
    }
  }
  Timer { interval: 7500; running: true; onTriggered: { console.log("DEADLINE_FAILURE stalled"); Qt.quit() } }
}
'''.replace('CORE', json.dumps((ROOT/'qml/core').as_uri()))
   .replace('COMMAND', json.dumps([sys.executable, str(backend), scenario]))
   .replace('SCENARIO', json.dumps(scenario)))
        run = subprocess.run(['dbus-run-session', '--', 'quickshell', '--no-color', '--path', str(qml)],
                             env=env, capture_output=True, text=True, timeout=12)
        output = run.stdout+run.stderr
        assert run.returncode == 0 and 'DEADLINE_PASS '+scenario in output and 'DEADLINE_FAILURE' not in output, output
print('PASS: actual QML timers expire a silent handshake and health request; idle deadlines are disarmed')
