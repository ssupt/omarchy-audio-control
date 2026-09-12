import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "../core/Model.js" as Model
import "../components"
import "../core"
import "../devices"
import "../diagnostics"
import "../microphone"
import "../policy"
import "../routing"
import "../scenes"

// Audio configuration belongs in a regular centered window rather than the
// compact bar popout. The quick panel and Setup > Audio both summon this same
// surface, while the shell host owns its lifetime like any other panel plugin.
Item {
  id: root

  AudioRuntime { id: runtime }
  AudioPolicyController {
    service: root.service
    id: policy
    onSettled: root.clampCursor()
  }
  AudioRulesController {
    service: root.service
    id: rulesStore
    nodes: root.pipewireNodes
    onRulesChanged: root.clampCursor()
    onWriteFinished: function(success) {
      if (!success) root.showRoutingStatus(rulesStore.error, true)
    }
  }
  AudioOutputGroupsController {
    service: root.service
    id: outputGroupController
    scriptPath: runtime.script("audio-output-groups")
    onOperationFinished: function(action, _groupId, success, exitCode) {
      if (success) {
        if (action === "create") {
          root.newOutputGroupName = ""
          root.newOutputGroupMembers = []
          root.showOutputGroupStatus("Created output group", false)
        } else if (action === "update") {
          root.showOutputGroupStatus("Updated output group", false)
        } else if (action === "delete") {
          root.showOutputGroupStatus("Deleted output group", false)
        }
      } else if (action !== "reconcile") {
        root.showOutputGroupStatus(exitCode === 3
          ? "Switch away from the group and make sure every selected output is connected"
          : outputGroupController.error, true)
      }
      root.clampCursor()
    }
  }
  AudioDiagnosticsController {
    id: diagnostics
    service: root.service
    diagnosticsPath: runtime.script("audio-diagnostics")
    speakerTestPath: runtime.script("audio-speaker-test")
    recoveryPath: runtime.script("audio-recovery")
    sessionActive: window.visible && root.activeTab === 5 && !root.recoveryConfirmOpen
    mutationBlocked: root.graphMutationBusy
  }

  property var shell: null
  property var manifest: null
  property var service: null
  readonly property string catalogRevision: service && service.ready
    ? String(service.state.catalogRevision || "") : ""
  onCatalogRevisionChanged: catalogRefresh.restart()
  Timer {
    id: catalogRefresh
    interval: 200
    onTriggered: {
      if (!window.visible) return
      if (root.profileMenuOpen) { restart(); return }
      root.resolveVolumeSink()
    }
  }
  property bool closingFromHost: false
  property bool openRequested: false
  property bool quickPanelProxyOpen: false
  property bool windowRuleReady: false
  property bool recoveryConfirmOpen: false
  readonly property bool opened: window.visible

  property var audioCards: []
  property var audioPorts: []
  readonly property bool profilesLoaded: !!service && service.ready && service.state.catalogReady === true
  readonly property bool bluetoothAutoSwitch: policy.settings["bluetooth.autoswitch-to-headset-profile"] === true
  readonly property bool bluetoothAutoSwitchLoaded: policy.loaded && Model.hasOwn(policy.settings, "bluetooth.autoswitch-to-headset-profile")
  readonly property string bluetoothProfilePreference: policy.settings["bluetooth.profile-preference"] || "quality"
  readonly property bool bluetoothProfilePreferenceLoaded: policy.loaded && Model.hasOwn(policy.settings, "bluetooth.profile-preference")
  readonly property var audioScenes: service && service.stores.scenes ? service.stores.scenes.scenes : []
  readonly property bool scenesLoaded: !!service && service.ready && !!service.stores.scenes
  readonly property bool settingsLoaded: !!service && service.ready && !!service.stores.settings
  readonly property bool preferencesLoaded: !!service && service.ready && !!service.stores.preferences
  readonly property var audioRules: rulesStore.rules
  property string newRuleApp: ""
  property string newOutputGroupName: ""
  property var newOutputGroupMembers: []
  property string aliasEditingDevice: ""
  readonly property bool routingMutation: rulesStore.busy || outputGroupController.busy
  readonly property bool diagnosticsMutationBusy: diagnostics.speakerTesting
    || diagnostics.recovering
  readonly property bool graphMutationBusy: !service || !service.ready || service.transactionBusy || sceneController.busy
    || profileSetProc.running || portSetPending || microphoneTest.busy || policy.busy
  readonly property bool sceneMutationBusy: graphMutationBusy
    || sceneWritePending
    || diagnosticsMutationBusy
  property bool sceneWritePending: false
  property string sceneStatus: ""
  property bool sceneStatusIsError: false
  property string outputGroupStatus: ""
  property bool outputGroupStatusIsError: false
  property string routingStatus: ""
  property bool routingStatusIsError: false
  property string profileSetError: ""
  property string portSetError: ""
  property bool portSetPending: false
  property string settingsSaveError: ""
  readonly property string settingsFormatError: service && service.storeErrors.settings ? service.storeErrors.settings.message : ""
  readonly property bool audioControlSettingsWritable: !!service && service.ready && !service.storeErrors.settings
  property bool audioControlWritePending: false
  readonly property var policySettings: policy.settings
  readonly property bool policySettingsLoaded: policy.loaded
  readonly property string pendingPolicyKey: policy.pendingKey
  readonly property string policyError: policy.error
  readonly property string error: {
    var errors = activeTab === 0
      ? [profileSetError, portSetError, settingsSaveError, settingsFormatError]
      : (activeTab === 1
        ? [profileSetError, policyError]
        : (activeTab === 2
          ? [settingsSaveError, settingsFormatError, policyError] : []))
    for (var i = 0; i < errors.length; i++) if (errors[i] !== "") return errors[i]
    return ""
  }
  // 0 = devices, 1 = Bluetooth, 2 = policy, 3 = scenes, 4 = routing,
  // 5 = diagnostics
  property int activeTab: 0
  // Defer list delegates until their tab is first used, then retain them so
  // returning to a tab preserves its controls and any in-progress interaction.
  property int visitedTabs: 1
  onActiveTabChanged: visitedTabs |= (1 << activeTab)
  property bool cursorActive: false
  property int selectedIndex: 0
  property int profileMenuCount: 0
  readonly property bool profileMenuOpen: profileMenuCount > 0
  readonly property var audioPreferences: service && service.stores.preferences ? service.stores.preferences : Model.parseAudioPreferences("")

  readonly property bool outputOverdrive: !!service && !!service.stores.settings && service.stores.settings.outputOverdrive === true
  readonly property bool captureNotifications: !service || !service.stores.settings || service.stores.settings.captureNotifications !== false

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
  property bool volumeSinkResolvePending: false
  readonly property var outputDevice: {
    try {
      if (!defaultOutputDevice || !volumeSinkName
          || Model.nodeName(defaultOutputDevice) === volumeSinkName) return defaultOutputDevice
      var match = null
      for (var i = 0; i < pipewireNodes.length && i < 4096; i++) {
        var node = pipewireNodes[i]
        if (!node || !node.isSink || node.isStream
            || Model.nodeName(node) !== volumeSinkName) continue
        if (match) return defaultOutputDevice
        match = node
      }
      return match || defaultOutputDevice
    } catch (_error) {
      return defaultOutputDevice
    }
  }
  readonly property var rawInputDevice: Pipewire.defaultAudioSource
  readonly property var inputDevice: usableInputNode(rawInputDevice)
    && mutableAudioNode(rawInputDevice) ? rawInputDevice : null
  readonly property bool inputDeviceMuted: audioNodeMuted(inputDevice, true)
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
  readonly property int outputGroupCreateIndex: 0
  readonly property int outputGroupStartIndex: 1
  readonly property int newRuleAppIndex: outputGroupStartIndex + audioRules.outputGroups.length
  readonly property int newRuleDeviceIndex: newRuleAppIndex + 1
  readonly property int routingRuleStartIndex: newRuleDeviceIndex + 1
  readonly property int managedDeviceStartIndex: routingRuleStartIndex + audioRules.appRules.length
  readonly property int itemCount: activeTab === 5
    ? diagnosticsView.itemCount
    : (activeTab === 4
      ? managedDeviceStartIndex + managedDevices.length
      : (activeTab === 3
        ? 1 + audioScenes.length
        : (activeTab === 0
          ? deviceItemCount + (inputDevice ? 1 : 0)
          : (activeTab === 1 ? 2 + bluetoothCards.length : policyItemCount))))
  readonly property bool audioMutationBusy: graphMutationBusy || diagnosticsMutationBusy
  onAudioMutationBusyChanged: if (!audioMutationBusy) enforceOutputVolumeLimit()
  onOutputOverdriveChanged: enforceOutputVolumeLimit()
  readonly property bool policyMutationBlocked: sceneController.busy
    || profileSetProc.running || portSetPending || microphoneTest.busy
    || diagnosticsMutationBusy
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  onDefaultOutputDeviceChanged: {
    volumeSinkName = ""
    resolveVolumeSink()
  }
  onOutputDeviceChanged: enforceOutputVolumeLimit()

  function pluginId() {
    var id = manifest && typeof manifest.id === "string" ? String(manifest.id) : ""
    return id !== "" ? id : "ssupt.audio-control"
  }

  function toggleQuickPanel() {
    var hostBar = shell ? shell.bar : null
    if (!hostBar || typeof hostBar.isBarWidgetOpen !== "function"
        || typeof hostBar.summonBarWidget !== "function"
        || typeof hostBar.hideBarWidget !== "function") return false

    var id = pluginId()
    var wasOpen = hostBar.isBarWidgetOpen(id) === true
    var changed = wasOpen ? hostBar.hideBarWidget(id) : hostBar.summonBarWidget(id)
    if (changed !== true) return false
    quickPanelProxyOpen = !wasOpen
    return true
  }

  function open(payloadJson) {
    var request = Model.parseAudioOpenRequest(payloadJson)
    if (!request.advanced && toggleQuickPanel()) return

    quickPanelProxyOpen = false
    activeTab = request.tab
    openRequested = true
    closingFromHost = false
    cursorActive = false
    selectedIndex = 0
    clearErrors()
    recoveryConfirmOpen = false
    microphoneTest.discard()
    cancelAliasEdit()
    if (windowRuleReady) showOnCurrentWorkspace()
    else if (!windowRuleProc.running) windowRuleProc.running = true
  }

  function clearErrors() {
    profileSetError = ""
    portSetError = ""
    settingsSaveError = ""
    sceneStatus = ""
    outputGroupStatus = ""
    routingStatus = ""
    policy.clearError()
  }

  function showOnCurrentWorkspace() {
    if (!openRequested) return
    window.visible = true
    Quickshell.execDetached(runtime.scriptCommand("place-advanced-window"))
    Qt.callLater(function() {
      if (!window.visible) return
      keyCatcher.forceActiveFocus()
      refresh()
    })
  }

  function close() {
    if (quickPanelProxyOpen) {
      var hostBar = shell ? shell.bar : null
      if (hostBar && typeof hostBar.hideBarWidget === "function")
        hostBar.hideBarWidget(pluginId())
      quickPanelProxyOpen = false
    }
    openRequested = false
    closingFromHost = true
    closeProfileMenus()
    profileMenuCount = 0
    recoveryConfirmOpen = false
    microphoneTest.discard()
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    openRequested = false
    closeProfileMenus()
    profileMenuCount = 0
    recoveryConfirmOpen = false
    microphoneTest.discard()
    if (shell && typeof shell.hide === "function") shell.hide("ssupt.audio-control")
    else window.visible = false
  }

  function refresh() {
    if (!window.visible) return
    resolveVolumeSink()
  }

  function resolveVolumeSink() {
    if (volumeSinkProc.running) {
      volumeSinkResolvePending = true
      return
    }
    volumeSinkResolvePending = false
    volumeSinkProc.response = ""
    volumeSinkProc.requestedDefaultName = Model.nodeName(defaultOutputDevice)
    volumeSinkProc.requestedDefaultObjectId = Model.nodeObjectId(defaultOutputDevice)
    volumeSinkProc.running = true
  }

  function mutableAudioNode(node) {
    try {
      if (!node || node.ready !== true || !node.audio
          || pipewireNodes.length > 4096) return false
      var objectId = Model.nodeObjectId(node)
      if (objectId === "") return false
      var match = null
      for (var i = 0; i < pipewireNodes.length; i++) {
        var candidate = pipewireNodes[i]
        if (!candidate || Model.nodeObjectId(candidate) !== objectId) continue
        if (match) return false
        match = candidate
      }
      return match === node
    } catch (_error) {
      return false
    }
  }

  function usableInputNode(node) {
    try {
      return !!node && node.ready === true && !!node.audio
        && node.isStream !== true && node.isSink !== true
        && Model.nodeName(node) !== "" && Model.isAudioSource(node)
        && !Model.isMonitorSource(node)
        && !Model.isInternalAudioNode(Model.nodeName(node), Model.nodeProps(node))
    } catch (_error) {
      return false
    }
  }

  function audioNodeMuted(node, fallback) {
    if (!mutableAudioNode(node)) return fallback === true
    try { return node.audio.muted === true } catch (_error) { return fallback === true }
  }

  function setOutputGroupMemberVolume(node, value) {
    if (audioMutationBusy || routingMutation || !mutableAudioNode(node)) return false
    var requested = Number(value)
    var maximum = outputOverdrive ? 1.5 : 1.0
    if (!isFinite(requested)) return false
    try {
      return !!service && service.changeNode(node, { volume: Math.max(0, Math.min(maximum, requested)) })
    } catch (_error) {
      return false
    }
  }

  function enforceOutputVolumeLimit() {
    if (outputOverdrive || audioMutationBusy || !mutableAudioNode(outputDevice)) return
    try {
      var volume = Number(outputDevice.audio.volume)
      if (isFinite(volume) && volume > 1) service.changeNode(outputDevice, { volume: 1 })
    } catch (_error) { }
  }

  function refreshDeviceCatalog() {
    if (profileMenuOpen) return
    audioCards = service ? service.profiles : []
    audioPorts = service ? service.ports : []
    clampCursor()
  }
  onServiceChanged: refreshDeviceCatalog()
  onProfileMenuOpenChanged: if (!profileMenuOpen) Qt.callLater(refreshDeviceCatalog)
  Connections {
    target: root.service
    function onProfilesChanged() { root.refreshDeviceCatalog() }
    function onPortsChanged() { root.refreshDeviceCatalog() }
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
    if (activeTab !== 2 || policyMutationBlocked) return false
    var index = selectedIndex - policyVolumeStartIndex
    if (index < 0 || index >= availablePolicyVolumes.length) return false
    var definition = availablePolicyVolumes[index]
    setPolicySetting(definition.key,
      Number(Model.mapValue(policySettings, definition.key, 0)) + delta * 0.05)
    return true
  }

  function setPolicySetting(key, value) {
    if (policyMutationBlocked) return
    policy.setSetting(key, value)
  }

  function setOutputOverdrive(enabled) {
    if (audioMutationBusy) return
    setAudioControlSetting("outputOverdrive", enabled)
  }

  function setCaptureNotifications(enabled) {
    setAudioControlSetting("captureNotifications", enabled)
  }

  function setAudioControlSetting(key, value) {
    if (!audioControlSettingsWritable || audioControlWritePending
        || (key !== "outputOverdrive" && key !== "captureNotifications")) return
    if (!service || !service.ready) return
    audioControlWritePending = true
    settingsSaveError = ""
    service.request("settings.set", { key: key, value: value }, function(_result, failure) {
      root.audioControlWritePending = false
      root.settingsSaveError = failure ? failure.message : ""
    })
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
    var name = Model.nodeName(node)
    var alias = name !== "" ? rulesStore.aliasFor(name) : ""
    if (alias !== "") return alias
    return Model.nodeLabel(node)
  }

  function stereoIndices(node) {
    try {
      if (!mutableAudioNode(node) || !node.audio.channels || !node.audio.volumes)
        return { left: -1, right: -1 }
      var channels = node.audio.channels
      var left = -1
      var right = -1
      for (var i = 0; i < channels.length && i < 64; i++) {
        if (channels[i] === PwAudioChannel.FrontLeft) left = i
        else if (channels[i] === PwAudioChannel.FrontRight) right = i
      }
      if ((left < 0 || right < 0) && node.audio.volumes.length === 2)
        return { left: 0, right: 1 }
      return { left: left, right: right }
    } catch (_error) {
      return { left: -1, right: -1 }
    }
  }

  function balanceAvailable(node) {
    var indices = stereoIndices(node)
    return indices.left >= 0 && indices.right >= 0
  }

  function balanceFor(node) {
    try {
      if (!mutableAudioNode(node)) return 0
      var indices = stereoIndices(node)
      if (indices.left < 0 || indices.right < 0) return 0
      return Model.balanceValue(node.audio.volumes[indices.left], node.audio.volumes[indices.right])
    } catch (_error) {
      return 0
    }
  }

  function setBalance(node, value) {
    if (audioMutationBusy || !mutableAudioNode(node)) return false
    var indices = stereoIndices(node)
    if (indices.left < 0 || indices.right < 0) return false
    try {
      return !!service && service.changeNode(node, { balance: value })
    } catch (_error) {
      return false
    }
  }

  function adjustBalanceAtCursor(delta) {
    if (audioMutationBusy) return false
    var node = selectedIndex === outputBalanceIndex ? outputDevice
      : (selectedIndex === inputBalanceIndex ? inputDevice : null)
    if (!node) return false
    return setBalance(node, balanceFor(node) + delta * 0.1)
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
    if (outputGroupCreateRow) outputGroupCreateRow.closeMemberMenu()
    var repeaters = [deviceProfileRepeater, bluetoothProfileRepeater,
      audioPortRepeater, outputGroupRepeater, routingRuleRepeater]
    for (var r = 0; r < repeaters.length; r++) {
      var repeater = repeaters[r]
      if (!repeater) continue
      for (var i = 0; i < repeater.count; i++) {
        var row = repeater.itemAt(i)
        if (!row) continue
        if (typeof row.closeProfileMenu === "function") row.closeProfileMenu()
        if (typeof row.closePortMenu === "function") row.closePortMenu()
        if (typeof row.closeTargetMenu === "function") row.closeTargetMenu()
        if (typeof row.closeMemberMenu === "function") row.closeMemberMenu()
      }
    }
  }

  function updateProfileMenu(open) {
    profileMenuCount = Math.max(0, profileMenuCount + (open ? 1 : -1))
  }

  function selectTab(index) {
    var next = Math.max(0, Math.min(5, index))
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
    selectTab((activeTab + (direction < 0 ? -1 : 1) + 6) % 6)
  }

  function setCursor(index) {
    // Mouse claims never scroll; keyboard navigation sets the flag itself.
    keyboardScrolling = false
    cursorActive = true
    selectedIndex = index
  }

  function activateCursor() {
    if (!cursorActive || itemCount === 0) return
    if (activeTab === 5) {
      diagnosticsView.activate(selectedIndex)
      return
    }
    if (activeTab === 4) {
      if (selectedIndex === outputGroupCreateIndex) outputGroupCreateRow.activate()
      else if (selectedIndex < newRuleAppIndex) {
        var groupRow = outputGroupRepeater.itemAt(selectedIndex - outputGroupStartIndex)
        if (groupRow) groupRow.toggleMemberMenu()
      } else if (selectedIndex === newRuleAppIndex) newRuleAppRow.toggleAppMenu()
      else if (selectedIndex === newRuleDeviceIndex) newRuleDeviceRow.toggleDeviceMenu()
      else if (selectedIndex < managedDeviceStartIndex) {
        var ruleRow = routingRuleRepeater.itemAt(selectedIndex - routingRuleStartIndex)
        if (ruleRow) ruleRow.toggleTargetMenu()
      } else {
        var deviceIndex = selectedIndex - managedDeviceStartIndex
        if (deviceIndex >= 0 && deviceIndex < managedDevices.length) {
          var managed = managedDevices[deviceIndex]
          if (managed) toggleDeviceFavorite(managed.name, managed.favorite)
        }
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
        setPolicySetting(policyToggle.key,
          Model.mapValue(policySettings, policyToggle.key, false) !== true)
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
      if (profileSetProc.running || portSetPending || sceneController.busy
          || policy.busy || diagnosticsMutationBusy) return
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

  function requestRecovery() {
    if (graphMutationBusy || diagnostics.busy
        || !diagnostics.snapshot.capabilities.recovery) return
    recoveryConfirm.selectedIndex = 1
    recoveryConfirmOpen = true
  }

  function cancelRecovery() {
    recoveryConfirmOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function confirmRecovery() {
    diagnostics.runRecovery()
    recoveryConfirmOpen = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
    profileSetProc.command = runtime.scriptCommand(
      "audio-profile-set", [String(card.name), profile])
    profileSetProc.running = true
  }

  function setAudioPort(port, value) {
    if (!port || !port.identity || !value || !service || audioMutationBusy) return
    portSetError = ""
    portSetPending = true
    service.request("port.set", { identity: port.identity, port: value }, function(_result, failure) {
      root.portSetPending = false
      root.portSetError = failure ? failure.message : ""
    }, { timeout: 15000 })
  }

  function setBluetoothAutoSwitch(enabled) {
    policy.setSetting("bluetooth.autoswitch-to-headset-profile", enabled)
  }

  function setBluetoothProfilePreference(value) {
    policy.setSetting("bluetooth.profile-preference", value)
  }

  Process {
    id: windowRuleProc
    command: runtime.scriptCommand("prepare-advanced-window")
    onExited: function(_exitCode) {
      // The placement helper below remains a fallback if Hyprland rejected
      // the pre-map rule. Do not leave the settings inaccessible on another
      // compositor merely because it has no Hyprland rule API.
      root.windowRuleReady = true
      root.showOnCurrentWorkspace()
    }
  }

  function runRuleWrite(args) {
    routingStatus = ""
    return rulesStore.write(args)
  }

  AudioSceneController {
    id: sceneController
    service: root.service
    onCaptureFailed: function(error) { root.showSceneStatus(error, true) }
    onCaptureFinished: function(scene) {
      root.sceneWritePending = true
      root.service.request("scenes.save", { name: scene.name, scene: scene }, function(_result, error) {
        root.sceneWritePending = false
        root.showSceneStatus((error ? "Could not save" : "Saved") + " scene '" + scene.name + "'", !!error)
      })
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

  Timer {
    id: outputGroupStatusTimer
    interval: 6000
    onTriggered: root.outputGroupStatus = ""
  }

  function showOutputGroupStatus(text, isError) {
    outputGroupStatus = text
    outputGroupStatusIsError = isError
    outputGroupStatusTimer.restart()
  }

  Timer {
    id: routingStatusTimer
    interval: 6000
    onTriggered: root.routingStatus = ""
  }

  function showRoutingStatus(text, isError) {
    routingStatus = text
    routingStatusIsError = isError
    routingStatusTimer.restart()
  }

  function nextSceneName() {
    var used = []
    for (var i = 0; i < audioScenes.length; i++) used.push(audioScenes[i].name)
    for (var n = 1; n < 100; n++)
      if (used.indexOf("Scene " + n) === -1) return "Scene " + n
    return "Scene " + Math.floor(Math.random() * 100000)
  }

  function saveCurrentScene() {
    if (sceneMutationBusy) return
    sceneStatus = ""
    sceneController.capture(nextSceneName())
  }

  function applySceneAt(index) {
    var scene = index >= 0 ? audioScenes[index] : null
    if (!scene || sceneMutationBusy) return
    sceneStatus = ""
    sceneController.apply(scene)
  }

  function deleteSceneAt(index) {
    var scene = index >= 0 ? audioScenes[index] : null
    if (!scene || sceneMutationBusy) return
    sceneStatus = ""
    sceneWritePending = true
    service.request("scenes.delete", { name: scene.name }, function(_result, error) {
      root.sceneWritePending = false
      if (error) root.showSceneStatus("Could not delete the scene", true)
    })
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

  readonly property var outputGroups: rulesStore.outputGroups
  readonly property var outputGroupMemberOptions: rulesStore.outputGroupMemberOptions
  readonly property var managedDevices: rulesStore.managedDevices
  readonly property var newRuleAppOptions: rulesStore.availableApplicationLabels

  function createOutputGroup() {
    var name = String(newOutputGroupName || "").trim()
    var members = Model.listSnapshot(newOutputGroupMembers)
    if (name === "" || members.length < 2 || routingMutation) return
    outputGroupStatus = ""
    if (!outputGroupController.createGroup(name, members))
      showOutputGroupStatus("Another routing change is still finishing", true)
  }

  function updateOutputGroup(group, members) {
    if (!group || routingMutation) return
    var next = Model.listSnapshot(members)
    if (next.length < 2) {
      showOutputGroupStatus("An output group needs at least two devices", true)
      return
    }
    outputGroupStatus = ""
    if (!outputGroupController.updateGroup(group.id, group.name, next))
      showOutputGroupStatus("Another routing change is still finishing", true)
  }

  function deleteOutputGroup(group) {
    if (!group || routingMutation) return
    outputGroupStatus = ""
    if (!outputGroupController.deleteGroup(group.id))
      showOutputGroupStatus("Another routing change is still finishing", true)
  }

  onManagedDevicesChanged: {
    if (aliasEditingDevice === "") return
    for (var i = 0; i < managedDevices.length; i++)
      if (managedDevices[i].name === aliasEditingDevice) return
    cancelAliasEdit()
  }

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
    var trimmed = String(text || "").trim()
    if (runRuleWrite(["set-alias", name, trimmed])) cancelAliasEdit()
    else showRoutingStatus("Another routing change is still finishing", true)
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
    service: root.service
    inputDevice: root.inputDevice
    inputDeviceLive: root.mutableAudioNode(root.inputDevice)
    sessionActive: window.visible
  }

  AudioCommand {
    service: root.service
    id: volumeSinkProc
    property string response: ""
    property string requestedDefaultName: ""
    property string requestedDefaultObjectId: ""
    command: runtime.scriptCommand("audio-resolve-output-sink")
    stdout: AudioReply {
      waitForEnd: true
      onStreamFinished: volumeSinkProc.response = String(text || "").trim()
    }
    onExited: function(exitCode) {
      var resolved = Model.sanitizeIdentifier(response, 160)
      var currentDefaultName = Model.nodeName(root.defaultOutputDevice)
      var currentDefaultObjectId = Model.nodeObjectId(root.defaultOutputDevice)
      var requestStillCurrent = requestedDefaultName === currentDefaultName
        && requestedDefaultObjectId === currentDefaultObjectId
      var retry = root.volumeSinkResolvePending || !requestStillCurrent
      if (requestStillCurrent)
        root.volumeSinkName = exitCode === 0 && resolved !== "" ? resolved : ""
      response = ""
      requestedDefaultName = ""
      requestedDefaultObjectId = ""
      root.volumeSinkResolvePending = false
      if (retry) Qt.callLater(root.resolveVolumeSink)
    }
  }

  AudioCommand {
    service: root.service
    id: profileSetProc
    onExited: function(exitCode) {
      root.profileSetError = exitCode === 0 ? ""
        : (exitCode === 2
          ? "Audio profile changed, but its shared preference could not be saved"
          : (exitCode === 4
            ? "Audio profile changed, but endpoint volume or mute state was only partially restored"
            : (exitCode === 3 ? "That audio profile is no longer available"
              : "Could not change the audio profile")))
    }
  }

  FloatingWindow {
    id: window
    title: "Advanced Audio Control"
    visible: false
    color: root.background
    implicitWidth: 680
    implicitHeight: 560
    minimumSize: Qt.size(640, 440)

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
            if (root.recoveryConfirmOpen) {
              if (dx !== 0) recoveryConfirm.selectedIndex = recoveryConfirm.selectedIndex === 0 ? 1 : 0
              return
            }
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
          if (root.recoveryConfirmOpen) {
            recoveryConfirm.selectedIndex = recoveryConfirm.selectedIndex === 0 ? 1 : 0
            return
          }
          root.keyboardScrolling = true
          root.switchTab(direction)
        }
        onActivateRequested: {
          if (root.recoveryConfirmOpen) {
            if (recoveryConfirm.selectedIndex === 0) root.cancelRecovery()
            else root.confirmRecovery()
          } else root.activateCursor()
        }
        onCloseRequested: {
          if (root.recoveryConfirmOpen) root.cancelRecovery()
          else root.requestClose()
        }

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
                  text: "Configure devices, automation, safety, and live audio diagnostics."
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
                { value: "routing", label: "Routing", icon: "󰘮" },
                { value: "diagnostics", label: "Diagnostics", icon: "󰒓" }
              ]
              value: root.activeTab === 0 ? "devices"
                : root.activeTab === 1 ? "bluetooth"
                : root.activeTab === 2 ? "policy"
                : root.activeTab === 3 ? "scenes"
                : root.activeTab === 4 ? "routing" : "diagnostics"
              focusable: false
              foreground: root.foreground
              background: root.background
              fontFamily: root.fontFamily
              onChanged: function(value) {
                root.selectTab(value === "bluetooth" ? 1
                  : value === "policy" ? 2
                  : value === "scenes" ? 3
                  : value === "routing" ? 4
                  : value === "diagnostics" ? 5 : 0)
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
                        text: "Extend device and application output volume from 100% to 150%."
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
                    enabled: root.audioControlSettingsWritable
                      && !root.audioControlWritePending && !root.audioMutationBusy
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
                  model: (root.visitedTabs & 1) ? root.audioPorts : []

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
                      root.updateProfileMenu(open)
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
                      busy: policy.busy
                      interactive: false
                      cursorRing: false
                      foreground: root.foreground
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    enabled: root.bluetoothAutoSwitchLoaded
                      && !policy.busy
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
                  menuEnabled: root.bluetoothProfilePreferenceLoaded
                    && !policy.busy
                  onCursorRequested: root.setCursor(1)
                  onPreferenceSelected: function(value) { root.setBluetoothProfilePreference(value) }
                  onMenuToggled: function(open) {
                    root.updateProfileMenu(open)
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
                    model: (root.visitedTabs & 4) ? root.availablePolicyCore : []

                    AudioPolicyToggleRow {
                      id: policyCoreRow
                      required property var modelData
                      required property int index
                      width: parent.width
                      definition: modelData
                      checked: Model.mapValue(root.policySettings, modelData.key, false) === true
                      busy: policy.busy && root.pendingPolicyKey === modelData.key
                      enabled: root.policySettingsLoaded && !policy.busy
                        && !root.policyMutationBlocked
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
                    model: (root.visitedTabs & 4) ? root.availablePolicyVolumes : []

                    AudioPolicyVolumeRow {
                      id: policyVolumeRow
                      required property var modelData
                      required property int index
                      readonly property int rowIndex: root.policyVolumeStartIndex + index
                      width: parent.width
                      definition: modelData
                      value: Number(Model.mapValue(root.policySettings, modelData.key, 0))
                      enabled: root.policySettingsLoaded && !policy.busy
                        && !root.policyMutationBlocked
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
                    model: (root.visitedTabs & 4) ? root.availablePolicyExperimental : []

                    AudioPolicyToggleRow {
                      id: policyExperimentalRow
                      required property var modelData
                      required property int index
                      readonly property int rowIndex: root.policyExperimentalStartIndex + index
                      width: parent.width
                      definition: modelData
                      checked: Model.mapValue(root.policySettings, modelData.key, false) === true
                      busy: policy.busy && root.pendingPolicyKey === modelData.key
                      enabled: root.policySettingsLoaded && !policy.busy
                        && !root.policyMutationBlocked
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
                    enabled: root.audioControlSettingsWritable
                      && !root.audioControlWritePending
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
                  enabled: !root.sceneMutationBusy
                  hasCursor: root.cursorActive && root.activeTab === 3 && root.selectedIndex === 0
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sceneSaveRow)
                  foreground: root.foreground
                  fill: root.hoverFill
                  bordered: true

                  // Declared beneath the content so the save button stays
                  // clickable; clicks landing anywhere else still save.
                  MouseArea {
                    anchors.fill: parent
                    enabled: !root.sceneMutationBusy
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
                        text: root.sceneMutationBusy
                          ? "Updating the audio scene…"
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
                  model: (root.visitedTabs & 8) ? root.audioScenes : []

                  AudioSceneRow {
                    id: sceneListRow
                    required property var modelData
                    required property int index
                    width: parent.width
                    sceneName: modelData ? String(modelData.name || "") : ""
                    summary: Model.sceneSummary(modelData)
                    actionEnabled: !root.sceneMutationBusy
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

                PanelSectionHeader {
                  text: "OUTPUT GROUPS"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Text {
                  width: parent.width
                  text: "Play through two or more connected outputs at once. Groups appear as one destination everywhere else in the mixer. Devices with separate clocks—especially Bluetooth—may drift slightly."
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                AudioOutputGroupCreateRow {
                  id: outputGroupCreateRow
                  width: parent.width
                  groupName: root.newOutputGroupName
                  selectedMembers: root.newOutputGroupMembers
                  options: root.outputGroupMemberOptions
                  busy: root.routingMutation
                  hasCursor: root.cursorActive && root.activeTab === 4
                    && root.selectedIndex === root.outputGroupCreateIndex
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(outputGroupCreateRow)
                  foreground: root.foreground
                  fill: root.hoverFill
                  fontFamily: root.fontFamily
                  onNameEdited: function(value) { root.newOutputGroupName = value }
                  onMembersEdited: function(values) { root.newOutputGroupMembers = values }
                  onCreateRequested: root.createOutputGroup()
                  onCursorRequested: root.setCursor(root.outputGroupCreateIndex)
                  onMenuToggled: function(open) {
                    root.updateProfileMenu(open)
                    if (!open) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                  }
                }

                Repeater {
                  id: outputGroupRepeater
                  model: (root.visitedTabs & 16) ? root.outputGroups : []

                  AudioOutputGroupRow {
                    id: outputGroupDelegate
                    required property var modelData
                    required property int index
                    width: parent.width
                    groupName: modelData ? String(modelData.name || "") : ""
                    groupId: modelData ? String(modelData.id || "") : ""
                    members: modelData && modelData.members ? modelData.members : []
                    memberLevels: rulesStore.outputGroupMemberLevels(modelData)
                    options: rulesStore.memberOptionsFor(modelData)
                    available: rulesStore.outputGroupAvailable(modelData)
                    statusText: rulesStore.outputGroupStatusText(modelData)
                    busy: root.routingMutation
                    memberVolumeBusy: root.audioMutationBusy || root.routingMutation
                    volumeMaximum: root.outputOverdrive ? 1.5 : 1.0
                    hasCursor: root.cursorActive && root.activeTab === 4
                      && root.selectedIndex === root.outputGroupStartIndex
                        + outputGroupDelegate.index
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(outputGroupDelegate)
                    foreground: root.foreground
                    fill: root.hoverFill
                    urgent: root.urgent
                    fontFamily: root.fontFamily
                    onMembersChosen: function(values) {
                      root.updateOutputGroup(outputGroupDelegate.modelData, values)
                    }
                    onMemberVolumeMoved: function(node, value) {
                      root.setOutputGroupMemberVolume(node, value)
                    }
                    onDeleted: root.deleteOutputGroup(outputGroupDelegate.modelData)
                    onCursorRequested: root.setCursor(
                      root.outputGroupStartIndex + outputGroupDelegate.index)
                    onMenuToggled: function(open) {
                      root.updateProfileMenu(open)
                      if (!open) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                    }
                  }
                }

                Text {
                  visible: root.outputGroupStatus !== ""
                    || outputGroupController.error !== ""
                  width: parent.width
                  text: root.outputGroupStatus !== "" ? root.outputGroupStatus
                    : outputGroupController.error
                  color: root.outputGroupStatus !== ""
                    ? (root.outputGroupStatusIsError ? root.urgent : root.foreground)
                    : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                PanelSectionHeader {
                  text: "APPLICATION ROUTING"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

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
                  hasCursor: root.cursorActive && root.activeTab === 4
                    && root.selectedIndex === root.newRuleAppIndex
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

                      onHovered: function(on) { if (on) root.setCursor(root.newRuleAppIndex) }
                      onChanged: function(value) { root.newRuleApp = value }
                      onPopupOpenChanged: {
                        root.updateProfileMenu(popupOpen)
                        if (!popupOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    hoverEnabled: true
                    onContainsMouseChanged: if (containsMouse) root.setCursor(root.newRuleAppIndex)
                  }
                }

                CursorSurface {
                  id: newRuleDeviceRow
                  width: parent.width
                  implicitHeight: Math.max(newDeviceLabels.implicitHeight, newDeviceDropdown.implicitHeight) + Style.space(18)
                  hasCursor: root.cursorActive && root.activeTab === 4
                    && root.selectedIndex === root.newRuleDeviceIndex
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
                      enabled: root.newRuleApp !== "" && !root.routingMutation
                      opacity: enabled ? 1 : 0.6
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      anchors.verticalCenter: parent.verticalCenter

                      onHovered: function(on) { if (on) root.setCursor(root.newRuleDeviceIndex) }
                      onChanged: function(value) {
                        if (value === "") return
                        var direction = rulesStore.directionForTarget(value)
                        if (direction === "" || !root.runRuleWrite(
                            ["set-app", root.newRuleApp, direction, value])) return
                        root.showRoutingStatus("Pinned '" + root.newRuleApp + "'", false)
                        root.newRuleApp = ""
                      }
                      onPopupOpenChanged: {
                        root.updateProfileMenu(popupOpen)
                        if (!popupOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                      }
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.NoButton
                    hoverEnabled: true
                    onContainsMouseChanged: if (containsMouse) root.setCursor(root.newRuleDeviceIndex)
                  }
                }

                Repeater {
                  id: routingRuleRepeater
                  model: (root.visitedTabs & 16) ? root.audioRules.appRules : []

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
                      && root.selectedIndex === root.routingRuleStartIndex
                        + routingRuleDelegate.index
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(routingRuleDelegate)
                    foreground: root.foreground
                    fill: root.hoverFill
                    urgent: root.urgent
                    fontFamily: root.fontFamily
                    onCursorRequested: root.setCursor(
                      root.routingRuleStartIndex + routingRuleDelegate.index)
                    onMenuToggled: function(open) {
                      root.updateProfileMenu(open)
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
                  text: "Give a device a custom name, favorite it to sort it first, or hide it from mixer device lists."
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  model: (root.visitedTabs & 16) ? root.managedDevices : []

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
                      && root.selectedIndex === root.managedDeviceStartIndex
                        + managedDeviceDelegate.index
                    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(managedDeviceDelegate)
                    foreground: root.foreground
                    fill: root.hoverFill
                    urgent: root.urgent
                    fontFamily: root.fontFamily
                    onCursorRequested: root.setCursor(
                      root.managedDeviceStartIndex + managedDeviceDelegate.index)
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
                  visible: root.routingStatus !== "" || rulesStore.error !== ""
                  width: parent.width
                  text: root.routingStatus !== "" ? root.routingStatus : rulesStore.error
                  color: root.routingStatus !== ""
                    ? (root.routingStatusIsError ? root.urgent : root.foreground)
                    : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }
              }

              AudioDiagnosticsView {
                id: diagnosticsView
                visible: root.activeTab === 5
                width: parent.width
                controller: diagnostics
                tabActive: root.activeTab === 5
                cursorActive: root.cursorActive
                selectedIndex: root.selectedIndex
                foreground: root.foreground
                urgent: root.urgent
                fill: root.hoverFill
                fontFamily: root.fontFamily
                onCursorRequested: function(index) { root.setCursor(index) }
                onEnsureVisible: function(item) { root.ensureCursorVisible(item) }
                onRecoveryRequested: root.requestRecovery()
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
                    model: (root.visitedTabs & 2) ? root.bluetoothCards : []

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
                        root.updateProfileMenu(open)
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
                    model: (root.visitedTabs & 1) ? root.deviceCards : []

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
                        root.updateProfileMenu(open)
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
                    enabled: !root.audioMutationBusy
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
                    enabled: !root.audioMutationBusy
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
                    enabled: !profileSetProc.running && !portSetPending
                      && !sceneController.busy && !policy.busy
                      && !root.diagnosticsMutationBusy
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

        ConfirmDialog {
          id: recoveryConfirm
          anchors.fill: parent
          opened: root.recoveryConfirmOpen
          z: 20
          message: "Restart PipeWire and WirePlumber with Omarchy audio recovery? Playback and recording will be interrupted, and a stuck USB device may require authorization to reset."
          confirmText: "Restart audio"
          background: root.background
          foreground: root.foreground
          selectedText: Color.accent
          fontFamily: root.fontFamily
          cornerRadius: Style.cornerRadius
          onCanceled: root.cancelRecovery()
          onConfirmed: root.confirmRecovery()
        }
      }
    }
  }
}
