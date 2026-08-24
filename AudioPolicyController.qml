import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Capability discovery and optimistic WirePlumber policy mutation. The view
// consumes only the supported definitions and does not need to coordinate
// parsing, rollback, or Process state.
Item {
  id: root

  required property string scriptPath

  property var settings: ({})
  property bool loaded: false
  property string error: ""
  property string pendingKey: ""
  readonly property bool busy: policyProc.running

  property bool mutation: false
  property bool responseValid: false
  property var previousSettings: ({})

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
      if (settings[definition.key] !== undefined) supported.push(definition)
    }
    return supported
  }

  function copySettings(source) {
    var copy = ({})
    for (var key in source) copy[key] = source[key]
    return copy
  }

  function loadResponse(raw) {
    var response = Model.parseAudioPolicySettings(raw)
    responseValid = response.valid
    if (!response.valid) return
    settings = response.values
    loaded = true
  }

  function refresh() {
    loaded = false
    if (busy) return
    mutation = false
    responseValid = false
    pendingKey = ""
    policyProc.command = [scriptPath]
    policyProc.running = true
  }

  function clearError() {
    error = ""
  }

  function setSetting(key, value) {
    if (!loaded || busy || settings[key] === undefined) return
    var current = settings[key]
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
    policyProc.command = [scriptPath, "set", key, String(normalized)]
    policyProc.running = true
  }

  Process {
    id: policyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadResponse(text)
    }
    onExited: function(exitCode) {
      var wasMutation = root.mutation
      if (exitCode !== 0 || !root.responseValid) {
        root.settings = wasMutation ? root.previousSettings : ({})
        root.loaded = true
        root.error = wasMutation
          ? "Could not change the audio safety policy"
          : "Could not load audio safety policies"
      } else {
        root.error = ""
      }
      root.mutation = false
      root.pendingKey = ""
      root.previousSettings = ({})
      root.settled()
    }
  }
}
