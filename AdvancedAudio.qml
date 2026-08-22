import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Audio configuration belongs in a regular centered window rather than the
// compact bar popout. The quick panel and Setup > Audio both summon this same
// surface, while the shell host owns its lifetime like any other panel plugin.
Item {
  id: root

  property var shell: null
  property bool closingFromHost: false
  property bool openRequested: false
  property bool windowRuleReady: false
  readonly property bool opened: window.visible

  property var audioCards: []
  property var audioPorts: []
  property bool profilesLoaded: false
  property bool bluetoothAutoSwitch: true
  property bool bluetoothAutoSwitchLoaded: false
  property bool autoswitchMutation: false
  property string bluetoothProfilePreference: "quality"
  property bool bluetoothProfilePreferenceLoaded: false
  property bool bluetoothProfilePreferenceMutation: false
  property var policySettings: ({})
  property bool policySettingsLoaded: false
  property bool policyMutation: false
  property bool policyResponseValid: false
  property var previousPolicySettings: ({})
  property string pendingPolicyKey: ""
  property string microphoneTestState: "idle"
  property string microphoneTestOperation: ""
  property bool microphoneTestCancelled: false
  property int microphoneTestSecondsRemaining: 0
  property string microphoneTestError: ""
  property string profileLoadError: ""
  property string portLoadError: ""
  property string profileSetError: ""
  property string portSetError: ""
  property string bluetoothAutoswitchError: ""
  property string bluetoothPreferenceError: ""
  property string policyError: ""
  readonly property string error: {
    var errors = [profileSetError, portSetError, bluetoothAutoswitchError,
      bluetoothPreferenceError, policyError, profileLoadError, portLoadError]
    for (var i = 0; i < errors.length; i++) if (errors[i] !== "") return errors[i]
    return ""
  }
  property int activeTab: 0  // 0 = devices, 1 = Bluetooth, 2 = policy
  property bool cursorActive: false
  property int selectedIndex: 0
  property bool profileMenuOpen: false
  property var pendingSharedProfile: null
  property var audioPreferences: Model.parseAudioPreferences("")
  property var audioControlSettings: ({
    version: 1,
    outputOverdrive: false,
    captureNotifications: true
  })
  property bool outputOverdrive: false
  property bool captureNotifications: true

  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: Style.font.family
  readonly property var policyCoreDefinitions: [
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
  readonly property var policyVolumeDefinitions: [
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
  readonly property var policyExperimentalDefinitions: [
    {
      key: "monitor.alsa.autodetect-hdmi-channels",
      label: "Detect HDMI channel layout",
      description: "Let WirePlumber infer HDMI channel counts. Experimental; some receivers report them incorrectly."
    }
  ]
  readonly property var captureNotificationDefinition: ({
    key: "captureNotifications",
    label: "Capture-start notifications",
    description: "Notify when a new application begins using the microphone. Respects Do Not Disturb and ignores existing captures at shell startup."
  })
  readonly property var availablePolicyCore: supportedPolicyDefinitions(policyCoreDefinitions)
  readonly property var availablePolicyVolumes: supportedPolicyDefinitions(policyVolumeDefinitions)
  readonly property var availablePolicyExperimental: supportedPolicyDefinitions(policyExperimentalDefinitions)
  readonly property var bluetoothCards: Model.audioCardsByBluetooth(audioCards, true)
  readonly property var deviceCards: Model.audioCardsByBluetooth(audioCards, false)
  readonly property var pipewireNodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var defaultOutputDevice: Pipewire.defaultAudioSink
  property string volumeSinkName: ""
  readonly property var outputDevice: {
    if (!defaultOutputDevice || !volumeSinkName
        || String(defaultOutputDevice.name) === volumeSinkName) return defaultOutputDevice
    for (var i = 0; i < pipewireNodes.length; i++) {
      var node = pipewireNodes[i]
      if (node && node.isSink && !node.isStream && String(node.name) === volumeSinkName)
        return node
    }
    return defaultOutputDevice
  }
  readonly property var inputDevice: Pipewire.defaultAudioSource
  readonly property bool inputDeviceMuted: !inputDevice || !inputDevice.audio
    || inputDevice.audio.muted
  readonly property bool outputBalanceAvailable: balanceAvailable(outputDevice)
  readonly property bool inputBalanceAvailable: balanceAvailable(inputDevice)
  readonly property int audioPortStartIndex: 1
  readonly property int deviceProfileStartIndex: audioPortStartIndex + audioPorts.length
  readonly property int balanceStartIndex: deviceProfileStartIndex + deviceCards.length
  readonly property int outputBalanceIndex: outputBalanceAvailable ? balanceStartIndex : -1
  readonly property int inputBalanceIndex: inputBalanceAvailable
    ? balanceStartIndex + (outputBalanceAvailable ? 1 : 0) : -1
  readonly property int deviceItemCount: balanceStartIndex
    + (outputBalanceAvailable ? 1 : 0) + (inputBalanceAvailable ? 1 : 0)
  readonly property int microphoneTestIndex: inputDevice ? deviceItemCount : -1
  readonly property int policyVolumeStartIndex: availablePolicyCore.length
  readonly property int policyExperimentalStartIndex: policyVolumeStartIndex + availablePolicyVolumes.length
  readonly property int wireplumberPolicyItemCount: policyExperimentalStartIndex
    + availablePolicyExperimental.length
  readonly property int captureNotificationIndex: wireplumberPolicyItemCount
  readonly property int policyItemCount: wireplumberPolicyItemCount + 1
  readonly property int itemCount: activeTab === 0
    ? deviceItemCount + (inputDevice ? 1 : 0)
    : (activeTab === 1 ? 2 + bluetoothCards.length : policyItemCount)
  readonly property bool audioMutationBusy: profileSetProc.running || portSetProc.running
    || microphoneTestProc.running || microphoneTestStopProc.running
  readonly property real microphoneTestLevel: inputDevice && inputDevice.audio
    && !inputDevice.audio.muted
    ? Math.max(0, Math.min(1, Number(microphoneTestPeakMonitor.peak || 0))) : 0
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property string settingsPath: {
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome) configHome = Quickshell.env("HOME") + "/.config"
    return configHome + "/omarchy/audio-control.json"
  }
  readonly property string audioPreferencesPath: {
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome) configHome = Quickshell.env("HOME") + "/.config"
    return configHome + "/omarchy/audio-preferences.json"
  }
  onDefaultOutputDeviceChanged: resolveVolumeSink()
  onInputDeviceChanged: if (microphoneTestState !== "idle") discardMicrophoneTest()
  onInputDeviceMutedChanged: if (inputDeviceMuted && microphoneTestState === "recording")
    cancelMicrophoneTest()

  function pluginScript(name) {
    var url = String(Qt.resolvedUrl("scripts/" + name))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    activeTab = payload.tab === "bluetooth" ? 1 : (payload.tab === "policy" ? 2 : 0)
    openRequested = true
    closingFromHost = false
    cursorActive = false
    selectedIndex = 0
    clearErrors()
    profilesLoaded = false
    bluetoothAutoSwitchLoaded = false
    bluetoothProfilePreferenceLoaded = false
    policySettingsLoaded = false
    discardMicrophoneTest()
    if (windowRuleReady) showOnCurrentWorkspace()
    else if (!windowRuleProc.running) windowRuleProc.running = true
  }

  function clearErrors() {
    profileLoadError = ""
    portLoadError = ""
    profileSetError = ""
    portSetError = ""
    bluetoothAutoswitchError = ""
    bluetoothPreferenceError = ""
    policyError = ""
  }

  function showOnCurrentWorkspace() {
    if (!openRequested) return
    window.visible = true
    Quickshell.execDetached([pluginScript("place-advanced-window")])
    Qt.callLater(function() {
      if (!window.visible) return
      keyCatcher.forceActiveFocus()
      refresh()
    })
  }

  function close() {
    openRequested = false
    closingFromHost = true
    profileMenuOpen = false
    discardMicrophoneTest()
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    openRequested = false
    discardMicrophoneTest()
    if (shell && typeof shell.hide === "function") shell.hide("ssupt.audio-control")
    else window.visible = false
  }

  function refresh() {
    if (!window.visible) return
    if (!profilesProc.running && !profileSetProc.running) profilesProc.running = true
    if (!bluetoothAutoswitchProc.running) {
      autoswitchMutation = false
      bluetoothAutoswitchProc.command = [pluginScript("audio-bluetooth-autoswitch")]
      bluetoothAutoswitchProc.running = true
    }
    if (!bluetoothPreferenceProc.running) {
      bluetoothProfilePreferenceMutation = false
      bluetoothPreferenceProc.command = [pluginScript("audio-bluetooth-profile-preference")]
      bluetoothPreferenceProc.running = true
    }
    if (!portsProc.running && !portSetProc.running) portsProc.running = true
    if (!policyProc.running) {
      policyMutation = false
      policyResponseValid = false
      pendingPolicyKey = ""
      policyProc.command = [pluginScript("audio-policy-settings")]
      policyProc.running = true
    }
    resolveVolumeSink()
  }

  function resolveVolumeSink() {
    if (!volumeSinkProc.running) volumeSinkProc.running = true
  }

  function parseAudioProfiles(raw) {
    audioCards = Model.parseAudioProfiles(raw)
    profilesLoaded = true
    clampCursor()
  }

  function parseAudioPorts(raw) {
    audioPorts = Model.parseAudioPorts(raw)
    clampCursor()
  }

  function loadAudioPreferences(raw) {
    audioPreferences = Model.parseAudioPreferences(raw)
  }

  function loadAudioControlSettings(raw) {
    audioControlSettings = Model.parseAudioControlSettings(raw)
    outputOverdrive = audioControlSettings.outputOverdrive
    captureNotifications = audioControlSettings.captureNotifications
  }

  function supportedPolicyDefinitions(definitions) {
    var supported = []
    for (var i = 0; i < definitions.length; i++) {
      var definition = definitions[i]
      if (policySettings[definition.key] !== undefined) supported.push(definition)
    }
    return supported
  }

  function copyPolicySettings(source) {
    var copy = ({})
    for (var key in source) copy[key] = source[key]
    return copy
  }

  function loadPolicySettings(raw) {
    var response = Model.parseAudioPolicySettings(raw)
    policyResponseValid = response.valid
    if (!response.valid) return
    policySettings = response.values
    policySettingsLoaded = true
    clampCursor()
  }

  function setPolicySetting(key, value) {
    if (!policySettingsLoaded || policyProc.running || policySettings[key] === undefined) return
    var current = policySettings[key]
    var normalized
    if (typeof current === "boolean") {
      if (typeof value !== "boolean") return
      normalized = value
    } else {
      normalized = Math.max(0, Math.min(1, Math.round(Number(value) * 20) / 20))
      if (!isFinite(normalized)) return
    }
    if (normalized === current) return

    policyError = ""
    previousPolicySettings = copyPolicySettings(policySettings)
    var next = copyPolicySettings(policySettings)
    next[key] = normalized
    policySettings = next
    policyMutation = true
    policyResponseValid = false
    pendingPolicyKey = key
    policyProc.command = [pluginScript("audio-policy-settings"), "set", key, String(normalized)]
    policyProc.running = true
  }

  function policyToggleAtCursor() {
    if (activeTab !== 2) return null
    if (selectedIndex < availablePolicyCore.length)
      return availablePolicyCore[selectedIndex]
    if (selectedIndex >= policyExperimentalStartIndex) {
      var experimentalIndex = selectedIndex - policyExperimentalStartIndex
      if (experimentalIndex < availablePolicyExperimental.length)
        return availablePolicyExperimental[experimentalIndex]
    }
    return null
  }

  function adjustPolicyVolumeAtCursor(delta) {
    if (activeTab !== 2) return false
    var index = selectedIndex - policyVolumeStartIndex
    if (index < 0 || index >= availablePolicyVolumes.length) return false
    var definition = availablePolicyVolumes[index]
    setPolicySetting(definition.key, Number(policySettings[definition.key]) + delta * 0.05)
    return true
  }

  function setOutputOverdrive(enabled) {
    setAudioControlSetting("outputOverdrive", enabled)
  }

  function setCaptureNotifications(enabled) {
    setAudioControlSetting("captureNotifications", enabled)
  }

  function setAudioControlSetting(key, value) {
    var next = ({})
    for (var setting in audioControlSettings) next[setting] = audioControlSettings[setting]
    next.version = 1
    next[key] = value
    audioControlSettings = next
    if (key === "outputOverdrive") outputOverdrive = value
    else if (key === "captureNotifications") captureNotifications = value
    settingsFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function startMicrophoneTestRecording() {
    if (!inputDevice || !inputDevice.name || inputDeviceMuted || microphoneTestProc.running
        || microphoneTestStopProc.running) return
    microphoneTestError = ""
    microphoneTestCancelled = false
    microphoneTestOperation = "record"
    microphoneTestState = "recording"
    microphoneTestSecondsRemaining = 5
    microphoneTestProc.command = [
      pluginScript("audio-microphone-test"),
      "record",
      String(inputDevice.name)
    ]
    microphoneTestProc.running = true
    microphoneTestCountdown.restart()
  }

  function playMicrophoneTest() {
    if (microphoneTestState !== "ready" || microphoneTestProc.running
        || microphoneTestStopProc.running) return
    microphoneTestError = ""
    microphoneTestCancelled = false
    microphoneTestOperation = "play"
    microphoneTestState = "playing"
    microphoneTestProc.command = [pluginScript("audio-microphone-test"), "play"]
    microphoneTestProc.running = true
  }

  function stopMicrophoneTestRecording() {
    if (microphoneTestState !== "recording" || !microphoneTestProc.running
        || microphoneTestStopProc.running) return
    microphoneTestError = ""
    microphoneTestState = "stopping"
    microphoneTestCountdown.stop()
    microphoneTestSecondsRemaining = 0
    microphoneTestStopProc.command = [pluginScript("audio-microphone-test"), "stop"]
    microphoneTestStopProc.running = true
  }

  function cancelMicrophoneTest() {
    if (!microphoneTestProc.running) return
    var operation = microphoneTestOperation
    microphoneTestCancelled = true
    microphoneTestProc.running = false
    microphoneTestCountdown.stop()
    microphoneTestSecondsRemaining = 0
    microphoneTestState = operation === "record" ? "idle" : "ready"
    if (operation === "record")
      Quickshell.execDetached([pluginScript("audio-microphone-test"), "clear"])
  }

  function discardMicrophoneTest() {
    if (microphoneTestStopProc.running) microphoneTestStopProc.running = false
    if (microphoneTestProc.running) cancelMicrophoneTest()
    microphoneTestCountdown.stop()
    microphoneTestSecondsRemaining = 0
    microphoneTestState = "idle"
    microphoneTestError = ""
    Quickshell.execDetached([pluginScript("audio-microphone-test"), "clear"])
  }

  function activateMicrophoneTest() {
    if (microphoneTestState === "stopping") return
    if (microphoneTestState === "recording") stopMicrophoneTestRecording()
    else if (microphoneTestProc.running) cancelMicrophoneTest()
    else if (microphoneTestState === "ready") playMicrophoneTest()
    else startMicrophoneTestRecording()
  }

  function profileOptions(card) {
    return Model.audioProfileOptions(card)
  }

  function selectedAudioProfile(card) {
    if (!card) return ""
    if (!card.bluetooth) return String(card.activeProfile || "off")
    return Model.preferredAudioProfile(
      audioPreferences, card.address, profileOptions(card), card.activeProfile)
  }

  function nodeLabel(node) {
    return Model.nodeLabel(node)
  }

  function stereoIndices(node) {
    if (!node || !node.audio || !node.audio.channels || !node.audio.volumes)
      return { left: -1, right: -1 }
    var channels = node.audio.channels
    var left = -1
    var right = -1
    for (var i = 0; i < channels.length; i++) {
      if (channels[i] === PwAudioChannel.FrontLeft) left = i
      else if (channels[i] === PwAudioChannel.FrontRight) right = i
    }
    if ((left < 0 || right < 0) && node.audio.volumes.length === 2)
      return { left: 0, right: 1 }
    return { left: left, right: right }
  }

  function balanceAvailable(node) {
    var indices = stereoIndices(node)
    return indices.left >= 0 && indices.right >= 0
  }

  function balanceFor(node) {
    if (!node || !node.audio) return 0
    var indices = stereoIndices(node)
    if (indices.left < 0 || indices.right < 0) return 0
    return Model.balanceValue(node.audio.volumes[indices.left], node.audio.volumes[indices.right])
  }

  function setBalance(node, value) {
    if (!node || !node.audio) return
    var indices = stereoIndices(node)
    if (indices.left < 0 || indices.right < 0) return
    node.audio.volumes = Model.applyBalance(node.audio.volumes, indices.left, indices.right, value)
  }

  function adjustBalanceAtCursor(delta) {
    var node = selectedIndex === outputBalanceIndex ? outputDevice
      : (selectedIndex === inputBalanceIndex ? inputDevice : null)
    if (!node) return false
    setBalance(node, balanceFor(node) + delta * 0.1)
    return true
  }

  function clampCursor() {
    selectedIndex = Math.max(0, Math.min(Math.max(0, itemCount - 1), selectedIndex))
  }
  onItemCountChanged: clampCursor()

  function moveCursor(delta) {
    if (itemCount === 0) return
    selectedIndex = Math.max(0, Math.min(itemCount - 1, selectedIndex + delta))
  }

  function closeProfileMenus() {
    bluetoothPreferenceDropdown.close()
    var repeaters = [deviceProfileRepeater, bluetoothProfileRepeater, audioPortRepeater]
    for (var r = 0; r < repeaters.length; r++) {
      var repeater = repeaters[r]
      if (!repeater) continue
      for (var i = 0; i < repeater.count; i++) {
        var row = repeater.itemAt(i)
        if (!row) continue
        if (typeof row.closeProfileMenu === "function") row.closeProfileMenu()
        if (typeof row.closePortMenu === "function") row.closePortMenu()
      }
    }
  }

  function selectTab(index) {
    var next = Math.max(0, Math.min(2, index))
    if (next === activeTab) return
    closeProfileMenus()
    activeTab = next
    selectedIndex = 0
    clampCursor()
    var flick = scrollArea ? scrollArea.contentItem : null
    if (flick && flick.contentY !== undefined) flick.contentY = 0
  }

  function switchTab(direction) {
    selectTab((activeTab + (direction < 0 ? -1 : 1) + 3) % 3)
  }

  function setCursor(index) {
    cursorActive = true
    selectedIndex = index
  }

  function activateCursor() {
    if (!cursorActive || itemCount === 0) return
    if (activeTab === 2) {
      if (selectedIndex === captureNotificationIndex) {
        setCaptureNotifications(!captureNotifications)
        return
      }
      var policyToggle = policyToggleAtCursor()
      if (policyToggle)
        setPolicySetting(policyToggle.key, policySettings[policyToggle.key] !== true)
      return
    }
    if (activeTab === 0 && selectedIndex === 0) {
      setOutputOverdrive(!outputOverdrive)
      return
    }
    if (activeTab === 0
        && (selectedIndex === outputBalanceIndex || selectedIndex === inputBalanceIndex)) {
      var balanceNode = selectedIndex === outputBalanceIndex ? outputDevice : inputDevice
      setBalance(balanceNode, 0)
      return
    }
    if (activeTab === 0 && selectedIndex >= audioPortStartIndex
        && selectedIndex < deviceProfileStartIndex) {
      var portRow = audioPortRepeater.itemAt(selectedIndex - audioPortStartIndex)
      if (portRow) portRow.togglePortMenu()
      return
    }
    if (activeTab === 0 && selectedIndex === microphoneTestIndex) {
      activateMicrophoneTest()
      return
    }
    if (activeTab === 1 && selectedIndex === 0) {
      setBluetoothAutoSwitch(!bluetoothAutoSwitch)
      return
    }
    if (activeTab === 1 && selectedIndex === 1) {
      if (bluetoothPreferenceDropdown.enabled) bluetoothPreferenceDropdown.toggle()
      return
    }
    var row = activeTab === 0
      ? deviceProfileRepeater.itemAt(selectedIndex - deviceProfileStartIndex)
      : bluetoothProfileRepeater.itemAt(selectedIndex - 2)
    if (row) row.toggleProfileMenu()
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var point = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = point.y
    var bottom = top + (item.height || 0)
    var margin = Style.space(12)
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = bottom + margin - flick.height
  }

  function setAudioProfile(card, profile) {
    if (!card || !card.name || !profile || audioMutationBusy) return
    profileSetError = ""
    pendingSharedProfile = card.bluetooth && card.address ? {
      address: String(card.address),
      profile: String(profile)
    } : null
    profileSetProc.command = [pluginScript("audio-profile-set"), String(card.name), profile]
    profileSetProc.running = true
  }

  function setAudioPort(port, value) {
    if (!port || !value || audioMutationBusy) return
    portSetError = ""
    portSetProc.command = [pluginScript("audio-port-set"), port.direction, port.endpoint, value]
    portSetProc.running = true
  }

  function setBluetoothAutoSwitch(enabled) {
    if (!bluetoothAutoSwitchLoaded || bluetoothAutoswitchProc.running) return
    bluetoothAutoswitchError = ""
    autoswitchMutation = true
    bluetoothAutoswitchProc.command = [pluginScript("audio-bluetooth-autoswitch"), enabled ? "on" : "off"]
    bluetoothAutoswitchProc.running = true
  }

  function setBluetoothProfilePreference(value) {
    if (!bluetoothProfilePreferenceLoaded || bluetoothPreferenceProc.running
        || (value !== "quality" && value !== "latency")) return
    bluetoothPreferenceError = ""
    bluetoothProfilePreferenceMutation = true
    bluetoothPreferenceProc.command = [pluginScript("audio-bluetooth-profile-preference"), value]
    bluetoothPreferenceProc.running = true
  }

  Process {
    id: windowRuleProc
    command: [root.pluginScript("prepare-advanced-window")]
    onExited: function(_exitCode) {
      // The placement helper below remains a fallback if Hyprland rejected
      // the pre-map rule. Do not leave the settings inaccessible on another
      // compositor merely because it has no Hyprland rule API.
      root.windowRuleReady = true
      root.showOnCurrentWorkspace()
    }
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadAudioControlSettings(text())
    onLoadFailed: root.loadAudioControlSettings("")
    onFileChanged: reload()
  }

  FileView {
    path: root.audioPreferencesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadAudioPreferences(text())
    onLoadFailed: root.loadAudioPreferences("")
    onFileChanged: reload()
  }

  PwObjectTracker { objects: root.outputDevice ? [root.outputDevice] : [] }
  PwObjectTracker { objects: root.inputDevice ? [root.inputDevice] : [] }

  PwNodePeakMonitor {
    id: microphoneTestPeakMonitor
    node: root.inputDevice
    enabled: window.visible && root.microphoneTestState === "recording" && !!root.inputDevice
  }

  Process {
    id: profilesProc
    command: [root.pluginScript("audio-profiles")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseAudioProfiles(text)
    }
    onExited: function(exitCode) {
      root.profilesLoaded = true
      root.profileLoadError = exitCode !== 0 && window.visible
        ? "Could not load audio profiles" : ""
    }
  }

  Process {
    id: volumeSinkProc
    command: ["omarchy-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumeSinkName = String(text || "").trim()
    }
  }

  Process {
    id: portsProc
    command: [root.pluginScript("audio-ports")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseAudioPorts(text)
    }
    onExited: function(exitCode) {
      root.portLoadError = exitCode !== 0 && window.visible
        ? "Could not load audio ports" : ""
    }
  }

  Process {
    id: profileSetProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.profileSetError = "Could not change the audio profile"
      else {
        root.profileSetError = ""
        if (root.pendingSharedProfile)
          Quickshell.execDetached([
            root.pluginScript("audio-preferences"),
            "set-profile",
            root.pendingSharedProfile.address,
            root.pendingSharedProfile.profile
          ])
      }
      root.pendingSharedProfile = null
      profileRefreshTimer.restart()
    }
  }

  Process {
    id: portSetProc
    onExited: function(exitCode) {
      root.portSetError = exitCode !== 0 ? "Could not change the audio port" : ""
      portRefreshTimer.restart()
    }
  }

  Process {
    id: bluetoothAutoswitchProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = String(text || "").trim()
        if (value === "true" || value === "false") {
          root.bluetoothAutoSwitch = value === "true"
          root.bluetoothAutoSwitchLoaded = true
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.bluetoothAutoswitchError = root.autoswitchMutation
          ? "Could not change automatic headset mode"
          : "Could not load automatic headset mode"
      else root.bluetoothAutoswitchError = ""
      root.autoswitchMutation = false
    }
  }

  Process {
    id: bluetoothPreferenceProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var value = String(text || "").trim()
        if (value === "quality" || value === "latency") {
          root.bluetoothProfilePreference = value
          root.bluetoothProfilePreferenceLoaded = true
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0)
        root.bluetoothPreferenceError = root.bluetoothProfilePreferenceMutation
          ? "Could not change Bluetooth profile preference"
          : "Could not load Bluetooth profile preference"
      else root.bluetoothPreferenceError = ""
      root.bluetoothProfilePreferenceMutation = false
    }
  }

  Process {
    id: policyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadPolicySettings(text)
    }
    onExited: function(exitCode) {
      var mutation = root.policyMutation
      if (exitCode !== 0 || !root.policyResponseValid) {
        if (mutation) root.policySettings = root.previousPolicySettings
        else root.policySettings = ({})
        root.policySettingsLoaded = true
        root.policyError = mutation
          ? "Could not change the audio safety policy"
          : "Could not load audio safety policies"
      } else {
        root.policyError = ""
      }
      root.policyMutation = false
      root.pendingPolicyKey = ""
      root.previousPolicySettings = ({})
      root.clampCursor()
    }
  }

  Process {
    id: microphoneTestProc
    onExited: function(exitCode) {
      var operation = root.microphoneTestOperation
      microphoneTestCountdown.stop()
      root.microphoneTestSecondsRemaining = 0
      if (root.microphoneTestCancelled) {
        root.microphoneTestCancelled = false
        root.microphoneTestOperation = ""
        return
      }

      if (operation === "record") {
        if (exitCode === 0) {
          root.microphoneTestState = "ready"
          root.microphoneTestError = ""
        }
        else {
          root.microphoneTestState = "idle"
          root.microphoneTestError = "Could not record the microphone test"
          Quickshell.execDetached([root.pluginScript("audio-microphone-test"), "clear"])
        }
      } else if (operation === "play") {
        root.microphoneTestState = "ready"
        if (exitCode !== 0) root.microphoneTestError = "Could not play the microphone test"
      }
      root.microphoneTestOperation = ""
    }
  }

  Process {
    id: microphoneTestStopProc
    onExited: function(exitCode) {
      // A failed stop request must not strand the row in the stopping state:
      // if the recorder is still running, tear it down like a cancellation.
      if (exitCode !== 0 && root.microphoneTestState === "stopping"
          && root.microphoneTestProc.running) {
        root.microphoneTestError = "Could not stop the microphone test"
        root.cancelMicrophoneTest()
      }
    }
  }

  Timer {
    id: profileRefreshTimer
    interval: 200
    repeat: false
    onTriggered: if (window.visible && !profilesProc.running) profilesProc.running = true
  }

  Timer {
    id: microphoneTestCountdown
    interval: 1000
    repeat: true
    onTriggered: if (root.microphoneTestState === "recording")
      root.microphoneTestSecondsRemaining = Math.max(0, root.microphoneTestSecondsRemaining - 1)
  }

  Timer {
    id: portRefreshTimer
    interval: 200
    repeat: false
    onTriggered: if (window.visible && !portsProc.running) portsProc.running = true
  }

  Timer {
    interval: 2000
    running: window.visible
    repeat: true
    onTriggered: if (!root.profileMenuOpen && !profilesProc.running && !profileSetProc.running
        && !portsProc.running && !portSetProc.running) {
      profilesProc.running = true
      portsProc.running = true
    }
  }


  Timer {
    interval: 15000
    running: window.visible
    repeat: true
    triggeredOnStart: true
    onTriggered: root.resolveVolumeSink()
  }

  FloatingWindow {
    id: window
    title: "Advanced Audio Control"
    visible: false
    color: root.background
    implicitWidth: 680
    implicitHeight: 560
    minimumSize: Qt.size(520, 440)

    onVisibleChanged: {
      if (!visible && !root.closingFromHost) {
        root.discardMicrophoneTest()
        if (root.shell && typeof root.shell.hide === "function")
          root.shell.hide("ssupt.audio-control")
      }
    }

    FocusScope {
      anchors.fill: parent
      focus: true

      PanelKeyCatcher {
        id: keyCatcher
        anchors.fill: parent
        blocked: root.profileMenuOpen
          onMoveRequested: function(dx, dy) {
            if (dx !== 0) {
              root.cursorActive = true
              if (root.activeTab === 0 && root.adjustBalanceAtCursor(dx)) return
              if (root.activeTab === 2 && root.adjustPolicyVolumeAtCursor(dx)) return
              root.switchTab(dx)
            return
          }
          if (!root.cursorActive) { root.cursorActive = true; return }
          if (dy !== 0) root.moveCursor(dy)
        }
        onTabRequested: function(direction) { root.switchTab(direction) }
        onActivateRequested: root.activateCursor()
        onCloseRequested: root.requestClose()

        Column {
          id: frame
          anchors.fill: parent
          anchors.margins: Style.space(22)
          spacing: Style.space(18)

          Column {
            id: fixedHeader
            width: parent.width
            spacing: Style.space(18)

            Row {
              width: parent.width
              spacing: Style.space(14)

              Text {
                text: ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - parent.children[0].width - parent.spacing
                spacing: Style.space(3)

                Text {
                  text: "Audio"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.iconLarge
                  font.bold: true
                }

                Text {
                  width: parent.width
                  text: "Configure devices, Bluetooth behavior, and system-wide audio safety."
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }
            }

            PanelSeparator { foreground: root.foreground }

            ButtonGroup {
              options: [
                { value: "devices", label: "Devices", icon: "󰓃" },
                { value: "bluetooth", label: "Bluetooth", icon: "󰂯" },
                { value: "policy", label: "Policy", icon: "󰒃" }
              ]
              value: root.activeTab === 0 ? "devices" : (root.activeTab === 1 ? "bluetooth" : "policy")
              focusable: false
              foreground: root.foreground
              background: root.background
              fontFamily: root.fontFamily
              onChanged: function(value) {
                root.selectTab(value === "bluetooth" ? 1 : (value === "policy" ? 2 : 0))
              }
            }
          }

          ScrollView {
            id: scrollArea
            width: parent.width
            height: Math.max(0, frame.height - fixedHeader.height - frame.spacing)
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
            ScrollBar.vertical: ScrollBar {
              id: advancedScrollBar
              policy: content.implicitHeight > scrollArea.height
                ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
              interactive: false
              width: Style.space(5)
              background: Item { }
              contentItem: Rectangle {
                implicitWidth: Style.space(3)
                radius: width / 2
                color: root.foreground
                opacity: advancedScrollBar.active ? 0.55 : 0.25
              }
            }

            Column {
              id: content
              width: scrollArea.availableWidth
              spacing: Style.space(18)

              Column {
                visible: root.activeTab === 0
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  text: "OUTPUT RANGE"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                CursorSurface {
                  id: outputOverdriveRow
                  width: parent.width
                  implicitHeight: outputOverdriveContent.implicitHeight + Style.space(18)
                  hasCursor: root.cursorActive && root.activeTab === 0 && root.selectedIndex === 0
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(outputOverdriveRow)
                  foreground: root.foreground
                  fill: root.hoverFill
                  bordered: true

                  Row {
                    id: outputOverdriveContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    spacing: Style.space(12)

                    Column {
                      width: parent.width - outputOverdriveToggle.width - parent.spacing
                      spacing: Style.space(3)

                      Text {
                        width: parent.width
                        text: "Allow volume boost"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: "Extend the main output volume range from 100% to 150%."
                        color: Qt.darker(root.foreground, 1.35)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                      }
                    }

                    ToggleSwitch {
                      id: outputOverdriveToggle
                      checked: root.outputOverdrive
                      interactive: false
                      cursorRing: false
                      foreground: root.foreground
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onContainsMouseChanged: if (containsMouse) root.setCursor(0)
                    onClicked: root.setOutputOverdrive(!root.outputOverdrive)
                  }
                }
              }

              PanelSeparator {
                visible: root.activeTab === 0
                foreground: root.foreground
              }

              Column {
                visible: root.activeTab === 0 && root.audioPorts.length > 0
                width: parent.width
                spacing: Style.space(12)

                PanelSectionHeader {
                  text: "DEVICE PORTS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  id: audioPortRepeater
                  model: root.audioPorts

                  PortRow {
                    required property var modelData
                    required property int index
                    width: parent.width
                    port: modelData
                    rowIndex: root.audioPortStartIndex + index
                  }
                }
              }

              PanelSeparator {
                visible: root.activeTab === 0 && root.audioPorts.length > 0
                foreground: root.foreground
              }

              Column {
                visible: root.activeTab === 1
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  text: "BLUETOOTH POLICY"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                CursorSurface {
                  id: autoswitchRow
                  width: parent.width
                  implicitHeight: autoswitchContent.implicitHeight + Style.space(18)
                  hasCursor: root.cursorActive && root.selectedIndex === 0
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(autoswitchRow)
                  foreground: root.foreground
                  fill: root.hoverFill
                  bordered: true

                  Row {
                    id: autoswitchContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    spacing: Style.space(12)

                    Column {
                      width: parent.width - autoswitchToggle.width - parent.spacing
                      spacing: Style.space(3)

                      Text {
                        width: parent.width
                        text: "Automatic headset mode"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: "Switch to headset mode when an application records."
                        color: Qt.darker(root.foreground, 1.35)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                      }
                    }

                    ToggleSwitch {
                      id: autoswitchToggle
                      checked: root.bluetoothAutoSwitch
                      busy: bluetoothAutoswitchProc.running
                      interactive: false
                      cursorRing: false
                      foreground: root.foreground
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    enabled: root.bluetoothAutoSwitchLoaded && !bluetoothAutoswitchProc.running
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onContainsMouseChanged: if (containsMouse) root.setCursor(0)
                    onClicked: root.setBluetoothAutoSwitch(!root.bluetoothAutoSwitch)
                  }
                }

                CursorSurface {
                  id: bluetoothPreferenceRow
                  width: parent.width
                  implicitHeight: Math.max(bluetoothPreferenceLabels.implicitHeight,
                    bluetoothPreferenceDropdown.implicitHeight) + Style.space(18)
                  hasCursor: root.cursorActive && root.selectedIndex === 1
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(bluetoothPreferenceRow)
                  foreground: root.foreground
                  fill: root.hoverFill
                  bordered: true

                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    spacing: Style.space(16)

                    Column {
                      id: bluetoothPreferenceLabels
                      width: Math.max(Style.space(180), parent.width * 0.4)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(3)

                      Text {
                        width: parent.width
                        text: "Profile preference"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: "Automatic profile selection"
                        color: Qt.darker(root.foreground, 1.35)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    AudioDropdown {
                      id: bluetoothPreferenceDropdown
                      width: parent.width - bluetoothPreferenceLabels.width - parent.spacing
                      showLabel: false
                      popupDirection: "down"
                      value: root.bluetoothProfilePreference
                      options: [
                        { value: "quality", label: "Prefer quality" },
                        { value: "latency", label: "Prefer lower latency" }
                      ]
                      hasCursor: bluetoothPreferenceRow.hasCursor
                      enabled: root.bluetoothProfilePreferenceLoaded && !bluetoothPreferenceProc.running
                      opacity: enabled ? 1 : 0.6
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      anchors.verticalCenter: parent.verticalCenter

                      onHovered: function(on) { if (on) root.setCursor(1) }
                      onChanged: function(value) { root.setBluetoothProfilePreference(value) }
                      onPopupOpenChanged: {
                        root.profileMenuOpen = popupOpen
                        if (!popupOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    hoverEnabled: true
                    onContainsMouseChanged: if (containsMouse) root.setCursor(1)
                  }
                }
              }

              PanelSeparator {
                visible: root.activeTab === 1
                foreground: root.foreground
              }

              Column {
                visible: root.activeTab === 2
                width: parent.width
                spacing: Style.space(18)

                Text {
                  visible: !root.policySettingsLoaded
                  width: parent.width
                  text: "Loading audio safety policies…"
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  visible: root.policySettingsLoaded && root.wireplumberPolicyItemCount === 0
                    && root.policyError === ""
                  width: parent.width
                  text: "This WirePlumber version does not expose the supported policy controls."
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: root.policySettingsLoaded && root.wireplumberPolicyItemCount > 0
                  width: parent.width
                  text: "WirePlumber policies apply system-wide and are saved immediately. Unsupported controls are hidden automatically."
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Column {
                  visible: root.availablePolicyCore.length > 0
                  width: parent.width
                  spacing: Style.space(8)

                  PanelSectionHeader {
                    text: "SAFETY & ACCESSIBILITY"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Repeater {
                    model: root.availablePolicyCore

                    AudioPolicyToggleRow {
                      id: policyCoreRow
                      required property var modelData
                      required property int index
                      width: parent.width
                      definition: modelData
                      checked: root.policySettings[modelData.key] === true
                      busy: policyProc.running && root.pendingPolicyKey === modelData.key
                      enabled: root.policySettingsLoaded && !policyProc.running
                      opacity: enabled ? 1 : 0.6
                      hasCursor: root.cursorActive && root.activeTab === 2
                        && root.selectedIndex === index
                      foreground: root.foreground
                      fill: root.hoverFill
                      fontFamily: root.fontFamily
                      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(policyCoreRow)
                      onHovered: root.setCursor(index)
                      onActivated: root.setPolicySetting(modelData.key, !checked)
                    }
                  }
                }

                PanelSeparator {
                  visible: root.availablePolicyCore.length > 0
                    && (root.availablePolicyVolumes.length > 0
                      || root.availablePolicyExperimental.length > 0)
                  foreground: root.foreground
                }

                Column {
                  visible: root.availablePolicyVolumes.length > 0
                  width: parent.width
                  spacing: Style.space(8)

                  PanelSectionHeader {
                    text: "STARTING VOLUMES"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Repeater {
                    model: root.availablePolicyVolumes

                    AudioPolicyVolumeRow {
                      id: policyVolumeRow
                      required property var modelData
                      required property int index
                      readonly property int rowIndex: root.policyVolumeStartIndex + index
                      width: parent.width
                      definition: modelData
                      value: Number(root.policySettings[modelData.key])
                      enabled: root.policySettingsLoaded && !policyProc.running
                      opacity: enabled ? 1 : 0.6
                      hasCursor: root.cursorActive && root.activeTab === 2
                        && root.selectedIndex === rowIndex
                      foreground: root.foreground
                      fill: root.hoverFill
                      fontFamily: root.fontFamily
                      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(policyVolumeRow)
                      onHovered: root.setCursor(rowIndex)
                      onCommitted: function(value) { root.setPolicySetting(modelData.key, value) }
                    }
                  }
                }

                PanelSeparator {
                  visible: root.availablePolicyExperimental.length > 0
                    && (root.availablePolicyCore.length > 0 || root.availablePolicyVolumes.length > 0)
                  foreground: root.foreground
                }

                Column {
                  visible: root.availablePolicyExperimental.length > 0
                  width: parent.width
                  spacing: Style.space(8)

                  PanelSectionHeader {
                    text: "EXPERIMENTAL"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Repeater {
                    model: root.availablePolicyExperimental

                    AudioPolicyToggleRow {
                      id: policyExperimentalRow
                      required property var modelData
                      required property int index
                      readonly property int rowIndex: root.policyExperimentalStartIndex + index
                      width: parent.width
                      definition: modelData
                      checked: root.policySettings[modelData.key] === true
                      busy: policyProc.running && root.pendingPolicyKey === modelData.key
                      enabled: root.policySettingsLoaded && !policyProc.running
                      opacity: enabled ? 1 : 0.6
                      hasCursor: root.cursorActive && root.activeTab === 2
                        && root.selectedIndex === rowIndex
                      foreground: root.foreground
                      fill: root.hoverFill
                      fontFamily: root.fontFamily
                      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(policyExperimentalRow)
                      onHovered: root.setCursor(rowIndex)
                      onActivated: root.setPolicySetting(modelData.key, !checked)
                    }
                  }
                }

                PanelSeparator {
                  visible: root.wireplumberPolicyItemCount > 0
                  foreground: root.foreground
                }

                Column {
                  width: parent.width
                  spacing: Style.space(8)

                  PanelSectionHeader {
                    text: "MICROPHONE PRIVACY"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  AudioPolicyToggleRow {
                    id: captureNotificationRow
                    width: parent.width
                    definition: root.captureNotificationDefinition
                    checked: root.captureNotifications
                    enabled: true
                    hasCursor: root.cursorActive && root.activeTab === 2
                      && root.selectedIndex === root.captureNotificationIndex
                    foreground: root.foreground
                    fill: root.hoverFill
                    fontFamily: root.fontFamily
                    onHasCursorChanged: if (hasCursor)
                      root.ensureCursorVisible(captureNotificationRow)
                    onHovered: root.setCursor(root.captureNotificationIndex)
                    onActivated: root.setCaptureNotifications(!root.captureNotifications)
                  }
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(12)

                Text {
                  visible: !root.profilesLoaded
                    && ((root.activeTab === 0 && root.deviceCards.length === 0)
                      || (root.activeTab === 1 && root.bluetoothCards.length === 0))
                  text: "Loading device profiles…"
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  visible: root.profilesLoaded
                    && ((root.activeTab === 0 && root.deviceCards.length === 0)
                      || (root.activeTab === 1 && root.bluetoothCards.length === 0))
                  text: root.activeTab === 0
                    ? "No configurable audio devices found"
                    : "No Bluetooth audio device connected"
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Column {
                  visible: root.activeTab === 1 && root.bluetoothCards.length > 0
                  width: parent.width
                  spacing: Style.space(12)

                  PanelSectionHeader {
                    text: "BLUETOOTH CODECS"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Repeater {
                    id: bluetoothProfileRepeater
                    model: root.bluetoothCards

                    ProfileRow {
                      required property var modelData
                      required property int index
                      width: parent.width
                      card: modelData
                      rowIndex: 2 + index
                    }
                  }
                }

                Column {
                  visible: root.activeTab === 0 && root.deviceCards.length > 0
                  width: parent.width
                  spacing: Style.space(12)

                  PanelSectionHeader {
                    text: "DEVICE PROFILES"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Repeater {
                    id: deviceProfileRepeater
                    model: root.deviceCards

                    ProfileRow {
                      required property var modelData
                      required property int index
                      width: parent.width
                      card: modelData
                      rowIndex: root.deviceProfileStartIndex + index
                    }
                  }
                }

                PanelSeparator {
                  visible: root.activeTab === 0
                    && (root.outputBalanceAvailable || root.inputBalanceAvailable)
                  foreground: root.foreground
                }

                Column {
                  visible: root.activeTab === 0
                    && (root.outputBalanceAvailable || root.inputBalanceAvailable)
                  width: parent.width
                  spacing: Style.space(8)

                  PanelSectionHeader {
                    text: "CHANNEL BALANCE"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  BalanceRow {
                    visible: root.outputBalanceAvailable
                    node: root.outputDevice
                    label: "Output"
                    rowIndex: root.outputBalanceIndex
                  }

                  BalanceRow {
                    visible: root.inputBalanceAvailable
                    node: root.inputDevice
                    label: "Input"
                    rowIndex: root.inputBalanceIndex
                  }
                }

                PanelSeparator {
                  visible: root.activeTab === 0 && !!root.inputDevice
                  foreground: root.foreground
                }

                Column {
                  visible: root.activeTab === 0 && !!root.inputDevice
                  width: parent.width
                  spacing: Style.space(8)

                  PanelSectionHeader {
                    text: "MICROPHONE TEST"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  MicrophoneTestRow {
                    id: microphoneTestRow
                    width: parent.width
                    deviceLabel: root.nodeLabel(root.inputDevice)
                    state: root.microphoneTestState
                    secondsRemaining: root.microphoneTestSecondsRemaining
                    level: root.microphoneTestLevel
                    microphoneMuted: root.inputDeviceMuted
                    error: root.microphoneTestError
                    enabled: !profileSetProc.running && !portSetProc.running
                    hasCursor: root.cursorActive && root.activeTab === 0
                      && root.selectedIndex === root.microphoneTestIndex
                    foreground: root.foreground
                    fill: root.hoverFill
                    urgent: root.urgent
                    fontFamily: root.fontFamily
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(microphoneTestRow)
                    onHovered: root.setCursor(root.microphoneTestIndex)
                    onPrimaryActivated: root.activateMicrophoneTest()
                    onDiscarded: root.discardMicrophoneTest()
                  }
                }

                Text {
                  visible: root.error !== ""
                  width: parent.width
                  text: root.error
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }
            }
          }
        }
      }
    }
  }

  component PortRow: CursorSurface {
    id: portRow
    required property var port
    required property int rowIndex

    width: parent ? parent.width : 0
    implicitHeight: Math.max(portLabels.implicitHeight, portDropdown.implicitHeight) + Style.space(18)
    hasCursor: root.cursorActive && root.activeTab === 0 && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(portRow)
    foreground: root.foreground
    fill: root.hoverFill
    bordered: true

    function togglePortMenu() { if (portDropdown.enabled) portDropdown.toggle() }
    function closePortMenu() { portDropdown.close() }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(16)

      Column {
        id: portLabels
        width: Math.max(Style.space(180), parent.width * 0.4)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          width: parent.width
          text: portRow.port.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: portRow.port.direction === "output" ? "Output port" : "Input port"
          color: Qt.darker(root.foreground, 1.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      AudioDropdown {
        id: portDropdown
        width: parent.width - portLabels.width - parent.spacing
        showLabel: false
        popupDirection: "down"
        value: String(portRow.port.activePort || "")
        options: portRow.port.ports
        hasCursor: portRow.hasCursor
        enabled: !root.audioMutationBusy
        opacity: enabled ? 1 : 0.6
        foreground: root.foreground
        fontFamily: root.fontFamily
        anchors.verticalCenter: parent.verticalCenter

        onHovered: function(on) { if (on) root.setCursor(portRow.rowIndex) }
        onChanged: function(value) { root.setAudioPort(portRow.port, value) }
        onPopupOpenChanged: {
          root.profileMenuOpen = popupOpen
          if (!popupOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      hoverEnabled: true
      onContainsMouseChanged: if (containsMouse) root.setCursor(portRow.rowIndex)
    }
  }

  component BalanceRow: CursorSurface {
    id: balanceRow
    required property var node
    required property string label
    required property int rowIndex

    width: parent ? parent.width : 0
    implicitHeight: balanceColumn.implicitHeight + Style.space(18)
    hasCursor: root.cursorActive && root.activeTab === 0 && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(balanceRow)
    foreground: root.foreground
    fill: root.hoverFill
    bordered: true

    Column {
      id: balanceColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(4)

      Item {
        width: parent.width
        height: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

        Text {
          id: balanceLabel
          text: balanceRow.label + " · " + root.nodeLabel(balanceRow.node)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
          width: parent.width - balanceValue.width - Style.space(8)
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: balanceValue
          text: {
            var value = root.balanceFor(balanceRow.node)
            if (Math.abs(value) < 0.05) return "CENTER"
            return value < 0 ? "L " + Math.round(-value * 100) : "R " + Math.round(value * 100)
          }
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          text: "L"
          color: Qt.darker(root.foreground, 1.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
        }

        PanelSlider {
          width: parent.width - Style.space(40)
          minimum: -1
          maximum: 1
          step: 0.05
          value: root.balanceFor(balanceRow.node)
          tickCount: 3
          onMoved: function(value) { root.setBalance(balanceRow.node, value) }
        }

        Text {
          text: "R"
          color: Qt.darker(root.foreground, 1.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          width: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      hoverEnabled: true
      onContainsMouseChanged: if (containsMouse) root.setCursor(balanceRow.rowIndex)
    }
  }

  component ProfileRow: CursorSurface {
    id: profileRow
    required property var card
    required property int rowIndex

    width: parent ? parent.width : 0
    implicitHeight: Math.max(profileLabels.implicitHeight, profileDropdown.implicitHeight) + Style.space(18)
    hasCursor: root.cursorActive && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(profileRow)
    foreground: root.foreground
    fill: root.hoverFill
    bordered: true

    function toggleProfileMenu() { if (profileDropdown.enabled) profileDropdown.toggle() }
    function closeProfileMenu() { profileDropdown.close() }

    Component.onDestruction: if (profileDropdown.popupOpen) root.profileMenuOpen = false

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      spacing: Style.space(16)

      Column {
        id: profileLabels
        width: Math.max(Style.space(180), parent.width * 0.4)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          width: parent.width
          text: profileRow.card.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          visible: profileRow.card.bluetooth === true
          width: parent.width
          text: "Bluetooth audio"
          color: Qt.darker(root.foreground, 1.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      AudioDropdown {
        id: profileDropdown
        width: parent.width - profileLabels.width - parent.spacing
        showLabel: false
        popupDirection: "down"
        value: root.selectedAudioProfile(profileRow.card)
        options: root.profileOptions(profileRow.card)
        hasCursor: profileRow.hasCursor
        enabled: !root.audioMutationBusy
        opacity: enabled ? 1 : 0.6
        foreground: root.foreground
        fontFamily: root.fontFamily
        anchors.verticalCenter: parent.verticalCenter

        onHovered: function(on) { if (on) root.setCursor(profileRow.rowIndex) }
        onChanged: function(profile) { root.setAudioProfile(profileRow.card, profile) }
        onPopupOpenChanged: {
          root.profileMenuOpen = popupOpen
          if (!popupOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }
      }
    }
  }
}
