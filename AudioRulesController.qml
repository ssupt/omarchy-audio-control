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
  readonly property var liveSources: buildLiveSources()
  readonly property var playbackStreams: nodeGroups.playbackStreams
  readonly property var recordingStreams: nodeGroups.recordingStreams
  readonly property var outputGroups: rules && rules.outputGroups ? rules.outputGroups : []
  readonly property var physicalSinks: buildPhysicalSinks()
  readonly property var availableApplicationLabels: Model.availableRuleApplicationLabels(
    playbackStreams, recordingStreams, rules.appRules)
  readonly property var targetOptions: buildTargetOptions()
  readonly property var outputGroupMemberOptions: memberOptionsFor(null)
  readonly property var managedDevices: buildManagedDevices()

  signal writeFinished(bool success)

  function aliasFor(name) {
    var group = groupForSink(name)
    if (group) return String(group.name || "")
    return String(Model.mapValue(
      rules && rules.devices ? rules.devices.aliases : null,
      String(name || ""), "") || "")
  }

  function isHidden(name) {
    if (groupForSink(name)) return false
    return rules.devices.hidden.indexOf(String(name || "")) !== -1
  }

  function groupForSink(name) {
    return Model.outputGroupForSink(outputGroups, String(name || ""))
  }

  function groupById(id) {
    var key = String(id || "")
    for (var i = 0; i < outputGroups.length && i < 64; i++)
      if (outputGroups[i] && outputGroups[i].id === key) return outputGroups[i]
    return null
  }

  function buildPhysicalSinks() {
    var values = []
    for (var i = 0; i < sinks.length && i < 512; i++)
      if (Model.isOutputGroupMemberSink(sinks[i])) values.push(sinks[i])
    return values
  }

  function buildLiveSources() {
    var values = []
    for (var i = 0; i < sources.length && i < 512; i++) {
      var node = sources[i]
      try {
        if (node && node.ready === true && !!node.audio
            && Model.nodeName(node) !== "" && Model.isAudioSource(node)
            && !Model.isMonitorSource(node)
            && !Model.isInternalAudioNode(Model.nodeName(node), Model.nodeProps(node)))
          values.push(node)
      } catch (_error) { }
    }
    return values
  }

  function physicalSinkInfo(name) {
    var target = String(name || "")
    var info = { count: 0, node: null }
    for (var i = 0; i < physicalSinks.length && i < 512; i++) {
      if (Model.nodeName(physicalSinks[i]) !== target) continue
      info.count++
      info.node = info.count === 1 ? physicalSinks[i] : null
    }
    return info
  }

  function outputGroupMembers(group) {
    return group && group.members ? Model.listSnapshot(group.members) : []
  }

  function outputGroupAvailable(group) {
    var members = outputGroupMembers(group)
    if (!group || members.length < 2) return false
    var virtualInfo = liveTargetInfo(group.sink)
    if (virtualInfo.count !== 1 || virtualInfo.direction !== "playback"
        || !Model.isManagedOutputGroupSink(virtualInfo.node)) return false
    for (var i = 0; i < members.length && i < 8; i++)
      if (physicalSinkInfo(members[i]).count !== 1) return false
    return true
  }

  function outputGroupFallbackNode(group) {
    var names = []
    for (var i = 0; i < physicalSinks.length && i < 512; i++)
      names.push(Model.nodeName(physicalSinks[i]))
    var fallbackName = Model.outputGroupFallbackMember(group, names)
    if (fallbackName === "") return null
    var info = physicalSinkInfo(fallbackName)
    return info.count === 1 ? info.node : null
  }

  function outputGroupMemberLevels(group) {
    var members = outputGroupMembers(group)
    var levels = []
    for (var i = 0; i < members.length && i < 8; i++) {
      var member = members[i]
      var info = physicalSinkInfo(member)
      var connected = false
      try {
        connected = info.count === 1 && !!info.node
          && info.node.ready === true && !!info.node.audio
      } catch (_error) { }
      levels.push({
        name: member,
        label: deviceLabel(member),
        node: connected ? info.node : null,
        connected: connected
      })
    }
    return levels
  }

  function outputGroupMemberSummary(group) {
    var members = outputGroupMembers(group)
    if (!group) return ""
    var labels = []
    for (var i = 0; i < members.length && i < 8; i++) {
      var member = members[i]
      labels.push(deviceLabel(member))
    }
    return labels.join(" + ")
  }

  function outputGroupStatusText(group) {
    var members = outputGroupMembers(group)
    if (!group || members.length < 2)
      return "Unavailable · choose at least two outputs"

    var base = members.length + (members.length === 1 ? " output" : " outputs")
    var disconnected = []
    var ambiguous = []
    for (var i = 0; i < members.length && i < 8; i++) {
      var member = members[i]
      var info = physicalSinkInfo(member)
      if (info.count === 0) disconnected.push(deviceLabel(member))
      else if (info.count > 1) ambiguous.push(deviceLabel(member))
    }
    if (disconnected.length > 0)
      return base + " · " + disconnected.join(", ") + " disconnected"
    if (ambiguous.length > 0)
      return base + " · duplicate device name"

    var virtualInfo = liveTargetInfo(group.sink)
    if (virtualInfo.count !== 1 || virtualInfo.direction !== "playback")
      return base + " · restoring…"
    return base
  }

  function routingTargetLabel(name) {
    var label = deviceLabel(name)
    return groupForSink(name) ? label + " · Output group" : label
  }

  function memberOptionsFor(group) {
    var options = []
    var seen = []
    var stored = outputGroupMembers(group)
    for (var i = 0; i < physicalSinks.length && i < 512; i++) {
      var name = Model.nodeName(physicalSinks[i])
      if (name === "" || seen.indexOf(name) !== -1
          || physicalSinkInfo(name).count !== 1) continue
      seen.push(name)
      options.push({
        value: name,
        label: deviceLabel(name),
        description: "Connected output"
      })
    }
    for (i = 0; i < stored.length && i < 8; i++) {
      if (seen.indexOf(stored[i]) !== -1) continue
      seen.push(stored[i])
      options.push({
        value: stored[i],
        label: deviceLabel(stored[i]),
        description: "Not connected"
      })
    }
    return options
  }

  function liveTargetInfo(name) {
    var target = String(name || "")
    var info = { count: 0, direction: "", node: null }
    if (target === "") return info
    var groups = [
      { nodes: sinks, direction: "playback" },
      { nodes: liveSources, direction: "recording" }
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
    var group = groupForSink(name)
    if (Model.isOutputGroupSink(name)) return !!group && outputGroupAvailable(group)
    return liveTargetInfo(name).count === 1
  }

  function optionsFor(direction, storedTarget) {
    var recording = direction === "recording"
    var devices = recording ? liveSources : sinks
    var options = [{
      value: "",
      label: recording ? "Follow default input" : "Follow default output"
    }]
    var stored = String(storedTarget || "")
    var seen = []
    for (var i = 0; i < devices.length && i < 512 && options.length < 513; i++) {
      var name = Model.nodeName(devices[i])
      if (name !== "" && name !== stored && seen.indexOf(name) === -1
          && directionNameCount(devices, name) === 1 && !isHidden(name)
          && targetIsLive(name)) {
        seen.push(name)
        options.push({ value: name, label: routingTargetLabel(name) })
      }
    }
    if (stored !== "") options.push({ value: stored, label: routingTargetLabel(stored) })
    return options
  }

  function buildTargetOptions() {
    var options = []
    var seen = []
    var groups = [sinks, liveSources]
    for (var g = 0; g < groups.length; g++) {
      for (var i = 0; i < groups[g].length && i < 512 && options.length < 512; i++) {
        var name = Model.nodeName(groups[g][i])
        if (name === "" || seen.indexOf(name) !== -1 || isHidden(name)
            || liveTargetInfo(name).count !== 1 || !targetIsLive(name)) continue
        seen.push(name)
        options.push({ value: name, label: routingTargetLabel(name) })
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
      if (key === "" || Model.isOutputGroupSink(key)
          || seen.indexOf(key) !== -1 || devices.length >= 512) return
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
      if (!Model.isOutputGroupSink(sinks[i]))
        push(Model.nodeName(sinks[i]), Model.nodeLabel(sinks[i]))
    for (i = 0; i < liveSources.length; i++)
      push(Model.nodeName(liveSources[i]), Model.nodeLabel(liveSources[i]))
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
