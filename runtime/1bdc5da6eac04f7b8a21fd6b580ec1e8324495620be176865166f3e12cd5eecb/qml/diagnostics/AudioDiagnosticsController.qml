import QtQuick
import Quickshell.Io
import "../core/Model.js" as Model

// Displays shared Rust samples and owns the three explicit diagnostics actions.
// Recovery is invoked only after the view's confirmation dialog; its helper
// opens Omarchy's official command in a visible terminal rather than hiding a
// possible USB-reset authorization prompt inside the shell.
Item {
  id: root

  required property string diagnosticsPath
  required property string speakerTestPath
  required property string recoveryPath
  property var service: null
  property bool sessionActive: false
  // Supplied by the host so service recovery and channel playback cannot race
  // profile, port, scene, microphone, or policy mutations.
  property bool mutationBlocked: false

  property var snapshot: Model.emptyAudioDiagnostics()
  property bool loaded: false
  property string error: ""
  property string status: ""
  property bool statusIsError: false
  property bool snapshotValid: false
  property bool speakerCancelled: false
  property bool speakerStopping: false
  property bool recoveryPending: false
  property bool refreshPending: false
  property string snapshotRevision: ""

  readonly property var serviceDiagnostics: service && service.ready && service.state.diagnostics
    ? service.state.diagnostics : ({})
  readonly property bool refreshing: refreshPending || serviceDiagnostics.refreshing === true
  readonly property bool copying: copyProc.running
  readonly property bool speakerTesting: speakerProc.running || speakerStopping
  readonly property bool recovering: recoveryProc.running || recoveryPending
  readonly property bool busy: refreshing || copying || recovering

  onSessionActiveChanged: {
    if (sessionActive) refresh()
    else stopSpeakerTest(false)
  }
  onMutationBlockedChanged: if (mutationBlocked) {
    recoveryPending = false
    stopSpeakerTest(false)
  }
  onServiceDiagnosticsChanged: syncSnapshot()

  function syncSnapshot() {
    var revision = String(serviceDiagnostics.revision || "")
    if (revision === "" || revision === snapshotRevision) return
    snapshotRevision = revision
    if (serviceDiagnostics.error) {
      loaded = true
      error = String(serviceDiagnostics.error)
    } else if (serviceDiagnostics.snapshot) {
      loadSnapshot(serviceDiagnostics.snapshot)
      error = snapshotValid ? "" : "Could not collect audio diagnostics"
    }
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

  function loadSnapshot(value) {
    var response = Model.normalizeAudioDiagnostics(value)
    snapshotValid = response.valid
    if (!response.valid) return
    snapshot = response.value
    loaded = true
  }

  function refresh() {
    if (refreshPending || copyProc.running || speakerTesting || recovering) return
    if (!service || !service.ready) {
      loaded = true
      error = "Audio service is not connected"
      return
    }
    error = ""
    refreshPending = true
    service.request("diagnostics.refresh", {}, function(_result, failure) {
      root.refreshPending = false
      root.syncSnapshot()
      if (failure) {
        root.loaded = true
        root.error = failure.message
      }
    }, { mutating: false, timeout: 35000 })
  }

  function copySupportReport() {
    if (copyProc.running || refreshing || speakerTesting || recovering
        || !snapshot.capabilities.supportReport
        || !snapshot.capabilities.clipboard) return
    copyProc.command = ["/bin/bash", diagnosticsPath, "copy-report"]
    copyProc.running = true
  }

  function toggleSpeakerTest() {
    if (speakerStopping) return
    if (speakerProc.running) {
      stopSpeakerTest(true)
      return
    }
    if (mutationBlocked || busy) return
    var sink = snapshot.defaults ? String(snapshot.defaults.output || "") : ""
    if (!snapshot.capabilities.speakerTest || sink === "") return
    speakerCancelled = false
    speakerProc.command = ["/bin/bash", speakerTestPath, sink]
    speakerProc.running = true
    showStatus("Testing each reported output channel…", false)
  }

  function stopSpeakerTest(showFeedback) {
    if (speakerStopping || !speakerProc.running) return
    speakerCancelled = true
    speakerStopping = true
    speakerProc.running = false
    if (showFeedback) showStatus("Stopped the speaker test", false)
  }

  function runRecovery() {
    if (mutationBlocked || busy || !snapshot.capabilities.recovery) return
    if (speakerProc.running || speakerStopping) {
      recoveryPending = true
      stopSpeakerTest(false)
      return
    }
    recoveryProc.command = ["/bin/bash", recoveryPath]
    recoveryProc.running = true
  }

  Connections {
    target: root.service
    function onReadyChanged() {
      if (!root.service.ready) {
        root.snapshotRevision = ""
        root.refreshPending = false
        root.error = "Audio service is not connected"
      } else if (root.sessionActive) {
        root.refresh()
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
        root.speakerStopping = false
        if (root.recoveryPending) {
          root.recoveryPending = false
          root.runRecovery()
        }
        return
      }
      root.speakerStopping = false
      root.showStatus(exitCode === 0
        ? "Finished the speaker channel test"
        : "Could not complete the speaker channel test", exitCode !== 0)
      if (root.recoveryPending) {
        root.recoveryPending = false
        root.runRecovery()
      }
    }
  }

  Process {
    id: recoveryProc
    onExited: function(exitCode) {
      root.showStatus(exitCode === 0
        ? "Finished Omarchy audio recovery"
        : "Could not complete Omarchy audio recovery", exitCode !== 0)
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
