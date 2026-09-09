import QtQuick
import Quickshell.Io
import "../core/Model.js" as Model
import "../core"

// Capability discovery and optimistic WirePlumber policy mutation. The view
// consumes only the supported definitions and does not need to coordinate
// parsing, rollback, or Process state.
Item {
  id: root
  property var service: null

  required property string scriptPath

  property var settings: ({})
  property bool loaded: false
  property string error: ""
  property string pendingKey: ""
  property bool reconcilePending: false
  readonly property bool busy: policyProc.running || reconcilePending

  property bool mutation: false
  property bool responseValid: false
  property var previousSettings: ({})
  property var pendingValue: null

  readonly property var coreDefinitions: [
    {
      key: "node.features.audio.mono",
      label: "Mono audio",
      description: "Mix left and right output channels so every sound is audible from either speaker."
    },
    {
      key: "linking.pause-playback",
      label: "Pause on output loss",
      description: "Pause compatible media players when their active output device disappears."
    },
    {
      key: "device.routes.mute-on-alsa-playback-removed",
      label: "Mute after wired disconnect",
      description: "Keep playback muted instead of unexpectedly moving it to another output."
    },
    {
      key: "device.routes.mute-on-bluetooth-playback-removed",
      label: "Mute after Bluetooth disconnect",
      description: "Prevent private audio from jumping to speakers when Bluetooth drops."
    }
  ]
  readonly property var volumeDefinitions: [
    {
      key: "device.routes.default-sink-volume",
      label: "New output devices",
      description: "Starting level before WirePlumber has remembered a volume for the device."
    },
    {
      key: "device.routes.default-source-volume",
      label: "New input devices",
      description: "Starting level before WirePlumber has remembered a volume for the microphone."
    },
    {
      key: "node.stream.default-playback-volume",
      label: "New playback apps",
      description: "Starting level for applications that have not played audio before."
    },
    {
      key: "node.stream.default-capture-volume",
      label: "New recording apps",
      description: "Starting level for applications that have not recorded before."
    }
  ]
  readonly property var experimentalDefinitions: [
    {
      key: "monitor.alsa.autodetect-hdmi-channels",
      label: "Detect HDMI channel layout",
      description: "Let WirePlumber infer HDMI channel counts. Experimental; some receivers report them incorrectly."
    }
  ]

  readonly property var availableCore: supportedDefinitions(coreDefinitions)
  readonly property var availableVolumes: supportedDefinitions(volumeDefinitions)
  readonly property var availableExperimental: supportedDefinitions(experimentalDefinitions)

  signal settled()

  function supportedDefinitions(definitions) {
    var supported = []
    for (var i = 0; i < definitions.length; i++) {
      var definition = definitions[i]
      if (Model.hasOwn(settings, definition.key)) supported.push(definition)
    }
    return supported
  }

  function copySettings(source) {
    var copy = ({})
    for (var key in source)
      if (Model.hasOwn(source, key)) copy[key] = source[key]
    return copy
  }

  function loadResponse(raw) {
    var response = Model.parseAudioPolicySettings(raw)
    responseValid = response.valid
    if (!response.valid) return
    if (mutation) {
      if (!Model.hasOwn(response.values, pendingKey)) {
        responseValid = false
        return
      }
      var actual = Model.mapValue(response.values, pendingKey, null)
      if ((typeof pendingValue === "boolean" && actual !== pendingValue)
          || (typeof pendingValue === "number"
            && (typeof actual !== "number" || Math.abs(actual - pendingValue) > 0.001))) {
        responseValid = false
        return
      }
    }
    settings = response.values
    loaded = true
  }

  function refresh() {
    if (busy) return
    loaded = false
    mutation = false
    responseValid = false
    pendingKey = ""
    pendingValue = null
    policyProc.response = ""
    policyProc.command = ["/bin/bash", scriptPath]
    policyProc.running = true
  }

  function clearError() {
    error = ""
  }

  function setSetting(key, value) {
    if (!loaded || busy || !Model.hasOwn(settings, key)) return
    var current = Model.mapValue(settings, key, null)
    var normalized
    if (typeof current === "boolean") {
      if (typeof value !== "boolean") return
      normalized = value
    } else {
      normalized = Math.max(0, Math.min(1, Math.round(Number(value) * 20) / 20))
      if (!isFinite(normalized)) return
    }
    if (normalized === current) return

    error = ""
    previousSettings = copySettings(settings)
    var next = copySettings(settings)
    next[key] = normalized
    settings = next
    mutation = true
    responseValid = false
    pendingKey = key
    pendingValue = normalized
    policyProc.response = ""
    policyProc.command = ["/bin/bash", scriptPath, "set", key, String(normalized)]
    policyProc.running = true
  }

  AudioCommand {
    service: root.service
    id: policyProc
    property string response: ""
    stdout: AudioReply {
      waitForEnd: true
      onStreamFinished: policyProc.response = String(text || "")
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.loadResponse(response)
      response = ""
      var wasMutation = root.mutation
      if (exitCode !== 0 || !root.responseValid) {
        if (wasMutation) root.settings = root.previousSettings
        root.loaded = true
        root.error = wasMutation
          ? (exitCode === 4
            ? "Audio safety policy changed and its previous value could not be restored"
            : "Could not change the audio safety policy")
          : "Could not load audio safety policies"
      } else {
        root.error = ""
      }
      root.mutation = false
      root.pendingKey = ""
      root.pendingValue = null
      root.previousSettings = ({})
      if (wasMutation && exitCode === 4) {
        root.reconcilePending = true
        reconcileTimer.restart()
      }
      root.settled()
    }
  }

  Timer {
    id: reconcileTimer
    interval: 250
    repeat: false
    onTriggered: {
      root.reconcilePending = false
      root.refresh()
    }
  }
}
