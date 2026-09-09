import QtQuick
import Quickshell
import Quickshell.Io
import "services" as Services

// Use Omarchy's real registry and a persistent QML engine. Deliberately retain
// component-cache entries across unload/rescan, as on the affected live host.
ShellRoot {
  id: root
  property var client: null
  property var surfaces: []
  property bool enabled: true
  property int buildMismatchCount: 0
  property string loadError: ""
  function serviceFor(_id) { return client }
  function firstPartyServiceFor(_id) { return null }
  function unload() {
    for (var i = 0; i < surfaces.length; i++) surfaces[i].destroy()
    surfaces = []
    if (client) client.destroy()
    client = null
  }
  function rescan() {
    unload()
    Qt.callLater(function() { registry.rescan() })
  }
  function load() {
    if (!enabled || client) return
    var manifest = registry.installedPlugins["ssupt.audio-control"]
    if (!manifest) return
    if (!manifest.entryPoints.service) { loadSurfaces(); return }
    var component = Qt.createComponent(registry.entryPointUrl(manifest, "service"))
    if (component.status !== Component.Ready) { loadError = component.errorString(); return }
    client = component.createObject(root, {shell: root, manifest: manifest})
    if (!client) { loadError = "Service creation failed"; return }
  }
  function loadSurfaces() {
    if (!enabled || surfaces.length) return
    var manifest = registry.installedPlugins["ssupt.audio-control"]
    if (!manifest || (manifest.entryPoints.service && (!client || !client.ready))) return
    var kinds = ["barWidget", "panel"]
    var created = []
    for (var i = 0; i < kinds.length; i++) {
      var component = Qt.createComponent(registry.entryPointUrl(manifest, kinds[i]))
      if (component.status !== Component.Ready) { loadError = component.errorString(); break }
      var properties = i === 0 ? {bar: testBar, manageIpc: false}
        : {shell: root, manifest: manifest}
      if (client) properties.service = client
      var item = component.createObject(root, properties)
      if (!item) { loadError = "UI creation failed"; break }
      created.push(item)
    }
    surfaces = created
  }
  Services.PluginRegistry {
    id: registry
    pluginsDir: PLUGINS_DIRECTORY
    firstPartyDir: ""
    onScanFinished: root.load()
  }
  Connections {
    target: root.client
    function onErrorChanged() {
      if (root.client && root.client.error.indexOf("releases do not match") !== -1)
        root.buildMismatchCount++
    }
  }
  Timer { interval: 50; running: true; repeat: true; onTriggered: root.loadSurfaces() }
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
    target: "upgrade"
    function status(): string {
      var manifest = registry.installedPlugins["ssupt.audio-control"]
      return JSON.stringify({ready: root.enabled && root.surfaces.length === 2 && !!manifest &&
          (!manifest.entryPoints.service || (!!root.client && root.client.ready)),
        info: root.client && root.client.client ? root.client.client.info : null,
        surfaces: root.surfaces.length, mismatches: root.buildMismatchCount,
        error: root.loadError, pid: Quickshell.processId,
        registryRevision: registry.registryRevision, scanning: registry.scanning})
    }
    function rescan(): void { root.rescan() }
    function disable(): void { root.enabled = false; root.unload() }
    function enable(): void { root.enabled = true; root.load() }
    function quit(): void { Qt.quit() }
  }
}
