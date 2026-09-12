import QtQuick
import Quickshell
import Quickshell.Io
import "AudioProtocol.js" as Protocol
import "Model.js" as Model
import "ReleasePaths.js" as ReleasePaths

// Exactly one shell-owned client. The two UI surfaces share immutable state
// and submit commands through this boundary; the backend owns transactions.
Item {
  id: root
  property var shell: null
  property var manifest: null
  property string omarchyPath: ""
  // Release checkouts include this executable. Tests can inject an isolated
  // binary; users never need a compiler or a separately installed user unit.
  property var backendCommand: [decodeURIComponent(Qt.resolvedUrl(ReleasePaths.root + "bin/omarchy-audio-service").toString().replace(/^file:\/\//, "")), "--plugin"]
  readonly property bool connected: backend.running
  property bool ready: false
  property string backendVersion: ""
  property var capabilities: []
  property string error: ""
  property var state: ({})
  property var stores: ({})
  property var storeErrors: ({})
  property var policies: ({})
  property var profiles: []
  property var ports: []
  readonly property bool busy: state.busy === true
  readonly property bool transactionBusy: busy && state.operation !== "node.audio"
  property var client: null
  property bool destroying: false

  function request(method, params, callback, settings) {
    if (!client) {
      if (callback) callback(null, Protocol.failure("not_ready", "Audio service is starting", false))
      return ""
    }
    return client.request(method, params || {}, callback, settings)
  }
  function identityForNode(node) {
    if (!ready || !state.graphReady || !node) return null
    var id = Model.nodeObjectId(node)
    var serial = Model.nodeSerial(node)
    var nodes = state.nodes || []
    var found = false
    for (var i = 0; i < nodes.length; i++) {
      if (String(nodes[i].id) === id && nodes[i].serial === serial) { found = true; break }
    }
    return found ? { generation: state.generation, id: Number(id), serial: serial } : null
  }
  function changeNode(node, patch) {
    var identity = identityForNode(node)
    if (!identity) return false
    var params = { identity: identity }
    for (var key in patch) if (Model.hasOwn(patch, key)) params[key] = patch[key]
    request("node.level", params, function(_result, failure) {
      root.error = failure ? failure.message : ""
    })
    return true
  }
  function scheduleReconnect() {
    if (destroying) return
    // Defer process changes out of its signal handler to avoid binding loops.
    reconnectTimer.restart()
  }
  Component.onCompleted: {
    client = new Protocol.Client({
      expectedBuildId: ReleasePaths.buildId,
      deadline: function(value) {
        deadlineTimer.stop()
        if (value && !root.destroying) {
          deadlineTimer.interval = Math.max(1, value - Date.now())
          deadlineTimer.start()
        }
      },
      write: function(frame) { backend.write(frame) },
      ready: function(value, info) {
        root.ready = value
        root.backendVersion = info ? String(info.version || "") : ""
        root.capabilities = info ? info.capabilities : []
        if (value) root.error = ""
      },
      state: function(value) {
        if (JSON.stringify(root.stores) !== JSON.stringify(value.stores || {})) root.stores = value.stores || {}
        if (JSON.stringify(root.storeErrors) !== JSON.stringify(value.storeErrors || {})) root.storeErrors = value.storeErrors || {}
        if (JSON.stringify(root.policies) !== JSON.stringify(value.policies || {})) root.policies = value.policies || {}
        if (JSON.stringify(root.profiles) !== JSON.stringify(value.profiles || [])) root.profiles = value.profiles || []
        if (JSON.stringify(root.ports) !== JSON.stringify(value.ports || [])) root.ports = value.ports || []
        root.state = value
      },
      fault: function(message) {
        root.error = message
        restartProcessTimer.restart()
      },
      callbackError: function() { console.warn("Audio command callback failed") }
    })
    launchTimer.start()
  }
  Component.onDestruction: {
    destroying = true
    reconnectTimer.stop()
    backend.running = false
    if (client) client.reset(Protocol.failure("disconnected", "Audio plugin closed", false))
  }
  Process {
    id: backend
    command: root.backendCommand
    stdinEnabled: true
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { if (root.client) root.client.feed(chunk) }
    }
    // Forward diagnostics without accumulating an unbounded stderr document.
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { console.warn("Audio backend:", String(chunk).slice(0, 1024)) }
    }
    onStarted: if (root.client) root.client.open()
    onExited: function(_code, _status) {
      if (root.destroying) return
      root.error = "Audio service is unavailable; check that the plugin release includes its backend"
      if (root.client) root.client.reset(Protocol.failure("disconnected", root.error, false))
      root.scheduleReconnect()
    }
    onRunningChanged: if (!running && !root.destroying) root.scheduleReconnect()
  }
  Timer {
    id: launchTimer
    interval: 1
    onTriggered: if (!root.destroying) backend.running = true
  }
  Timer {
    id: restartProcessTimer
    interval: 1
    onTriggered: {
      backend.running = false
      root.scheduleReconnect()
    }
  }
  Timer {
    id: deadlineTimer
    onTriggered: if (root.client) root.client.tick()
  }
  Timer {
    interval: 15000
    repeat: true
    running: root.ready
    onTriggered: root.request("health", {}, null, { mutating: false, timeout: 5000 })
  }
  Timer {
    id: reconnectTimer
    interval: 5000
    onTriggered: if (!root.destroying && !backend.running) backend.running = true
  }
}
