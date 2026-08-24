import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Owns read-only health refreshes and the three explicit diagnostics actions.
// Recovery is invoked only after the view's confirmation dialog; its helper
// opens Omarchy's official command in a visible terminal rather than hiding a
// possible USB-reset authorization prompt inside the shell.
Item {
  id: root

  required property string diagnosticsPath
  required property string speakerTestPath
  required property string recoveryPath
  property bool sessionActive: false

  property var snapshot: Model.emptyAudioDiagnostics()
  property bool loaded: false
  property string error: ""
  property string status: ""
  property bool statusIsError: false
  property bool snapshotValid: false
  property bool speakerCancelled: false

  readonly property bool refreshing: snapshotProc.running
  readonly property bool copying: copyProc.running
  readonly property bool speakerTesting: speakerProc.running
  readonly property bool recovering: recoveryProc.running
  readonly property bool busy: refreshing || copying || recovering

  onSessionActiveChanged: {
    if (sessionActive) refresh()
    else stopSpeakerTest(false)
  }

  function showStatus(message, isError) {
    status = String(message || "")
    statusIsError = isError === true
    if (status !== "") statusTimer.restart()
  }

  function clearMessages() {
    error = ""
    status = ""
  }

  function loadSnapshot(raw) {
    var response = Model.parseAudioDiagnostics(raw)
    snapshotValid = response.valid
    if (!response.valid) return
    snapshot = response.value
    loaded = true
  }

  function refresh() {
    if (snapshotProc.running) return
    error = ""
    snapshotValid = false
    snapshotProc.command = [diagnosticsPath, "snapshot"]
    snapshotProc.running = true
  }

  function copySupportReport() {
    if (copyProc.running || !snapshot.capabilities.supportReport
        || !snapshot.capabilities.clipboard) return
    copyProc.command = [diagnosticsPath, "copy-report"]
    copyProc.running = true
  }

  function toggleSpeakerTest() {
    if (speakerProc.running) {
      stopSpeakerTest(true)
      return
    }
    var sink = snapshot.defaults ? String(snapshot.defaults.output || "") : ""
    if (!snapshot.capabilities.speakerTest || sink === "") return
    speakerCancelled = false
    speakerProc.command = [speakerTestPath, sink]
    speakerProc.running = true
    showStatus("Testing each reported output channel…", false)
  }

  function stopSpeakerTest(showFeedback) {
    if (!speakerProc.running) return
    speakerCancelled = true
    speakerProc.running = false
    if (showFeedback) showStatus("Stopped the speaker test", false)
  }

  function runRecovery() {
    if (recoveryProc.running || !snapshot.capabilities.recovery) return
    stopSpeakerTest(false)
    recoveryProc.command = [recoveryPath]
    recoveryProc.running = true
  }

  Process {
    id: snapshotProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadSnapshot(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.snapshotValid) {
        root.loaded = true
        root.error = "Could not collect audio diagnostics"
      } else {
        root.error = ""
      }
    }
  }

  Process {
    id: copyProc
    onExited: function(exitCode) {
      root.showStatus(exitCode === 0
        ? "Copied the privacy-conscious support report"
        : "Could not copy the support report", exitCode !== 0)
    }
  }

  Process {
    id: speakerProc
    onExited: function(exitCode) {
      if (root.speakerCancelled) {
        root.speakerCancelled = false
        return
      }
      root.showStatus(exitCode === 0
        ? "Finished the speaker channel test"
        : "Could not complete the speaker channel test", exitCode !== 0)
    }
  }

  Process {
    id: recoveryProc
    onExited: function(exitCode) {
      root.showStatus(exitCode === 0
        ? "Opened Omarchy audio recovery in a terminal"
        : "Could not open Omarchy audio recovery", exitCode !== 0)
      if (exitCode === 0) recoveryRefresh.restart()
    }
  }

  Timer {
    interval: 5000
    running: root.sessionActive
    repeat: true
    onTriggered: if (!root.busy) root.refresh()
  }

  Timer {
    id: recoveryRefresh
    interval: 4000
    onTriggered: if (root.sessionActive) root.refresh()
  }

  Timer {
    id: statusTimer
    interval: 6000
    onTriggered: root.status = ""
  }
}
