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
  readonly property bool busy: writeProc.running

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
    return rules.devices.aliases[String(name || "")] || ""
  }

  function isHidden(name) {
    return rules.devices.hidden.indexOf(String(name || "")) !== -1
  }

  function deviceLabel(name) {
    var target = String(name || "")
    if (target === "") return ""
    var alias = aliasFor(target)
    if (alias !== "") return alias
    var groups = [sinks, sources]
    for (var g = 0; g < groups.length; g++) {
      for (var i = 0; i < groups[g].length; i++) {
        var node = groups[g][i]
        if (node && String(node.name || "") === target) return Model.nodeLabel(node)
      }
    }
    return target
  }

  function targetIsLive(name) {
    var target = String(name || "")
    if (target === "") return false
    for (var i = 0; i < sinks.length; i++)
      if (sinks[i] && String(sinks[i].name || "") === target) return true
    for (var j = 0; j < sources.length; j++)
      if (sources[j] && String(sources[j].name || "") === target) return true
    return false
  }

  function optionsFor(direction, storedTarget) {
    var recording = direction === "recording"
    var devices = recording ? sources : sinks
    var options = [{
      value: "",
      label: recording ? "Follow default input" : "Follow default output"
    }]
    var stored = String(storedTarget || "")
    for (var i = 0; i < devices.length; i++) {
      var name = String(devices[i] ? devices[i].name || "" : "")
      if (name !== "" && name !== stored)
        options.push({ value: name, label: deviceLabel(name) })
    }
    if (stored !== "") options.push({ value: stored, label: deviceLabel(stored) })
    return options
  }

  function buildTargetOptions() {
    var options = []
    var seen = []
    var groups = [sinks, sources]
    for (var g = 0; g < groups.length; g++) {
      for (var i = 0; i < groups[g].length; i++) {
        var name = String(groups[g][i] ? groups[g][i].name || "" : "")
        if (name === "" || seen.indexOf(name) !== -1) continue
        seen.push(name)
        options.push({ value: name, label: deviceLabel(name) })
      }
    }
    return options
  }

  function directionForTarget(name) {
    var target = String(name || "")
    for (var i = 0; i < sinks.length; i++)
      if (sinks[i] && String(sinks[i].name || "") === target) return "playback"
    for (var j = 0; j < sources.length; j++)
      if (sources[j] && String(sources[j].name || "") === target) return "recording"
    return ""
  }

  function buildManagedDevices() {
    var devices = []
    var seen = []

    function push(name, liveLabel) {
      var key = String(name || "")
      if (key === "" || seen.indexOf(key) !== -1) return
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
      push(sinks[i] ? sinks[i].name : "", Model.nodeLabel(sinks[i]))
    for (i = 0; i < sources.length; i++)
      push(sources[i] ? sources[i].name : "", Model.nodeLabel(sources[i]))
    for (i = 0; i < rules.devices.favorites.length; i++)
      push(rules.devices.favorites[i], rules.devices.favorites[i])
    for (i = 0; i < rules.devices.hidden.length; i++)
      push(rules.devices.hidden[i], rules.devices.hidden[i])
    for (var aliasName in rules.devices.aliases) push(aliasName, aliasName)

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
    writeProc.command = [scriptPath].concat(args)
    writeProc.running = true
    return true
  }

  FileView {
    path: root.rulesPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.rules = Model.parseAudioRules(text())
      root.loaded = true
    }
    onLoadFailed: {
      root.rules = Model.parseAudioRules("")
      root.loaded = true
    }
    onFileChanged: reload()
  }

  Process {
    id: writeProc
    onExited: function(exitCode) {
      root.error = exitCode === 0 ? "" : "Could not update the audio rules"
      root.writeFinished(exitCode === 0)
    }
  }

  PwObjectTracker { objects: root.sinks }
  PwObjectTracker { objects: root.sources }
  PwObjectTracker { objects: root.playbackStreams }
  PwObjectTracker { objects: root.recordingStreams }
}
