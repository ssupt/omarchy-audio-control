import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "Model.js" as Model

// Captures live audio state into scene documents and applies them back.
//
// Apply is transactional in spirit: every target is resolved against live
// state first, unavailable devices are reported as skipped instead of
// failing the whole scene, and independent script steps run sequentially so
// results stay predictable. Direct node mutations (volume, mute, balance)
// happen instantly through the bound PipeWire objects; card profiles,
// ports, and defaults go through the existing helper scripts, with defaults
// applied last so they point at the post-profile device world.
Item {
  id: controller

  required property string scriptsDir

  property bool busy: false
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

  signal applyFinished(var result)
  signal captureFinished(var scene)

  property var pendingQueue: []
  property string currentLabel: ""
  property var currentResult: null
  property int stepToken: 0
  property bool capturePortsDone: false
  property bool captureProfilesDone: false
  property string capturePortsRaw: ""
  property string captureProfilesRaw: ""
  property string captureName: ""

  function findSink(name) {
    var target = String(name || "")
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (node && !node.isStream && node.isSink && String(node.name || "") === target)
        return node
    }
    return null
  }

  function findSource(name) {
    var target = String(name || "")
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (node && !node.isStream && !node.isSink && Model.isAudioSource(node)
          && String(node.name || "") === target)
        return node
    }
    return null
  }

  function findDevice(direction, name) {
    return direction === "input" ? findSource(name) : findSink(name)
  }

  function isInstrumentation(name) {
    var lower = String(name || "").toLowerCase()
    return lower === "quickshell" || lower.indexOf("omarchy_audio_test") === 0
  }

  function isMonitorSource(node) {
    return String(node && node.name || "").toLowerCase().endsWith(".monitor")
  }

  function stereoIndices(node) {
    if (!node || !node.audio || !node.audio.channels || !node.audio.volumes)
      return { left: -1, right: -1 }
    var left = -1
    var right = -1
    for (var i = 0; i < node.audio.channels.length; i++) {
      if (node.audio.channels[i] === PwAudioChannel.FrontLeft) left = i
      else if (node.audio.channels[i] === PwAudioChannel.FrontRight) right = i
    }
    if ((left < 0 || right < 0) && node.audio.volumes.length === 2)
      return { left: 0, right: 1 }
    return { left: left, right: right }
  }

  function balanceOf(node) {
    var indices = stereoIndices(node)
    if (indices.left < 0 || indices.right < 0) return 0
    return Model.balanceValue(node.audio.volumes[indices.left], node.audio.volumes[indices.right])
  }

  function setNodeBalance(node, value) {
    var indices = stereoIndices(node)
    if (indices.left < 0 || indices.right < 0) return false
    node.audio.volumes = Model.applyBalance(
      node.audio.volumes, indices.left, indices.right, value)
    return true
  }

  function apply(scene) {
    if (busy || !scene || typeof scene !== "object") return

    var result = { name: String(scene.name || ""), applied: 0, skipped: [], errors: [] }
    var queue = []
    var currentOutput = Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.name
      ? String(Pipewire.defaultAudioSink.name) : ""
    var currentInput = Pipewire.defaultAudioSource && Pipewire.defaultAudioSource.name
      ? String(Pipewire.defaultAudioSource.name) : ""

    // Card profiles may create or destroy devices, so they run before
    // everything that targets devices.
    var profiles = Array.isArray(scene.profiles) ? scene.profiles : []
    for (var i = 0; i < profiles.length; i++) {
      queue.push({
        command: [scriptsDir + "/audio-profile-set",
          String(profiles[i].card), String(profiles[i].profile)],
        label: "Profile " + profiles[i].card
      })
    }

    var ports = Array.isArray(scene.ports) ? scene.ports : []
    for (var j = 0; j < ports.length; j++) {
      queue.push({
        command: [scriptsDir + "/audio-port-set",
          String(ports[j].direction), String(ports[j].endpoint), String(ports[j].value)],
        label: "Port " + ports[j].endpoint
      })
    }

    var devices = Array.isArray(scene.devices) ? scene.devices : []
    for (var k = 0; k < devices.length; k++) {
      var entry = devices[k]
      var node = findDevice(entry.direction, entry.name)
      if (!node || !node.audio || node.audio.volumes === undefined) {
        result.skipped.push(entry.name)
        continue
      }
      node.audio.muted = entry.muted === true
      var volume = Math.max(0, Math.min(1.5, Number(entry.volume)))
      if (isFinite(volume)) node.audio.volume = volume
      setNodeBalance(node, Math.max(-1, Math.min(1, Number(entry.balance))))
      result.applied++
    }

    var defaults = scene.defaults && typeof scene.defaults === "object" ? scene.defaults : {}
    if (defaults.output !== "") {
      var outputNode = findSink(defaults.output)
      if (!outputNode || outputNode.id === undefined)
        result.skipped.push(defaults.output + " (default output)")
      else
        queue.push({
          command: [scriptsDir + "/audio-output-set-default",
            String(outputNode.id), String(outputNode.name), currentOutput],
          label: "Default output"
        })
    }
    if (defaults.input !== "") {
      var inputNode = findSource(defaults.input)
      if (!inputNode || inputNode.id === undefined)
        result.skipped.push(defaults.input + " (default input)")
      else
        queue.push({
          command: [scriptsDir + "/audio-input-set-default",
            String(inputNode.id), String(inputNode.name), currentInput],
          label: "Default input"
        })
    }

    busy = true
    currentResult = result
    pendingQueue = queue
    runNext()
  }

  function runNext() {
    if (pendingQueue.length === 0) {
      finishApply()
      return
    }
    var step = pendingQueue[0]
    pendingQueue = pendingQueue.slice(1)
    currentLabel = step.label
    stepToken++
    applyStepProc.token = stepToken
    applyStepProc.command = step.command
    applyStepProc.running = true
    stepWatchdog.restart()
  }

  function finishApply() {
    busy = false
    var result = currentResult
    currentResult = null
    if (result) applyFinished(result)
  }

  function capture(name) {
    if (busy) return
    busy = true
    captureName = String(name || "")
    capturePortsDone = false
    captureProfilesDone = false
    capturePortsRaw = ""
    captureProfilesRaw = ""
    capturePortsProc.command = [scriptsDir + "/audio-ports"]
    capturePortsProc.running = true
    captureProfilesProc.command = [scriptsDir + "/audio-profiles"]
    captureProfilesProc.running = true
  }

  function finishCapture() {
    if (!capturePortsDone || !captureProfilesDone) return

    var devices = []
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (!node || node.isStream || !node.audio || isInstrumentation(node.name)) continue
      var direction = node.isSink ? "output" : (Model.isAudioSource(node) ? "input" : "")
      if (direction === "" || isMonitorSource(node)) continue
      devices.push({
        name: String(node.name || ""),
        direction: direction,
        volume: Math.max(0, Math.min(1.5, Number(node.audio.volume))),
        // Only input muting is a deliberate state worth restoring.
        muted: direction === "input" && node.audio.muted === true,
        balance: balanceOf(node)
      })
    }

    var ports = []
    var rawPorts = Model.parseAudioPorts(capturePortsRaw)
    for (var j = 0; j < rawPorts.length; j++) {
      if (rawPorts[j].activePort === "") continue
      ports.push({
        direction: rawPorts[j].direction,
        endpoint: rawPorts[j].endpoint,
        value: rawPorts[j].activePort
      })
    }

    var profiles = []
    var cards = Model.parseAudioProfiles(captureProfilesRaw)
    for (var k = 0; k < cards.length; k++) {
      if (cards[k].activeProfile === "") continue
      profiles.push({ card: cards[k].name, profile: cards[k].activeProfile })
    }

    busy = false
    var defaultSource = Pipewire.defaultAudioSource
    // A monitor source is not a microphone; storing it as the scene's
    // default input would only produce a skipped entry later.
    captureFinished({
      version: 1,
      name: captureName,
      savedAt: new Date().toISOString(),
      defaults: {
        output: Pipewire.defaultAudioSink && Pipewire.defaultAudioSink.name
          ? String(Pipewire.defaultAudioSink.name) : "",
        input: defaultSource && defaultSource.name && !isMonitorSource(defaultSource)
          ? String(defaultSource.name) : ""
      },
      devices: devices,
      ports: ports,
      profiles: profiles
    })
  }

  Process {
    id: applyStepProc
    property int token: 0

    onExited: function(exitCode) {
      // A watchdog timeout advances the queue itself; ignore the late exit.
      if (token !== controller.stepToken) return
      controller.finishStep(exitCode)
    }
  }

  Timer {
    id: stepWatchdog
    interval: 30000
    onTriggered: {
      if (!applyStepProc.running) return
      applyStepProc.token = -1
      if (controller.currentResult)
        controller.currentResult.errors.push(controller.currentLabel + " timed out")
      applyStepProc.running = false
      controller.runNext()
    }
  }

  function finishStep(exitCode) {
    stepWatchdog.stop()
    var label = currentLabel
    currentLabel = ""
    if (currentResult) {
      // Exit 3 means the target device is absent, which is a skipped item,
      // not a failure. Exit 2 means the change landed but its shared
      // preference could not be saved; the audible part still applied.
      if (exitCode === 3) currentResult.skipped.push(label)
      else if (exitCode !== 0 && exitCode !== 2) currentResult.errors.push(label)
    }
    runNext()
  }

  Process {
    id: capturePortsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // A non-zero exit leaves whatever was collected; parseAudioPorts
        // turns unusable output into an empty list during assembly.
        controller.capturePortsRaw = String(text || "")
        controller.capturePortsDone = true
        controller.finishCapture()
      }
    }
  }

  Process {
    id: captureProfilesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        controller.captureProfilesRaw = String(text || "")
        controller.captureProfilesDone = true
        controller.finishCapture()
      }
    }
  }
}
