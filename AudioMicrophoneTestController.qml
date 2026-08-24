import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

// Owns the complete lifecycle of the private record/playback probe. The
// advanced window only renders this state, which keeps process cancellation
// and temporary-file cleanup independent from tab and cursor code.
Item {
  id: root

  required property string scriptPath
  property var inputDevice: null
  property bool sessionActive: false

  property string testState: "idle"
  property string operation: ""
  property bool cancelled: false
  property int secondsRemaining: 0
  property string error: ""

  readonly property bool microphoneMuted: !inputDevice || !inputDevice.audio
    || inputDevice.audio.muted
  readonly property bool busy: testProc.running || stopProc.running
  readonly property real level: inputDevice && inputDevice.audio && !inputDevice.audio.muted
    ? Math.max(0, Math.min(1, Number(peakMonitor.peak || 0))) : 0

  onInputDeviceChanged: if (testState !== "idle") discard()
  onMicrophoneMutedChanged: if (microphoneMuted && testState === "recording") cancel()
  onSessionActiveChanged: if (!sessionActive && testState !== "idle") discard()

  function clearClip() {
    Quickshell.execDetached([scriptPath, "clear"])
  }

  function startRecording() {
    if (!inputDevice || !inputDevice.name || microphoneMuted || busy) return
    error = ""
    cancelled = false
    operation = "record"
    testState = "recording"
    secondsRemaining = 5
    testProc.command = [scriptPath, "record", String(inputDevice.name)]
    testProc.running = true
    countdown.restart()
  }

  function play() {
    if (testState !== "ready" || busy) return
    error = ""
    cancelled = false
    operation = "play"
    testState = "playing"
    testProc.command = [scriptPath, "play"]
    testProc.running = true
  }

  function stopRecording() {
    if (testState !== "recording" || !testProc.running || stopProc.running) return
    error = ""
    testState = "stopping"
    countdown.stop()
    secondsRemaining = 0
    stopProc.command = [scriptPath, "stop"]
    stopProc.running = true
  }

  function cancel() {
    if (!testProc.running) return
    var cancelledOperation = operation
    cancelled = true
    testProc.running = false
    countdown.stop()
    secondsRemaining = 0
    testState = cancelledOperation === "record" ? "idle" : "ready"
    if (cancelledOperation === "record") clearClip()
  }

  function discard() {
    if (stopProc.running) stopProc.running = false
    if (testProc.running) cancel()
    countdown.stop()
    secondsRemaining = 0
    testState = "idle"
    error = ""
    clearClip()
  }

  function activate() {
    if (testState === "stopping") return
    if (testState === "recording") stopRecording()
    else if (testProc.running) cancel()
    else if (testState === "ready") play()
    else startRecording()
  }

  PwNodePeakMonitor {
    id: peakMonitor
    node: root.inputDevice
    enabled: root.sessionActive && root.testState === "recording" && !!root.inputDevice
  }

  Process {
    id: testProc

    onExited: function(exitCode) {
      var completedOperation = root.operation
      countdown.stop()
      root.secondsRemaining = 0
      if (root.cancelled) {
        root.cancelled = false
        root.operation = ""
        return
      }

      if (completedOperation === "record") {
        if (exitCode === 0) {
          root.testState = "ready"
          root.error = ""
        } else {
          root.testState = "idle"
          root.error = "Could not record the microphone test"
          root.clearClip()
        }
      } else if (completedOperation === "play") {
        root.testState = "ready"
        if (exitCode !== 0) root.error = "Could not play the microphone test"
      }
      root.operation = ""
    }
  }

  Process {
    id: stopProc

    onExited: function(exitCode) {
      // A failed stop request must not strand the UI in the stopping state.
      if (exitCode !== 0 && root.testState === "stopping" && testProc.running) {
        root.error = "Could not stop the microphone test"
        root.cancel()
      }
    }
  }

  Timer {
    id: countdown
    interval: 1000
    repeat: true
    onTriggered: if (root.testState === "recording")
      root.secondsRemaining = Math.max(0, root.secondsRemaining - 1)
  }
}
