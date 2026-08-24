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

  AudioRuntime { id: runtime }
  AudioPolicyController {
    id: policy
    scriptPath: runtime.script("audio-policy-settings")
    onSettled: root.clampCursor()
  }
  AudioRulesController {
    id: rulesStore
    nodes: root.pipewireNodes
    rulesPath: runtime.rulesPath
    scriptPath: runtime.script("audio-app-rules")
    onRulesChanged: root.clampCursor()
    onWriteFinished: function(success) {
      if (!success) root.showSceneStatus(rulesStore.error, true)
    }
  }

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
  property var audioScenes: []
  property bool scenesLoaded: false
  readonly property var audioRules: rulesStore.rules
  property string newRuleApp: ""
  property string aliasEditingDevice: ""
  readonly property bool routingMutation: rulesStore.busy
  property var pendingSceneSave: null
  property string sceneStatus: ""
  property bool sceneStatusIsError: false
  property string profileLoadError: ""
  property string portLoadError: ""
  property string profileSetError: ""
  property string portSetError: ""
  property string bluetoothAutoswitchError: ""
  property string bluetoothPreferenceError: ""
  readonly property var policySettings: policy.settings
  readonly property bool policySettingsLoaded: policy.loaded
  readonly property string pendingPolicyKey: policy.pendingKey
  readonly property string policyError: policy.error
  readonly property string error: {
    var errors = [profileSetError, portSetError, bluetoothAutoswitchError,
      bluetoothPreferenceError, policyError, profileLoadError, portLoadError]
    for (var i = 0; i < errors.length; i++) if (errors[i] !== "") return errors[i]
    return ""
  }
  property int activeTab: 0  // 0 = devices, 1 = Bluetooth, 2 = policy, 3 = scenes, 4 = routing
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
  readonly property var captureNotificationDefinition: ({
    key: "captureNotifications",
    label: "Capture-start notifications",
    description: "Notify when a new application begins using the microphone. Respects Do Not Disturb and ignores existing captures at shell startup."
  })
  readonly property var availablePolicyCore: policy.availableCore
  readonly property var availablePolicyVolumes: policy.availableVolumes
  readonly property var availablePolicyExperimental: policy.availableExperimental
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
  readonly property int itemCount: activeTab === 4
    ? 2 + audioRules.appRules.length + managedDevices.length
    : (activeTab === 3
      ? 1 + audioScenes.length
      : (activeTab === 0
        ? deviceItemCount + (inputDevice ? 1 : 0)
        : (activeTab === 1 ? 2 + bluetoothCards.length : policyItemCount)))
  readonly property bool audioMutationBusy: profileSetProc.running || portSetProc.running
    || microphoneTest.busy
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  onDefaultOutputDeviceChanged: resolveVolumeSink()

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    activeTab = payload.tab === "bluetooth" ? 1
      : payload.tab === "policy" ? 2
      : payload.tab === "scenes" ? 3
      : payload.tab === "routing" ? 4 : 0
    openRequested = true
    closingFromHost = false
    cursorActive = false
    selectedIndex = 0
    clearErrors()
    profilesLoaded = false
    bluetoothAutoSwitchLoaded = false
    bluetoothProfilePreferenceLoaded = false
    microphoneTest.discard()
    cancelAliasEdit()
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
    policy.clearError()
  }

  function showOnCurrentWorkspace() {
    if (!openRequested) return
    window.visible = true
    Quickshell.execDetached([runtime.script("place-advanced-window")])
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
    microphoneTest.discard()
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    openRequested = false
    microphoneTest.discard()
    if (shell && typeof shell.hide === "function") shell.hide("ssupt.audio-control")
    else window.visible = false
  }

  function refresh() {
    if (!window.visible) return
    if (!profilesProc.running && !profileSetProc.running) profilesProc.running = true
    if (!bluetoothAutoswitchProc.running) {
      autoswitchMutation = false
      bluetoothAutoswitchProc.command = [runtime.script("audio-bluetooth-autoswitch")]
      bluetoothAutoswitchProc.running = true
    }
    if (!bluetoothPreferenceProc.running) {
      bluetoothProfilePreferenceMutation = false
      bluetoothPreferenceProc.command = [runtime.script("audio-bluetooth-profile-preference")]
      bluetoothPreferenceProc.running = true
    }
    if (!portsProc.running && !portSetProc.running) portsProc.running = true
    policy.refresh()
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
    policy.setSetting(definition.key, Number(policySettings[definition.key]) + delta * 0.05)
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
    if (bluetoothPreferenceRow) bluetoothPreferenceRow.closePreferenceMenu()
    if (newAppDropdown) newAppDropdown.close()
    if (newDeviceDropdown) newDeviceDropdown.close()
    var repeaters = [deviceProfileRepeater, bluetoothProfileRepeater, audioPortRepeater, routingRuleRepeater]
    for (var r = 0; r < repeaters.length; r++) {
      var repeater = repeaters[r]
      if (!repeater) continue
      for (var i = 0; i < repeater.count; i++) {
        var row = repeater.itemAt(i)
        if (!row) continue
        if (typeof row.closeProfileMenu === "function") row.closeProfileMenu()
        if (typeof row.closePortMenu === "function") row.closePortMenu()
        if (typeof row.closeTargetMenu === "function") row.closeTargetMenu()
      }
    }
  }

  function selectTab(index) {
    var next = Math.max(0, Math.min(4, index))
    if (next === activeTab) return
    closeProfileMenus()
    cancelAliasEdit()
    activeTab = next
    selectedIndex = 0
    clampCursor()
    var flick = scrollArea ? scrollArea.contentItem : null
    if (flick && flick.contentY !== undefined) flick.contentY = 0
  }

  function switchTab(direction) {
    selectTab((activeTab + (direction < 0 ? -1 : 1) + 5) % 5)
  }

  function setCursor(index) {
    // Mouse claims never scroll; keyboard navigation sets the flag itself.
    keyboardScrolling = false
    cursorActive = true
    selectedIndex = index
  }

  function activateCursor() {
    if (!cursorActive || itemCount === 0) return
    if (activeTab === 4) {
      if (selectedIndex === 0) newRuleAppRow.toggleAppMenu()
      else if (selectedIndex === 1) newRuleDeviceRow.toggleDeviceMenu()
      else if (selectedIndex < 2 + audioRules.appRules.length) {
        var ruleRow = routingRuleRepeater.itemAt(selectedIndex - 2)
        if (ruleRow) ruleRow.toggleTargetMenu()
      } else {
        var deviceIndex = selectedIndex - 2 - audioRules.appRules.length
        toggleDeviceFavorite(managedDevices[deviceIndex].name, managedDevices[deviceIndex].favorite)
      }
      return
    }
    if (activeTab === 3) {
      if (selectedIndex === 0) saveCurrentScene()
      else applySceneAt(selectedIndex - 1)
      return
    }
    if (activeTab === 2) {
      if (selectedIndex === captureNotificationIndex) {
        setCaptureNotifications(!captureNotifications)
        return
      }
      var policyToggle = policyToggleAtCursor()
      if (policyToggle)
        policy.setSetting(policyToggle.key, policySettings[policyToggle.key] !== true)
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
      microphoneTest.activate()
      return
    }
    if (activeTab === 1 && selectedIndex === 0) {
      setBluetoothAutoSwitch(!bluetoothAutoSwitch)
      return
    }
    if (activeTab === 1 && selectedIndex === 1) {
      bluetoothPreferenceRow.togglePreferenceMenu()
      return
    }
    var row = activeTab === 0
      ? deviceProfileRepeater.itemAt(selectedIndex - deviceProfileStartIndex)
      : bluetoothProfileRepeater.itemAt(selectedIndex - 2)
    if (row) row.toggleProfileMenu()
  }

  // Mouse hovering claims the cursor without scrolling: the wheel and the
  // keyboard own scroll position here. Keyboard steps opt in below.
  property bool keyboardScrolling: false

  function ensureCursorVisible(item) {
    if (!keyboardScrolling) return
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
    profileSetProc.command = [runtime.script("audio-profile-set"), String(card.name), profile]
    profileSetProc.running = true
  }

  function setAudioPort(port, value) {
    if (!port || !value || audioMutationBusy) return
    portSetError = ""
    portSetProc.command = [runtime.script("audio-port-set"), port.direction, port.endpoint, value]
    portSetProc.running = true
  }

  function setBluetoothAutoSwitch(enabled) {
    if (!bluetoothAutoSwitchLoaded || bluetoothAutoswitchProc.running) return
    bluetoothAutoswitchError = ""
    autoswitchMutation = true
    bluetoothAutoswitchProc.command = [runtime.script("audio-bluetooth-autoswitch"), enabled ? "on" : "off"]
    bluetoothAutoswitchProc.running = true
  }

  function setBluetoothProfilePreference(value) {
    if (!bluetoothProfilePreferenceLoaded || bluetoothPreferenceProc.running
        || (value !== "quality" && value !== "latency")) return
    bluetoothPreferenceError = ""
    bluetoothProfilePreferenceMutation = true
    bluetoothPreferenceProc.command = [runtime.script("audio-bluetooth-profile-preference"), value]
    bluetoothPreferenceProc.running = true
  }

  Process {
    id: windowRuleProc
    command: [runtime.script("prepare-advanced-window")]
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
    path: runtime.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadAudioControlSettings(text())
    onLoadFailed: root.loadAudioControlSettings("")
    onFileChanged: reload()
  }

  FileView {
    path: runtime.preferencesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadAudioPreferences(text())
    onLoadFailed: root.loadAudioPreferences("")
    onFileChanged: reload()
  }

  FileView {
    path: runtime.scenesPath
    watchChanges: true
    printErrors: false
    onLoaded: function() {
      root.audioScenes = Model.parseAudioScenes(text()).scenes
      root.scenesLoaded = true
      root.clampCursor()
    }
    onLoadFailed: function() {
      root.audioScenes = []
      root.scenesLoaded = true
      root.clampCursor()
    }
    onFileChanged: reload()
  }

  function runRuleWrite(args) {
    return rulesStore.write(args)
  }

  AudioSceneController {
    id: sceneController
    scriptsDir: runtime.scriptsDir
    onCaptureFinished: function(scene) {
      root.pendingSceneSave = scene
      sceneStoreProc.command = [runtime.script("audio-scenes"), "save", scene.name,
        JSON.stringify(scene)]
      sceneStoreProc.running = true
    }
    onApplyFinished: function(result) {
      var text = "Applied scene '" + result.name + "'"
      if (result.errors.length > 0)
        root.showSceneStatus(text + ", but some steps failed", true)
      else if (result.skipped.length > 0)
        root.showSceneStatus(text + " · skipped: " + result.skipped.join(", "), false)
      else
        root.showSceneStatus(text, false)
    }
  }

  // Scene store writes go through the helper script so both surfaces stay
  // readers of the same flock-protected file.
  Process {
    id: sceneStoreProc
    onExited: function(exitCode) {
      var saving = root.pendingSceneSave !== null
      var name = saving ? root.pendingSceneSave.name : ""
      root.pendingSceneSave = null
      if (exitCode !== 0) {
        root.showSceneStatus(saving ? "Could not save scene '" + name + "'"
          : "Could not delete the scene", true)
        return
      }
      if (saving) root.showSceneStatus("Saved scene '" + name + "'", false)
    }
  }

  Timer {
    id: sceneStatusTimer
    interval: 6000
    onTriggered: root.sceneStatus = ""
  }

  function showSceneStatus(text, isError) {
    sceneStatus = text
    sceneStatusIsError = isError
    sceneStatusTimer.restart()
  }

  function nextSceneName() {
    var used = ({})
    for (var i = 0; i < audioScenes.length; i++) used[audioScenes[i].name] = true
    for (var n = 1; n < 100; n++)
      if (!used["Scene " + n]) return "Scene " + n
    return "Scene " + Math.floor(Math.random() * 100000)
  }

  function saveCurrentScene() {
    if (sceneController.busy || sceneStoreProc.running) return
    sceneStatus = ""
    sceneController.capture(nextSceneName())
  }

  function applySceneAt(index) {
    var scene = index >= 0 ? audioScenes[index] : null
    if (!scene || sceneController.busy || sceneStoreProc.running) return
    sceneStatus = ""
    sceneController.apply(scene)
  }

  function deleteSceneAt(index) {
    var scene = index >= 0 ? audioScenes[index] : null
    if (!scene || sceneController.busy || sceneStoreProc.running) return
    sceneStoreProc.command = [runtime.script("audio-scenes"), "delete", scene.name]
    sceneStoreProc.running = true
  }

  // ---- Routing tab helpers ----

  function deviceAliasFor(name) {
    return rulesStore.aliasFor(name)
  }

  function ruleDeviceLabel(name) {
    return rulesStore.deviceLabel(name)
  }

  function ruleTargetLive(name) {
    return rulesStore.targetIsLive(name)
  }

  function ruleTargetOptions(storedTarget) {
    return rulesStore.optionsFor("playback", storedTarget)
  }

  function recordingRuleTargetOptions(storedTarget) {
    return rulesStore.optionsFor("recording", storedTarget)
  }

  readonly property var managedDevices: rulesStore.managedDevices
  readonly property var newRuleAppOptions: rulesStore.availableApplicationLabels

  function cancelAliasEdit() {
    aliasEditingDevice = ""
  }

  // Renaming pulls keyboard focus into the text field; once the edit ends,
  // hand focus back so Escape and navigation work again.
  onAliasEditingDeviceChanged: {
    if (aliasEditingDevice === "" && window.visible)
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function commitAliasEdit(name, text) {
    cancelAliasEdit()
    var trimmed = String(text || "").trim()
    runRuleWrite(["set-alias", name, trimmed])
  }

  function toggleDeviceFavorite(name, currentFavorite) {
    runRuleWrite(["set-flag", name, "favorite", currentFavorite ? "false" : "true"])
  }

  function toggleDeviceHidden(name, currentHidden) {
    runRuleWrite(["set-flag", name, "hidden", currentHidden ? "false" : "true"])
  }

  function deleteAppRule(appKey, direction) {
    runRuleWrite(["del-app", appKey, direction])
  }

  function changeAppRuleTarget(appKey, direction, targetName) {
    if (targetName === "") runRuleWrite(["del-app", appKey, direction])
    else runRuleWrite(["set-app", appKey, direction, targetName])
  }

  PwObjectTracker { objects: root.outputDevice ? [root.outputDevice] : [] }
  PwObjectTracker { objects: root.inputDevice ? [root.inputDevice] : [] }

  AudioMicrophoneTestController {
    id: microphoneTest
    scriptPath: runtime.script("audio-microphone-test")
    inputDevice: root.inputDevice
    sessionActive: window.visible
  }

  Process {
    id: profilesProc
    command: [runtime.script("audio-profiles")]
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
    command: [runtime.script("audio-ports")]
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
            runtime.script("audio-preferences"),
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

  Timer {
    id: profileRefreshTimer
    interval: 200
    repeat: false
    onTriggered: if (window.visible && !profilesProc.running) profilesProc.running = true
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
        blocked: root.profileMenuOpen || root.aliasEditingDevice !== ""
          onMoveRequested: function(dx, dy) {
            root.keyboardScrolling = true
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
        onTabRequested: function(direction) {
          root.keyboardScrolling = true
          root.switchTab(direction)
        }
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
                { value: "policy", label: "Policy", icon: "󰒃" },
                { value: "scenes", label: "Scenes", icon: "󰌨" },
                { value: "routing", label: "Routing", icon: "󰘮" }
              ]
              value: root.activeTab === 0 ? "devices"
                : root.activeTab === 1 ? "bluetooth"
                : root.activeTab === 2 ? "policy"
                : root.activeTab === 3 ? "scenes" : "routing"
              focusable: false
              foreground: root.foreground
              background: root.background
              fontFamily: root.fontFamily
              onChanged: function(value) {
                root.selectTab(value === "bluetooth" ? 1
                  : value === "policy" ? 2
                  : value === "scenes" ? 3
                  : value === "routing" ? 4 : 0)
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

                  AudioPortRow {
                    id: audioPortDelegate
                    required property var modelData
                    required property int index
                    width: parent.width
                    port: modelData
                    rowIndex: root.audioPortStartIndex + index
                    hasCursor: root.cursorActive && root.activeTab === 0
                      && root.selectedIndex === audioPortDelegate.rowIndex
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(audioPortDelegate)
                    foreground: root.foreground
                    fill: root.hoverFill
                    fontFamily: root.fontFamily
                    menuEnabled: !root.audioMutationBusy
                    onCursorRequested: root.setCursor(audioPortDelegate.rowIndex)
                    onPortSelected: function(value) { root.setAudioPort(audioPortDelegate.port, value) }
                    onMenuToggled: function(open) {
                      root.profileMenuOpen = open
                      if (!open) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                    }
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

                AudioBluetoothPreferenceRow {
                  id: bluetoothPreferenceRow
                  width: parent.width
                  hasCursor: root.cursorActive && root.selectedIndex === 1
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(bluetoothPreferenceRow)
                  foreground: root.foreground
                  fill: root.hoverFill
                  fontFamily: root.fontFamily
                  preference: root.bluetoothProfilePreference
                  menuEnabled: root.bluetoothProfilePreferenceLoaded && !bluetoothPreferenceProc.running
                  onCursorRequested: root.setCursor(1)
                  onPreferenceSelected: function(value) { root.setBluetoothProfilePreference(value) }
                  onMenuToggled: function(open) {
                    root.profileMenuOpen = open
                    if (!open) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
                      busy: policy.busy && root.pendingPolicyKey === modelData.key
                      enabled: root.policySettingsLoaded && !policy.busy
                      opacity: enabled ? 1 : 0.6
                      hasCursor: root.cursorActive && root.activeTab === 2
                        && root.selectedIndex === index
                      foreground: root.foreground
                      fill: root.hoverFill
                      fontFamily: root.fontFamily
                      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(policyCoreRow)
                      onHovered: root.setCursor(index)
                      onActivated: policy.setSetting(modelData.key, !checked)
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
                      enabled: root.policySettingsLoaded && !policy.busy
                      opacity: enabled ? 1 : 0.6
                      hasCursor: root.cursorActive && root.activeTab === 2
                        && root.selectedIndex === rowIndex
                      foreground: root.foreground
                      fill: root.hoverFill
                      fontFamily: root.fontFamily
                      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(policyVolumeRow)
                      onHovered: root.setCursor(rowIndex)
                      onCommitted: function(value) { policy.setSetting(modelData.key, value) }
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
                      busy: policy.busy && root.pendingPolicyKey === modelData.key
                      enabled: root.policySettingsLoaded && !policy.busy
                      opacity: enabled ? 1 : 0.6
                      hasCursor: root.cursorActive && root.activeTab === 2
                        && root.selectedIndex === rowIndex
                      foreground: root.foreground
                      fill: root.hoverFill
                      fontFamily: root.fontFamily
                      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(policyExperimentalRow)
                      onHovered: root.setCursor(rowIndex)
                      onActivated: policy.setSetting(modelData.key, !checked)
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
                visible: root.activeTab === 3
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width
                  text: "Scenes snapshot defaults, device volume, mute, balance, ports, and card profiles so you can restore the whole setup at once."
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                CursorSurface {
                  id: sceneSaveRow
                  width: parent.width
                  implicitHeight: sceneSaveContent.implicitHeight + Style.space(18)
                  enabled: !sceneController.busy && !sceneStoreProc.running
                  hasCursor: root.cursorActive && root.activeTab === 3 && root.selectedIndex === 0
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sceneSaveRow)
                  foreground: root.foreground
                  fill: root.hoverFill
                  bordered: true

                  // Declared beneath the content so the save button stays
                  // clickable; clicks landing anywhere else still save.
                  MouseArea {
                    anchors.fill: parent
                    enabled: !sceneController.busy && !sceneStoreProc.running
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onContainsMouseChanged: if (containsMouse) root.setCursor(0)
                    onClicked: root.saveCurrentScene()
                  }

                  Row {
                    id: sceneSaveContent
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    spacing: Style.space(10)

                    Column {
                      width: parent.width - sceneSaveAction.width - parent.spacing
                      spacing: Style.space(3)

                      Text {
                        width: parent.width
                        text: "Save current state as a new scene"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: sceneController.busy || sceneStoreProc.running
                          ? "Capturing the current audio state…"
                          : "Captures every connected device with its current settings."
                        color: Qt.darker(root.foreground, 1.35)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    PanelActionButton {
                      id: sceneSaveAction
                      iconText: "󰆓"
                      tooltipText: "Save current state as a new scene"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      bordered: true
                      enabled: sceneSaveRow.enabled
                      onClicked: root.saveCurrentScene()
                    }
                  }
                }

                Repeater {
                  model: root.audioScenes

                  AudioSceneRow {
                    id: sceneListRow
                    required property var modelData
                    required property int index
                    width: parent.width
                    sceneName: modelData ? String(modelData.name || "") : ""
                    summary: Model.sceneSummary(modelData)
                    actionEnabled: !sceneController.busy && !sceneStoreProc.running
                    hasCursor: root.cursorActive && root.activeTab === 3
                      && root.selectedIndex === 1 + sceneListRow.index
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sceneListRow)
                    foreground: root.foreground
                    fill: root.hoverFill
                    urgent: root.urgent
                    fontFamily: root.fontFamily
                    onHovered: root.setCursor(1 + sceneListRow.index)
                    onActivated: root.applySceneAt(sceneListRow.index)
                    onDeleted: root.deleteSceneAt(sceneListRow.index)
                  }
                }

                Text {
                  visible: root.scenesLoaded && root.audioScenes.length === 0
                  width: parent.width
                  text: "No scenes saved yet. Capture the current setup to restore it later from here or from the quick mixer."
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: root.sceneStatus !== ""
                  width: parent.width
                  text: root.sceneStatus
                  color: root.sceneStatusIsError ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }

              Column {
                visible: root.activeTab === 4
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width
                  text: "Pin an application to a device and it is routed there every time it starts, whenever the device is present. Rules keep working while the application or device is offline."
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                CursorSurface {
                  id: newRuleAppRow
                  width: parent.width
                  implicitHeight: Math.max(newAppLabels.implicitHeight, newAppDropdown.implicitHeight) + Style.space(18)
                  hasCursor: root.cursorActive && root.activeTab === 4 && root.selectedIndex === 0
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(newRuleAppRow)
                  foreground: root.foreground
                  fill: root.hoverFill
                  bordered: true

                  function toggleAppMenu() { if (newAppDropdown.enabled) newAppDropdown.toggle() }
                  function closeAppMenu() { newAppDropdown.close() }

                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    spacing: Style.space(16)

                    Column {
                      id: newAppLabels
                      width: Math.max(Style.space(180), parent.width * 0.4)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(3)

                      Text {
                        width: parent.width
                        text: "Pin application"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: root.newRuleApp !== "" ? root.newRuleApp : "Pick a running application"
                        color: Qt.darker(root.foreground, 1.35)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    AudioDropdown {
                      id: newAppDropdown
                      width: parent.width - newAppLabels.width - parent.spacing
                      showLabel: false
                      popupDirection: "down"
                      value: root.newRuleApp
                      options: {
                        var arr = []
                        for (var i = 0; i < root.newRuleAppOptions.length; i++)
                          arr.push({ value: root.newRuleAppOptions[i], label: root.newRuleAppOptions[i] })
                        return arr
                      }
                      hasCursor: newRuleAppRow.hasCursor
                      enabled: root.newRuleAppOptions.length > 0
                      opacity: enabled ? 1 : 0.6
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      anchors.verticalCenter: parent.verticalCenter

                      onHovered: function(on) { if (on) root.setCursor(0) }
                      onChanged: function(value) { root.newRuleApp = value }
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
                    onContainsMouseChanged: if (containsMouse) root.setCursor(0)
                  }
                }

                CursorSurface {
                  id: newRuleDeviceRow
                  width: parent.width
                  implicitHeight: Math.max(newDeviceLabels.implicitHeight, newDeviceDropdown.implicitHeight) + Style.space(18)
                  hasCursor: root.cursorActive && root.activeTab === 4 && root.selectedIndex === 1
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(newRuleDeviceRow)
                  foreground: root.foreground
                  fill: root.hoverFill
                  bordered: true

                  function toggleDeviceMenu() { if (newDeviceDropdown.enabled) newDeviceDropdown.toggle() }
                  function closeDeviceMenu() { newDeviceDropdown.close() }

                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(12)
                    anchors.rightMargin: Style.space(12)
                    spacing: Style.space(16)

                    Column {
                      id: newDeviceLabels
                      width: Math.max(Style.space(180), parent.width * 0.4)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(3)

                      Text {
                        width: parent.width
                        text: "Route it to"
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        text: "Outputs pin playback, inputs pin recording."
                        color: Qt.darker(root.foreground, 1.35)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }

                    AudioDropdown {
                      id: newDeviceDropdown
                      width: parent.width - newDeviceLabels.width - parent.spacing
                      showLabel: false
                      popupDirection: "down"
                      value: ""
                      options: rulesStore.targetOptions
                      hasCursor: newRuleDeviceRow.hasCursor
                      enabled: root.newRuleApp !== ""
                      opacity: enabled ? 1 : 0.6
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      anchors.verticalCenter: parent.verticalCenter

                      onHovered: function(on) { if (on) root.setCursor(1) }
                      onChanged: function(value) {
                        if (value === "") return
                        var direction = rulesStore.directionForTarget(value)
                        if (direction === "" || !root.runRuleWrite(
                            ["set-app", root.newRuleApp, direction, value])) return
                        root.showSceneStatus("Pinned '" + root.newRuleApp + "'", false)
                        root.newRuleApp = ""
                      }
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

                Repeater {
                  id: routingRuleRepeater
                  model: root.audioRules.appRules

                  AudioAppRuleRow {
                    id: routingRuleDelegate
                    required property var modelData
                    required property int index
                    width: parent.width
                    appLabel: modelData ? String(modelData.app || "") : ""
                    direction: modelData ? String(modelData.direction || "playback") : "playback"
                    targetLabel: root.ruleDeviceLabel(modelData ? String(modelData.target || "") : "")
                    targetAvailable: root.ruleTargetLive(modelData ? String(modelData.target || "") : "")
                    currentValue: modelData ? String(modelData.target || "") : ""
                    options: routingRuleDelegate.direction === "recording"
                      ? root.recordingRuleTargetOptions(routingRuleDelegate.currentValue)
                      : root.ruleTargetOptions(routingRuleDelegate.currentValue)
                    menuEnabled: !root.routingMutation
                    hasCursor: root.cursorActive && root.activeTab === 4
                      && root.selectedIndex === 2 + routingRuleDelegate.index
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(routingRuleDelegate)
                    foreground: root.foreground
                    fill: root.hoverFill
                    urgent: root.urgent
                    fontFamily: root.fontFamily
                    onCursorRequested: root.setCursor(2 + routingRuleDelegate.index)
                    onMenuToggled: function(open) {
                      root.profileMenuOpen = open
                      if (!open) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                    }
                    onTargetChosen: function(value) {
                      root.changeAppRuleTarget(
                        routingRuleDelegate.modelData.app,
                        routingRuleDelegate.modelData.direction,
                        value)
                    }
                    onDeleted: root.deleteAppRule(
                      routingRuleDelegate.modelData.app,
                      routingRuleDelegate.modelData.direction)
                  }
                }

                PanelSectionHeader {
                  text: "MANAGE DEVICES"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  width: parent.width
                  text: "Give a device a custom name, favorite it to sort it first, or hide it everywhere."
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: root.managedDevices

                  AudioDevicePrefRow {
                    id: managedDeviceDelegate
                    required property var modelData
                    required property int index
                    width: parent.width
                    deviceName: modelData ? String(modelData.name || "") : ""
                    title: modelData ? String(modelData.title || "") : ""
                    favorite: modelData ? modelData.favorite === true : false
                    hidden: modelData ? modelData.hidden === true : false
                    editingAlias: root.aliasEditingDevice === managedDeviceDelegate.deviceName
                      && managedDeviceDelegate.deviceName !== ""
                    aliasValue: {
                      var alias = root.deviceAliasFor(managedDeviceDelegate.deviceName)
                      return alias !== "" ? alias : managedDeviceDelegate.title
                    }
                    busy: root.routingMutation
                    hasCursor: root.cursorActive && root.activeTab === 4
                      && root.selectedIndex === 2 + root.audioRules.appRules.length + managedDeviceDelegate.index
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(managedDeviceDelegate)
                    foreground: root.foreground
                    fill: root.hoverFill
                    urgent: root.urgent
                    fontFamily: root.fontFamily
                    onCursorRequested: root.setCursor(
                      2 + root.audioRules.appRules.length + managedDeviceDelegate.index)
                    onAliasEditStarted: root.aliasEditingDevice = managedDeviceDelegate.deviceName
                    onAliasCommitted: function(text) {
                      root.commitAliasEdit(managedDeviceDelegate.deviceName, text)
                    }
                    onAliasCancelled: root.cancelAliasEdit()
                    onFavoriteToggled: root.toggleDeviceFavorite(
                      managedDeviceDelegate.deviceName, managedDeviceDelegate.favorite)
                    onHiddenToggled: root.toggleDeviceHidden(
                      managedDeviceDelegate.deviceName, managedDeviceDelegate.hidden)
                  }
                }

                Text {
                  visible: root.sceneStatus !== ""
                  width: parent.width
                  text: root.sceneStatus
                  color: root.sceneStatusIsError ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
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

                    AudioProfileRow {
                      id: bluetoothProfileDelegate
                      required property var modelData
                      required property int index
                      width: parent.width
                      card: modelData
                      rowIndex: 2 + index
                      hasCursor: root.cursorActive
                        && root.selectedIndex === bluetoothProfileDelegate.rowIndex
                      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(bluetoothProfileDelegate)
                      foreground: root.foreground
                      fill: root.hoverFill
                      fontFamily: root.fontFamily
                      currentProfile: root.selectedAudioProfile(bluetoothProfileDelegate.card)
                      options: root.profileOptions(bluetoothProfileDelegate.card)
                      menuEnabled: !root.audioMutationBusy
                      onCursorRequested: root.setCursor(bluetoothProfileDelegate.rowIndex)
                      onProfileSelected: function(profile) {
                        root.setAudioProfile(bluetoothProfileDelegate.card, profile)
                      }
                      onMenuToggled: function(open) {
                        root.profileMenuOpen = open
                        if (!open) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
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

                    AudioProfileRow {
                      id: deviceProfileDelegate
                      required property var modelData
                      required property int index
                      width: parent.width
                      card: modelData
                      rowIndex: root.deviceProfileStartIndex + index
                      hasCursor: root.cursorActive
                        && root.selectedIndex === deviceProfileDelegate.rowIndex
                      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(deviceProfileDelegate)
                      foreground: root.foreground
                      fill: root.hoverFill
                      fontFamily: root.fontFamily
                      currentProfile: root.selectedAudioProfile(deviceProfileDelegate.card)
                      options: root.profileOptions(deviceProfileDelegate.card)
                      menuEnabled: !root.audioMutationBusy
                      onCursorRequested: root.setCursor(deviceProfileDelegate.rowIndex)
                      onProfileSelected: function(profile) {
                        root.setAudioProfile(deviceProfileDelegate.card, profile)
                      }
                      onMenuToggled: function(open) {
                        root.profileMenuOpen = open
                        if (!open) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
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

                  AudioBalanceRow {
                    id: outputBalanceRow
                    visible: root.outputBalanceAvailable
                    node: root.outputDevice
                    label: "Output"
                    rowIndex: root.outputBalanceIndex
                    deviceLabel: root.nodeLabel(root.outputDevice)
                    balanceValue: root.balanceFor(root.outputDevice)
                    foreground: root.foreground
                    fill: root.hoverFill
                    fontFamily: root.fontFamily
                    hasCursor: root.cursorActive && root.activeTab === 0
                      && root.selectedIndex === root.outputBalanceIndex
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(outputBalanceRow)
                    onCursorRequested: root.setCursor(outputBalanceRow.rowIndex)
                    onBalanceMoved: function(value) { root.setBalance(root.outputDevice, value) }
                  }

                  AudioBalanceRow {
                    id: inputBalanceRow
                    visible: root.inputBalanceAvailable
                    node: root.inputDevice
                    label: "Input"
                    rowIndex: root.inputBalanceIndex
                    deviceLabel: root.nodeLabel(root.inputDevice)
                    balanceValue: root.balanceFor(root.inputDevice)
                    foreground: root.foreground
                    fill: root.hoverFill
                    fontFamily: root.fontFamily
                    hasCursor: root.cursorActive && root.activeTab === 0
                      && root.selectedIndex === root.inputBalanceIndex
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(inputBalanceRow)
                    onCursorRequested: root.setCursor(inputBalanceRow.rowIndex)
                    onBalanceMoved: function(value) { root.setBalance(root.inputDevice, value) }
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
                    state: microphoneTest.testState
                    secondsRemaining: microphoneTest.secondsRemaining
                    level: microphoneTest.level
                    microphoneMuted: root.inputDeviceMuted
                    error: microphoneTest.error
                    enabled: !profileSetProc.running && !portSetProc.running
                    hasCursor: root.cursorActive && root.activeTab === 0
                      && root.selectedIndex === root.microphoneTestIndex
                    foreground: root.foreground
                    fill: root.hoverFill
                    urgent: root.urgent
                    fontFamily: root.fontFamily
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(microphoneTestRow)
                    onHovered: root.setCursor(root.microphoneTestIndex)
                    onPrimaryActivated: microphoneTest.activate()
                    onDiscarded: microphoneTest.discard()
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
}
