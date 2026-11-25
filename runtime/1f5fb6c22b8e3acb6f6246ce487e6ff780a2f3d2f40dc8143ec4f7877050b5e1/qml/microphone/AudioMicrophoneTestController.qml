import QtQuick
import Quickshell.Services.Pipewire
import "../core/Model.js" as Model

// Explicit record/play controls; Rust supervises children and owns the private
// in-memory clip. Closing this view discards it and never triggers playback.
Item {
  id: root
  property var service: null
  property var inputDevice: null
  required property bool inputDeviceLive
  property bool sessionActive: false
  readonly property string owner: "microphone-" + Date.now() + "-" + Math.random()
  property bool pending: false
  property bool cancelPending: false
  property bool pendingRecord: false
  property string localError: ""
  property int secondsRemaining: 0
  readonly property var job: service && service.ready && service.state.microphone
    && service.state.microphone.owner === owner ? service.state.microphone : ({})
  readonly property string rawTestState: String(job.state || "idle")
  readonly property string testState: cancelPending && (pending || rawTestState === "starting")
    ? "cancelling" : rawTestState
  readonly property string error: localError || String(job.error || "")
  readonly property bool microphoneMuted: !inputDeviceLive || !inputDevice
    || !inputDevice.audio || inputDevice.audio.muted
  readonly property bool busy: pending || testState === "starting" || testState === "cancelling"
    || testState === "recording" || testState === "playing"
  readonly property real level: microphoneMuted ? 0 : Math.max(0, Math.min(1, Number(peakMonitor.peak) || 0))
  onRawTestStateChanged: if (!pending && (rawTestState === "idle" || rawTestState === "ready")) cancelPending = false

  function start(record) {
    if (!service || !service.ready || pending) return
    if (record && (microphoneMuted || !sessionActive)) return
    var identity = record ? service.identityForNode(inputDevice) : null
    if (record && !identity) return
    pending = true
    pendingRecord = !!record
    cancelPending = false
    localError = ""
    secondsRemaining = record ? 5 : 0
    service.request("microphone.start", { owner: owner, record: record, identity: identity }, function(_result, error) {
      var wasCancelled = root.cancelPending
      root.pending = false
      root.cancelPending = false
      if (error && wasCancelled && error.code === "cancelled") {
        root.localError = ""
      } else {
        root.localError = error ? error.message : ""
      }
    })
  }
  function stop(discard) {
    if (!service || !service.ready) return
    if (rawTestState === "idle" && !pending) return
    if (pending || rawTestState === "starting") cancelPending = true
    service.request("microphone.stop", { owner: owner, discard: discard }, function(_result, error) {
      if (error) {
        root.cancelPending = false
        root.localError = error.message
      } else {
        root.localError = ""
      }
    })
  }
  function startRecording() { start(true) }
  function play() { if (rawTestState === "ready" && !pending) start(false) }
  function stopRecording() { stop(false) }
  function cancel() {
    stop(rawTestState === "recording" || (pending ? pendingRecord : rawTestState === "starting"))
  }
  function discard() { stop(true) }
  function activate() {
    if (testState === "cancelling") return
    if (rawTestState === "starting" || pending) {
      if (!cancelPending) cancel()
      return
    }
    if (rawTestState === "recording") stopRecording()
    else if (rawTestState === "playing") cancel()
    else if (rawTestState === "ready") play()
    else startRecording()
  }
  onInputDeviceChanged: if (rawTestState !== "idle" || pending) discard()
  onInputDeviceLiveChanged: if (!inputDeviceLive && (rawTestState !== "idle" || pending)) discard()
  onSessionActiveChanged: if (!sessionActive && (rawTestState !== "idle" || pending)) discard()
  Component.onDestruction: if (rawTestState !== "idle" || pending) discard()
  PwNodePeakMonitor {
    id: peakMonitor
    node: root.inputDevice
    enabled: root.sessionActive && root.testState === "recording"
      && root.inputDeviceLive && Model.inputPeakSupported(root.inputDevice)
  }
  Timer {
    interval: 1000; repeat: true; running: root.testState === "recording"
    onTriggered: root.secondsRemaining = Math.max(0, root.secondsRemaining - 1)
  }
}
