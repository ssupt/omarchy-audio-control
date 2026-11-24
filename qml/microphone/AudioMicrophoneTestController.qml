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
  property string localError: ""
  property int secondsRemaining: 0
  readonly property var job: service && service.ready && service.state.microphone
    && service.state.microphone.owner === owner ? service.state.microphone : ({})
  readonly property string testState: String(job.state || "idle")
  readonly property string error: localError || String(job.error || "")
  readonly property bool microphoneMuted: !inputDeviceLive || !inputDevice
    || !inputDevice.audio || inputDevice.audio.muted
  readonly property bool busy: pending || testState === "starting"
    || testState === "recording" || testState === "playing"
  readonly property real level: microphoneMuted ? 0 : Math.max(0, Math.min(1, Number(peakMonitor.peak) || 0))

  function start(record) {
    if (!service || !service.ready || pending) return
    if (record && (microphoneMuted || !sessionActive)) return
    var identity = record ? service.identityForNode(inputDevice) : null
    if (record && !identity) return
    pending = true
    localError = ""
    secondsRemaining = record ? 5 : 0
    service.request("microphone.start", { owner: owner, record: record, identity: identity }, function(_result, error) {
      root.pending = false
      root.localError = error ? error.message : ""
    })
  }
  function stop(discard) {
    if (!service || !service.ready) return
    if (testState === "idle" && !pending) return
    service.request("microphone.stop", { owner: owner, discard: discard }, function(_result, error) {
      root.localError = error ? error.message : ""
    })
  }
  function startRecording() { start(true) }
  function play() { if (testState === "ready") start(false) }
  function stopRecording() { stop(false) }
  function cancel() { stop(testState === "recording" || testState === "starting") }
  function discard() { stop(true) }
  function activate() {
    if (pending) return
    if (testState === "starting") cancel()
    else if (testState === "recording") stopRecording()
    else if (testState === "playing") cancel()
    else if (testState === "ready") play()
    else startRecording()
  }
  onInputDeviceChanged: if (testState !== "idle" || pending) discard()
  onInputDeviceLiveChanged: if (!inputDeviceLive && (testState !== "idle" || pending)) discard()
  onSessionActiveChanged: if (!sessionActive && (testState !== "idle" || pending)) discard()
  Component.onDestruction: if (testState !== "idle" || pending) discard()
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
