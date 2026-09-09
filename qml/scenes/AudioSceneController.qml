import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "../core/Model.js" as Model

// Captures live audio state into scene documents and applies them back.
//
// Apply is transactional in spirit: independent steps run sequentially and
// each live target is resolved only when its step executes. Card profiles can
// recreate every endpoint on a card, so profiles finish before ports, direct
// node mutations, and defaults. Unavailable devices are reported as skipped
// instead of aborting unrelated parts of the scene.
Item {
  id: controller

  required property string scriptsDir
  property real outputVolumeMaximum: 1.5

  property bool busy: false
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

  signal applyFinished(var result)
  signal captureFinished(var scene)
  signal captureFailed(string error)

  property var pendingQueue: []
  property string currentLabel: ""
  property var currentResult: null
  property bool stepTimedOut: false
  property bool capturePortsDone: false
  property bool captureProfilesDone: false
  property bool capturePortsSucceeded: false
  property bool captureProfilesSucceeded: false
  property string capturePortsRaw: ""
  property string captureProfilesRaw: ""
  property string captureName: ""
  property var pendingDeviceMutation: null
  property int deviceVerificationAttempts: 0
  property bool deviceRollbackVerification: false

  function findSink(name) {
    var target = String(name || "")
    if (target === "") return null
    var match = null
    for (var i = 0; i < nodes.length && i < 4096; i++) {
      try {
        var node = nodes[i]
        if (node && !node.isStream && node.isSink
            && !Model.isInternalAudioNode(node.name, Model.nodeProps(node))
            && String(node.name || "") === target) {
          if (match) return null
          match = node
        }
      } catch (_error) { }
    }
    return match
  }

  function findSource(name) {
    var target = String(name || "")
    if (target === "") return null
    var match = null
    for (var i = 0; i < nodes.length && i < 4096; i++) {
      try {
        var node = nodes[i]
        if (node && !node.isStream && !node.isSink && Model.isAudioSource(node)
            && !Model.isInternalAudioNode(node.name, Model.nodeProps(node))
            && !Model.isMonitorSource(node)
            && String(node.name || "") === target) {
          if (match) return null
          match = node
        }
      } catch (_error) { }
    }
    return match
  }

  function findDevice(direction, name) {
    return direction === "input" ? findSource(name) : findSink(name)
  }

  function capturableDeviceName(node, direction) {
    try {
      if (!node || node.ready !== true || node.isStream || !node.audio
          || Model.nodeObjectId(node) === ""
          || Model.isInternalAudioNode(node.name, Model.nodeProps(node))) return ""
      if (direction === "output") {
        if (node.isSink !== true) return ""
      } else if (direction === "input") {
        if (node.isSink === true || !Model.isAudioSource(node)
            || Model.isMonitorSource(node)) return ""
      } else {
        return ""
      }
      var name = Model.sanitizeIdentifier(String(node.name || ""), 160)
      // Names are persisted in scene files, so only capture one when it
      // resolves back to this exact live object. Otherwise a later apply could
      // transfer state to one of several same-name endpoints.
      return name !== "" && findDevice(direction, name) === node ? name : ""
    } catch (_error) {
      return ""
    }
  }

  function stereoIndices(node) {
    if (!node || !node.audio || !node.audio.channels || !node.audio.volumes)
      return { left: -1, right: -1 }
    var left = -1
    var right = -1
    for (var i = 0; i < node.audio.channels.length && i < 64; i++) {
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

  function apply(scene) {
    if (busy || !scene || typeof scene !== "object") return

    var normalized = Model.sanitizeSceneEntry(scene)
    if (!normalized) return
    var result = { name: normalized.name, applied: 0, skipped: [], errors: [] }

    busy = true
    currentResult = result
    pendingQueue = Model.audioScenePlan(normalized)
    runNext()
  }

  function runNext() {
    if (applyStepProc.running || sceneSettleTimer.running
        || deviceVerifyTimer.running || pendingDeviceMutation) return

    while (pendingQueue.length > 0) {
      var step = pendingQueue[0]
      pendingQueue = pendingQueue.slice(1)
      currentLabel = step.label

      if (step.kind === "settle") {
        sceneSettleTimer.restart()
        return
      }
      if (step.kind === "device") {
        if (applyDeviceStep(step)) return
        currentLabel = ""
        continue
      }

      var command = []
      if (step.kind === "profile") {
        command = ["/bin/bash", scriptsDir + "/audio-profile-set", step.card, step.profile]
      } else if (step.kind === "port") {
        command = ["/bin/bash", scriptsDir + "/audio-port-set",
          step.direction, step.endpoint, step.value]
      } else if (step.kind === "default") {
        var node = findDevice(step.direction, step.name)
        var objectId = Model.nodeObjectId(node)
        var nodeName = Model.nodeName(node)
        if (!node || objectId === "" || nodeName === ""
            || findDevice(step.direction, nodeName) !== node) {
          if (currentResult)
            currentResult.skipped.push(step.name + " (default " + step.direction + ")")
          currentLabel = ""
          continue
        }
        var current = step.direction === "input"
          ? Pipewire.defaultAudioSource : Pipewire.defaultAudioSink
        var previousName = Model.nodeName(current)
        var previousObjectId = Model.nodeObjectId(current)
        command = ["/bin/bash", scriptsDir + (step.direction === "input"
            ? "/audio-input-set-default" : "/audio-output-set-default"),
          objectId, nodeName, previousName, previousObjectId]
      } else {
        if (currentResult) currentResult.errors.push("Unknown scene step")
        currentLabel = ""
        continue
      }

      stepTimedOut = false
      applyStepProc.command = command
      applyStepProc.running = true
      stepWatchdog.restart()
      return
    }

    finishApply()
  }

  function applyDeviceStep(step) {
    try {
      return applyDeviceStepUnchecked(step)
    } catch (_error) {
      pendingDeviceMutation = null
      deviceVerificationAttempts = 0
      deviceRollbackVerification = false
      if (currentResult) currentResult.errors.push(step.name)
      return false
    }
  }

  function applyDeviceStepUnchecked(step) {
    var node = null
    try { node = findDevice(step.direction, step.name) } catch (_error) { }
    var objectId = Model.nodeObjectId(node)
    if (!node || objectId === "" || node.ready !== true || !node.audio
        || node.audio.volumes === undefined) {
      if (currentResult) currentResult.skipped.push(step.name)
      return false
    }

    var desiredVolume = Number(step.volume)
    var maximum = step.direction === "output" ? outputVolumeMaximum : 1.5
    if (!isFinite(desiredVolume) || !isFinite(maximum)) {
      if (currentResult) currentResult.errors.push(step.name)
      return false
    }
    desiredVolume = Math.max(0, Math.min(maximum, desiredVolume))

    var currentVolumes = node.audio.volumes
    var channelCount = currentVolumes && typeof currentVolumes.length === "number"
      ? Math.floor(Number(currentVolumes.length)) : 0
    var originalVolumes = []
    if (channelCount > 0 && channelCount <= 64) {
      for (var originalIndex = 0; originalIndex < channelCount; originalIndex++) {
        var originalChannelVolume = Number(currentVolumes[originalIndex])
        if (!isFinite(originalChannelVolume)) {
          if (currentResult) currentResult.errors.push(step.name)
          return false
        }
        originalVolumes.push(originalChannelVolume)
      }
    }
    var originalVolume = Number(node.audio.volume)
    if (!isFinite(originalVolume)) originalVolume = 0
    var expectedMuted = step.direction === "input" && step.muted === true
    var desiredVolumes = []
    if (channelCount > 0 && channelCount <= 64) {
      for (var i = 0; i < channelCount; i++) desiredVolumes.push(desiredVolume)
      var indices = stereoIndices(node)
      if (indices.left >= 0 && indices.right >= 0)
        desiredVolumes = Model.applyBalance(
          desiredVolumes, indices.left, indices.right, step.balance)
    }
    pendingDeviceMutation = {
      step: step,
      objectId: objectId,
      originalMuted: node.audio.muted === true,
      originalVolume: originalVolume,
      originalVolumes: originalVolumes,
      expectedMuted: expectedMuted,
      expectedVolume: desiredVolume,
      expectedVolumes: desiredVolumes
    }
    deviceVerificationAttempts = 0
    deviceRollbackVerification = false

    try {
      // Silence the endpoint before changing its gain. This avoids a stored
      // low-volume scene briefly playing at the endpoint's previous level.
      node.audio.muted = true
      if (channelCount > 0 && channelCount <= 64) {
        node.audio.volumes = desiredVolumes
      } else {
        node.audio.volume = desiredVolume
      }
      // Output scenes intentionally restore audibly; input mute remains a
      // privacy-bearing part of the saved scene.
      node.audio.muted = expectedMuted
    } catch (_mutationError) {
      beginDeviceRollback(node)
    }
    deviceVerifyTimer.restart()
    return true
  }

  function deviceStateMatches(node, muted, volume, volumes) {
    try {
      if (!node || node.ready !== true || !node.audio || node.audio.muted !== muted)
        return false
      if (volumes && volumes.length > 0) {
        var liveVolumes = node.audio.volumes
        if (!liveVolumes || liveVolumes.length !== volumes.length || volumes.length > 64)
          return false
        for (var i = 0; i < volumes.length; i++) {
          var actual = Number(liveVolumes[i])
          if (!isFinite(actual) || Math.abs(actual - Number(volumes[i])) > 0.015)
            return false
        }
        return true
      }
      var actualVolume = Number(node.audio.volume)
      return isFinite(actualVolume) && Math.abs(actualVolume - Number(volume)) <= 0.015
    } catch (_error) {
      return false
    }
  }

  function beginDeviceRollback(node) {
    try {
      var pending = pendingDeviceMutation
      if (!pending || !node || Model.nodeObjectId(node) !== pending.objectId) return false
      deviceRollbackVerification = true
      deviceVerificationAttempts = 0
      node.audio.muted = true
      if (pending.originalVolumes.length > 0) node.audio.volumes = pending.originalVolumes
      else node.audio.volume = pending.originalVolume
      node.audio.muted = pending.originalMuted
      return true
    } catch (_rollbackError) {
      return false
    }
  }

  function finishDeviceMutation(success, rollbackSucceeded) {
    var pending = pendingDeviceMutation
    deviceVerifyTimer.stop()
    pendingDeviceMutation = null
    deviceVerificationAttempts = 0
    deviceRollbackVerification = false
    currentLabel = ""
    if (pending && currentResult) {
      if (success) currentResult.applied++
      else currentResult.errors.push(pending.step.name
        + (rollbackSucceeded ? "" : " could not be restored"))
    }
    // A verified rollback leaves unrelated scene steps safe to continue. If
    // restoration itself failed, the live graph is unknown; stop before a
    // later profile/default/device step compounds that partial state.
    if (!success && !rollbackSucceeded) pendingQueue = []
    runNext()
  }

  function verifyDeviceMutation() {
    var pending = pendingDeviceMutation
    if (!pending) return
    var node = null
    try { node = findDevice(pending.step.direction, pending.step.name) } catch (_error) { }
    if (!node || Model.nodeObjectId(node) !== pending.objectId) {
      // The captured object vanished. Never transfer its state to a same-name
      // replacement; there is no remaining object to roll back.
      finishDeviceMutation(false, true)
      return
    }
    var matches = deviceRollbackVerification
      ? deviceStateMatches(node, pending.originalMuted,
          pending.originalVolume, pending.originalVolumes)
      : deviceStateMatches(node, pending.expectedMuted,
          pending.expectedVolume, pending.expectedVolumes)
    if (matches) {
      finishDeviceMutation(!deviceRollbackVerification, true)
      return
    }
    deviceVerificationAttempts++
    if (deviceVerificationAttempts < 10) {
      deviceVerifyTimer.restart()
      return
    }
    if (!deviceRollbackVerification && beginDeviceRollback(node)) {
      deviceVerifyTimer.restart()
      return
    }
    finishDeviceMutation(false, false)
  }

  function finishApply() {
    stepWatchdog.stop()
    sceneSettleTimer.stop()
    deviceVerifyTimer.stop()
    busy = false
    var result = currentResult
    currentResult = null
    pendingQueue = []
    currentLabel = ""
    stepTimedOut = false
    pendingDeviceMutation = null
    deviceVerificationAttempts = 0
    deviceRollbackVerification = false
    if (result) applyFinished(result)
  }

  function capture(name) {
    if (busy) return
    busy = true
    captureName = String(name || "")
    capturePortsDone = false
    captureProfilesDone = false
    capturePortsSucceeded = false
    captureProfilesSucceeded = false
    capturePortsRaw = ""
    captureProfilesRaw = ""
    capturePortsProc.command = ["/bin/bash", scriptsDir + "/audio-ports"]
    capturePortsProc.running = true
    captureProfilesProc.command = ["/bin/bash", scriptsDir + "/audio-profiles"]
    captureProfilesProc.running = true
  }

  function finishCapture() {
    if (!capturePortsDone || !captureProfilesDone) return

    if (!capturePortsSucceeded || !captureProfilesSucceeded) {
      var failedParts = []
      if (!capturePortsSucceeded) failedParts.push("device ports")
      if (!captureProfilesSucceeded) failedParts.push("card profiles")
      busy = false
      captureName = ""
      captureFailed("Could not capture " + failedParts.join(" and ") + " for the scene")
      return
    }

    var devices = []
    for (var i = 0; i < nodes.length && i < 4096 && devices.length < 64; i++) {
      try {
        var node = nodes[i]
        if (!node || node.ready !== true || node.isStream || !node.audio) continue
        var direction = node.isSink ? "output" : (Model.isAudioSource(node) ? "input" : "")
        var deviceName = capturableDeviceName(node, direction)
        var deviceVolume = Number(node.audio.volume)
        if (deviceName === "" || !isFinite(deviceVolume)) continue
        devices.push({
          name: deviceName,
          direction: direction,
          volume: Math.max(0, Math.min(direction === "output"
            ? outputVolumeMaximum : 1.5, deviceVolume)),
          // Only input muting is a deliberate state worth restoring.
          muted: direction === "input" && node.audio.muted === true,
          balance: balanceOf(node)
        })
      } catch (_captureError) {
        // Live nodes may vanish while a scene snapshot is assembled.
      }
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
      if (cards[k].activeProfile === "" || cards[k].activeProfile === "off") continue
      profiles.push({ card: cards[k].name, profile: cards[k].activeProfile })
    }

    busy = false
    var defaultSink = Pipewire.defaultAudioSink
    var defaultSource = Pipewire.defaultAudioSource
    var defaultOutputName = capturableDeviceName(defaultSink, "output")
    // Monitor, stream, and internal sources are not microphones; storing one
    // as a scene default would only produce an unsafe or permanently skipped
    // entry later.
    var defaultInputName = capturableDeviceName(defaultSource, "input")
    var capturedScene = Model.sanitizeSceneEntry({
      version: 1,
      name: captureName,
      savedAt: new Date().toISOString(),
      defaults: {
        output: defaultOutputName,
        input: defaultInputName
      },
      devices: devices,
      ports: ports,
      profiles: profiles
    })
    captureName = ""
    if (capturedScene) captureFinished(capturedScene)
    else captureFailed("Could not assemble the current audio scene")
  }

  Process {
    id: applyStepProc

    onExited: function(exitCode) {
      stepWatchdog.stop()
      if (controller.stepTimedOut) {
        controller.stepTimedOut = false
        controller.currentLabel = ""
        // The helper was killed with an unknown transactional state. Do not
        // compound that uncertainty by applying the remainder of the scene.
        controller.pendingQueue = []
        controller.finishApply()
        return
      }
      controller.finishStep(exitCode)
    }
  }

  Timer {
    id: stepWatchdog
    interval: 30000
    onTriggered: {
      if (!applyStepProc.running) return
      if (controller.currentResult)
        controller.currentResult.errors.push(controller.currentLabel + " timed out")
      controller.stepTimedOut = true
      // Do not reuse this Process until its onExited signal confirms that the
      // timed-out child is gone. Reusing it here lets the old exit complete a
      // newly started step and corrupts the rest of the queue.
      applyStepProc.running = false
    }
  }

  Timer {
    id: sceneSettleTimer
    interval: 200
    onTriggered: {
      controller.currentLabel = ""
      controller.runNext()
    }
  }

  Timer {
    id: deviceVerifyTimer
    interval: 100
    repeat: false
    onTriggered: controller.verifyDeviceMutation()
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
      else if (exitCode === 2) {
        currentResult.applied++
        currentResult.errors.push(label + " preference could not be saved")
      } else if (exitCode === 4) {
        currentResult.applied++
        currentResult.errors.push(label + " only partially applied")
        // Helper exit 4 explicitly means changed/unknown state with incomplete
        // recovery. Treat it like a watchdog timeout and do not layer the rest
        // of the scene on top of an unverified graph.
        pendingQueue = []
      } else if (exitCode !== 0) currentResult.errors.push(label)
      else currentResult.applied++
    }
    runNext()
  }

  Process {
    id: capturePortsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        controller.capturePortsRaw = String(text || "")
      }
    }
    onExited: function(exitCode) {
      controller.capturePortsSucceeded = exitCode === 0
      controller.capturePortsDone = true
      controller.finishCapture()
    }
  }

  Process {
    id: captureProfilesProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        controller.captureProfilesRaw = String(text || "")
      }
    }
    onExited: function(exitCode) {
      controller.captureProfilesSucceeded = exitCode === 0
      controller.captureProfilesDone = true
      controller.finishCapture()
    }
  }
}
