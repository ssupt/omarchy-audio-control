import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "../core/Model.js" as Model

// Owns the complete lifecycle of the private record/playback probe. The
// advanced window only renders this state, which keeps process cancellation
// and temporary-file cleanup independent from tab and cursor code.
Item {
  id: root

  required property string scriptPath
  property var inputDevice: null
  required property bool inputDeviceLive
  property bool sessionActive: false

  property string testState: "idle"
  property string operation: ""
  property bool cancelled: false
  property bool discardRequested: false
  property bool cancelNeedsClear: false
  property string cancelFinalState: "idle"
  property int secondsRemaining: 0
  property string error: ""

  readonly property bool microphoneMuted: deviceMuted()
  readonly property bool busy: testProc.running || stopProc.running || clearProc.running
    || cancelled || discardRequested
  readonly property real level: {
    try {
      if (!inputDeviceLive || !inputDevice || !inputDevice.audio
          || inputDevice.audio.muted) return 0
      var value = Number(peakMonitor.peak)
      return isFinite(value) ? Math.max(0, Math.min(1, value)) : 0
    } catch (_error) {
      return 0
    }
  }

  onInputDeviceChanged: if (testState !== "idle") discard()
  onInputDeviceLiveChanged: if (!inputDeviceLive && testState !== "idle") discard()
  onMicrophoneMutedChanged: if (microphoneMuted && testState === "recording") cancel()
  onSessionActiveChanged: if (!sessionActive && testState !== "idle") discard()

  function deviceMuted() {
    if (!inputDeviceLive || !inputDevice) return true
    try { return !inputDevice.audio || inputDevice.audio.muted === true }
    catch (_error) { return true }
  }

  function clearClip() {
    if (clearProc.running) return
    clearProc.command = ["/bin/bash", scriptPath, "clear"]
    clearProc.running = true
  }

  function startRecording() {
    var sourceName = Model.nodeName(inputDevice)
    if (!inputDeviceLive || sourceName === "" || microphoneMuted || busy) return
    error = ""
    cancelled = false
    discardRequested = false
    cancelNeedsClear = false
    operation = "record"
    testState = "recording"
    secondsRemaining = 5
    testProc.command = ["/bin/bash", scriptPath, "record", sourceName]
    testProc.running = true
    countdown.restart()
    recordWatchdog.restart()
  }

  function play() {
    if (testState !== "ready" || busy) return
    error = ""
    cancelled = false
    operation = "play"
    testState = "playing"
    testProc.command = ["/bin/bash", scriptPath, "play"]
    testProc.running = true
  }

  function stopRecording() {
    if (testState !== "recording" || !testProc.running || stopProc.running) return
    error = ""
    testState = "stopping"
    countdown.stop()
    recordWatchdog.stop()
    stopWatchdog.restart()
    secondsRemaining = 0
    stopProc.command = ["/bin/bash", scriptPath, "stop"]
    stopProc.running = true
  }

  function cancel() {
    if (!testProc.running) return
    var cancelledOperation = operation
    cancelled = true
    cancelFinalState = cancelledOperation === "record" ? "idle" : "ready"
    cancelNeedsClear = cancelledOperation === "record"
    testState = "cancelling"
    testProc.running = false
    countdown.stop()
    recordWatchdog.stop()
    stopWatchdog.stop()
    secondsRemaining = 0
  }

  function discard() {
    discardRequested = true
    if (stopProc.running) stopProc.running = false
    if (testProc.running) {
      cancel()
      return
    }
    countdown.stop()
    recordWatchdog.stop()
    stopWatchdog.stop()
    secondsRemaining = 0
    testState = "idle"
    error = ""
    discardRequested = false
    clearClip()
  }

  function activate() {
    if (testState === "stopping" || testState === "cancelling") return
    if (testState === "recording") stopRecording()
    else if (testProc.running) cancel()
    else if (testState === "ready") play()
    else startRecording()
  }

  PwNodePeakMonitor {
    id: peakMonitor
    node: root.inputDevice
    enabled: root.sessionActive && root.testState === "recording"
      && root.inputDeviceLive && !!root.inputDevice
  }

  Process {
    id: testProc

    onExited: function(exitCode) {
      var completedOperation = root.operation
      countdown.stop()
      recordWatchdog.stop()
      stopWatchdog.stop()
      root.secondsRemaining = 0
      if (root.cancelled) {
        root.cancelled = false
        root.operation = ""
        var clear = root.cancelNeedsClear || root.discardRequested
        root.testState = root.discardRequested ? "idle" : root.cancelFinalState
        root.cancelNeedsClear = false
        root.discardRequested = false
        if (clear) root.clearClip()
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

  Process {
    id: clearProc
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.sessionActive)
        root.error = "Could not discard the microphone test"
    }
  }

  Timer {
    id: countdown
    interval: 1000
    repeat: true
    onTriggered: if (root.testState === "recording")
      root.secondsRemaining = Math.max(0, root.secondsRemaining - 1)
  }

  Timer {
    id: recordWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (root.operation !== "record" || !testProc.running) return
      root.error = "Microphone test recording timed out"
      root.cancel()
    }
  }

  Timer {
    id: stopWatchdog
    interval: 3000
    repeat: false
    onTriggered: {
      if (root.testState !== "stopping" || !testProc.running) return
      root.error = "Microphone test did not stop cleanly"
      root.cancel()
    }
  }
}
