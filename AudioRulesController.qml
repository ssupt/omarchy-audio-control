import QtQuick
import Quickshell.Io
import Quickshell.Services.Pipewire
import "Model.js" as Model

// Shared saved-rule registry and live routing catalog. Both plugin surfaces
// observe the same store through this component, so filtering, aliases, and
// offline device presentation cannot drift apart again.
Item {
  id: root

  required property string rulesPath
  required property string scriptPath
  required property var nodes

  property var rules: Model.parseAudioRules("")
  property bool loaded: false
  property string error: ""
  property bool reloadPending: false
  readonly property bool busy: writeProc.running || reloadPending

  readonly property var nodeGroups: Model.classifyAudioNodes(nodes)
  readonly property var sinks: nodeGroups.sinks
  readonly property var sources: nodeGroups.sources
  readonly property var playbackStreams: nodeGroups.playbackStreams
  readonly property var recordingStreams: nodeGroups.recordingStreams
  readonly property var availableApplicationLabels: Model.availableRuleApplicationLabels(
    playbackStreams, recordingStreams, rules.appRules)
  readonly property var targetOptions: buildTargetOptions()
  readonly property var managedDevices: buildManagedDevices()

  signal writeFinished(bool success)

  function aliasFor(name) {
    return String(Model.mapValue(
      rules && rules.devices ? rules.devices.aliases : null,
      String(name || ""), "") || "")
  }

  function isHidden(name) {
    return rules.devices.hidden.indexOf(String(name || "")) !== -1
  }

  function liveTargetInfo(name) {
    var target = String(name || "")
    var info = { count: 0, direction: "", node: null }
    if (target === "") return info
    var groups = [
      { nodes: sinks, direction: "playback" },
      { nodes: sources, direction: "recording" }
    ]
    for (var g = 0; g < groups.length; g++) {
      for (var i = 0; i < groups[g].nodes.length && i < 512; i++) {
        var node = groups[g].nodes[i]
        if (Model.nodeName(node) !== target) continue
        info.count++
        if (info.count === 1) {
          info.direction = groups[g].direction
          info.node = node
        } else {
          info.direction = ""
          info.node = null
        }
      }
    }
    return info
  }

  function directionNameCount(devices, name) {
    var target = String(name || "")
    var count = 0
    for (var i = 0; i < devices.length && i < 512; i++) {
      if (Model.nodeName(devices[i]) === target) count++
      if (count > 1) break
    }
    return count
  }

  function deviceLabel(name) {
    var target = String(name || "")
    if (target === "") return ""
    var alias = aliasFor(target)
    if (alias !== "") return alias
    var info = liveTargetInfo(target)
    return info.count === 1 ? Model.nodeLabel(info.node) : target
  }

  function targetIsLive(name) {
    return liveTargetInfo(name).count === 1
  }

  function optionsFor(direction, storedTarget) {
    var recording = direction === "recording"
    var devices = recording ? sources : sinks
    var options = [{
      value: "",
      label: recording ? "Follow default input" : "Follow default output"
    }]
    var stored = String(storedTarget || "")
    var seen = []
    for (var i = 0; i < devices.length && i < 512 && options.length < 513; i++) {
      var name = Model.nodeName(devices[i])
      if (name !== "" && name !== stored && seen.indexOf(name) === -1
          && directionNameCount(devices, name) === 1 && !isHidden(name)) {
        seen.push(name)
        options.push({ value: name, label: deviceLabel(name) })
      }
    }
    if (stored !== "") options.push({ value: stored, label: deviceLabel(stored) })
    return options
  }

  function buildTargetOptions() {
    var options = []
    var seen = []
    var groups = [sinks, sources]
    for (var g = 0; g < groups.length; g++) {
      for (var i = 0; i < groups[g].length && i < 512 && options.length < 512; i++) {
        var name = Model.nodeName(groups[g][i])
        if (name === "" || seen.indexOf(name) !== -1 || isHidden(name)
            || liveTargetInfo(name).count !== 1) continue
        seen.push(name)
        options.push({ value: name, label: deviceLabel(name) })
      }
    }
    return options
  }

  function directionForTarget(name) {
    var info = liveTargetInfo(name)
    return info.count === 1 ? info.direction : ""
  }

  function buildManagedDevices() {
    var devices = []
    var seen = []

    function push(name, liveLabel) {
      var key = String(name || "")
      if (key === "" || seen.indexOf(key) !== -1 || devices.length >= 512) return
      seen.push(key)
      var alias = root.aliasFor(key)
      devices.push({
        name: key,
        title: alias !== "" ? alias : liveLabel,
        favorite: root.rules.devices.favorites.indexOf(key) !== -1,
        hidden: root.rules.devices.hidden.indexOf(key) !== -1
      })
    }

    var i
    for (i = 0; i < sinks.length; i++)
      push(Model.nodeName(sinks[i]), Model.nodeLabel(sinks[i]))
    for (i = 0; i < sources.length; i++)
      push(Model.nodeName(sources[i]), Model.nodeLabel(sources[i]))
    for (i = 0; i < rules.devices.favorites.length; i++)
      push(rules.devices.favorites[i], rules.devices.favorites[i])
    for (i = 0; i < rules.devices.hidden.length; i++)
      push(rules.devices.hidden[i], rules.devices.hidden[i])
    for (var aliasName in rules.devices.aliases) {
      if (Model.hasOwn(rules.devices.aliases, aliasName)) push(aliasName, aliasName)
    }

    devices.sort(function(a, b) {
      if (a.favorite !== b.favorite) return a.favorite ? -1 : 1
      if (a.hidden !== b.hidden) return a.hidden ? 1 : -1
      return 0
    })
    return devices
  }

  function write(args) {
    if (busy) return false
    error = ""
    writeProc.command = ["/bin/bash", scriptPath].concat(args)
    writeProc.running = true
    return true
  }

  function handleLoadFailure() {
    if (reloadPending) {
      reloadWatchdog.stop()
      reloadPending = false
      error = "Audio rules changed, but could not be reloaded"
      writeFinished(false)
      return
    }
    if (!loaded) {
      rules = Model.parseAudioRules("")
      loaded = true
      return
    }
    // Preserve a previously parsed registry across transient watch/read
    // failures. Clearing it here would briefly unpin every application.
    error = "Could not reload audio rules"
  }

  FileView {
    id: rulesFile
    path: root.rulesPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      var raw = text()
      if (!Model.isAudioRulesDocument(raw)) {
        root.handleLoadFailure()
        return
      }
      root.rules = Model.parseAudioRules(raw)
      root.loaded = true
      root.error = ""
      if (root.reloadPending) {
        reloadWatchdog.stop()
        root.reloadPending = false
        root.error = ""
        root.writeFinished(true)
      }
    }
    onLoadFailed: root.handleLoadFailure()
    onFileChanged: reload()
  }

  Process {
    id: writeProc
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.error = "Could not update the audio rules"
        root.writeFinished(false)
        return
      }
      // Keep writes serialized until the shared file has been parsed back
      // into memory. Otherwise enforcement can briefly apply the old rule
      // immediately after a successful manual route edit.
      root.reloadPending = true
      reloadWatchdog.restart()
      rulesFile.reload()
    }
  }

  Timer {
    id: reloadWatchdog
    interval: 3000
    onTriggered: {
      if (!root.reloadPending) return
      root.reloadPending = false
      root.error = "Audio rules changed, but could not be reloaded"
      root.writeFinished(false)
    }
  }

  PwObjectTracker { objects: root.sinks }
  PwObjectTracker { objects: root.sources }
  PwObjectTracker { objects: root.playbackStreams }
  PwObjectTracker { objects: root.recordingStreams }
}
