import QtQuick
import "../core/Model.js" as Model

// Views bind to observed settings; the shared service verifies and saves writes.
Item {
  id: root
  property var service: null
  readonly property var settings: service ? service.policies : ({})
  readonly property bool loaded: !!service && service.ready && service.state.graphReady === true
  property string error: ""
  property string pendingKey: ""
  readonly property bool busy: pendingKey !== "" || (!!service && service.transactionBusy)
  onSettingsChanged: settled()

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

  function clearError() { error = "" }

  function setSetting(key, value) {
    if (!loaded || busy || !Model.hasOwn(settings, key)) return
    var current = settings[key]
    if (typeof current !== typeof value) return
    if (typeof value === "number") {
      if (!isFinite(value)) return
      value = Math.max(0, Math.min(1, Math.round(value * 20) / 20))
    }
    if (value === current) return
    error = ""
    pendingKey = key
    service.request("policy.set", {
      generation: service.state.generation, key: key, value: value
    }, function(_result, failure) {
      root.pendingKey = ""
      root.error = failure ? failure.message : ""
      root.settled()
    })
  }
}
