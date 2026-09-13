import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire

ShellRoot {
  id: root
  property var manifest: MANIFEST
  property string pluginUrl: PLUGIN_URL
  property var client: null
  property var panel: null
  property var advanced: null
  property string error: ""
  property var latencies: []
  property int remaining: 0
  property real targetVolume: 0
  property double sentAt: 0
  property bool awaiting: false
  function serviceFor(_id) { return client }
  function firstPartyServiceFor(_id) { return null }
  function summon(_id, _payload) { return true }
  function create(kind, properties) {
    var component = Qt.createComponent(pluginUrl + manifest.entryPoints[kind])
    if (component.status !== Component.Ready) { error = component.errorString(); return null }
    var item = component.createObject(root, properties)
    if (!item) error = "Component creation failed: " + kind
    return item
  }
  Component.onCompleted: {
    if (manifest.entryPoints.service) client = create("service", {shell: root, manifest: manifest})
    var properties = {bar: testBar, manageIpc: false}
    if (client) properties.service = client
    panel = create("barWidget", properties)
  }
  function openAdvanced() {
    if (!advanced) {
      var properties = {shell: root, manifest: manifest}
      if (client) properties.service = client
      advanced = create("panel", properties)
    }
    if (advanced) advanced.open('{"view":"advanced"}')
  }
  function nextVolume() {
    if (!remaining) return
    targetVolume = remaining % 2 ? 0.3 : 0.5
    sentAt = Date.now()
    awaiting = true
    panel.setOutputVolume(targetVolume)
  }
  function volumeRequest(value, dispatch) {
    var sink = Pipewire.defaultAudioSink
    if (!sink || sink.name !== "audio_test_output" || !sink.audio)
      return JSON.stringify({error: "Expected the private dummy sink"})
    var request = {sentAtMs: Date.now(), targetVolume: value, nodeId: sink.id}
    if (dispatch) panel.setOutputVolume(value)
    return JSON.stringify(request)
  }
  Timer {
    interval: 1; repeat: true; running: root.remaining > 0
    onTriggered: {
      if (!root.awaiting) { root.nextVolume(); return }
      var sink = Pipewire.defaultAudioSink
      if (sink && sink.audio && Math.abs(sink.audio.volume - root.targetVolume) < 0.005) {
        root.latencies.push(Date.now() - root.sentAt)
        root.remaining--
        root.awaiting = false
      } else if (Date.now() - root.sentAt > 3000) {
        root.error = "Volume command did not converge"
        root.remaining = 0
      }
    }
  }
  QtObject {
    id: testBar
    property color foreground: "#eeeeee"
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
    property var shell: root
  }
  IpcHandler {
    target: "benchmark"
    function status(): string {
      var sink = Pipewire.defaultAudioSink
      return JSON.stringify({ready: !!root.panel && !!sink && !!sink.audio &&
          (!root.manifest.entryPoints.service || (!!root.client && root.client.ready)),
        pipewireReady: Pipewire.ready, nodes: Pipewire.nodes.values.length,
        sinkPresent: !!sink, sinkReady: !!sink && sink.ready, audioPresent: !!sink && !!sink.audio,
        opened: !!root.advanced && root.advanced.opened,
        error: root.error, remaining: root.remaining, latencies: root.latencies})
    }
    function open(): void { root.openAdvanced() }
    function close(): void { if (root.advanced) root.advanced.close() }
    function latency(): void { root.latencies = []; root.remaining = 40; root.awaiting = false }
    function volume(value: real): string { return root.volumeRequest(value, true) }
    function volumeMarker(value: real): string { return root.volumeRequest(value, false) }
    function quit(): void { Qt.quit() }
  }
}
