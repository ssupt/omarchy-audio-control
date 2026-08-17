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
  property string error: ""
  property int activeTab: 0  // 0 = devices, 1 = Bluetooth
  property bool cursorActive: false
  property int selectedIndex: 0
  property bool profileMenuOpen: false
  property var pendingSharedProfile: null
  property var audioPreferences: Model.parseAudioPreferences("")
  property var audioControlSettings: ({ version: 1, outputOverdrive: false })
  property bool outputOverdrive: false

  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: Style.font.family
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
  readonly property bool outputBalanceAvailable: balanceAvailable(outputDevice)
  readonly property bool inputBalanceAvailable: balanceAvailable(inputDevice)
  readonly property int audioPortStartIndex: 1
  readonly property int deviceProfileStartIndex: audioPortStartIndex + audioPorts.length
  readonly property int balanceStartIndex: deviceProfileStartIndex + deviceCards.length
  readonly property int outputBalanceIndex: outputBalanceAvailable ? balanceStartIndex : -1
  readonly property int inputBalanceIndex: inputBalanceAvailable
    ? balanceStartIndex + (outputBalanceAvailable ? 1 : 0) : -1
  readonly property int itemCount: activeTab === 0
    ? balanceStartIndex + (outputBalanceAvailable ? 1 : 0) + (inputBalanceAvailable ? 1 : 0)
    : 2 + bluetoothCards.length
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

  function pluginScript(name) {
    var url = String(Qt.resolvedUrl("scripts/" + name))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  function open(payloadJson) {
    var payload = ({})
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) { payload = ({}) }
    activeTab = payload.tab === "bluetooth" ? 1 : 0
    openRequested = true
    closingFromHost = false
    cursorActive = false
    selectedIndex = 0
    error = ""
    profilesLoaded = false
    if (windowRuleReady) showOnCurrentWorkspace()
    else if (!windowRuleProc.running) windowRuleProc.running = true
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
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    openRequested = false
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
  }

  function setOutputOverdrive(enabled) {
    var next = ({})
    for (var key in audioControlSettings) next[key] = audioControlSettings[key]
    next.version = 1
    next.outputOverdrive = enabled
    audioControlSettings = next
    outputOverdrive = enabled
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
    var next = Math.max(0, Math.min(1, index))
    if (next === activeTab) return
    closeProfileMenus()
    activeTab = next
    selectedIndex = 0
    clampCursor()
    var flick = scrollArea ? scrollArea.contentItem : null
    if (flick && flick.contentY !== undefined) flick.contentY = 0
  }

  function switchTab(direction) {
    selectTab((activeTab + (direction < 0 ? -1 : 1) + 2) % 2)
  }

  function setCursor(index) {
    cursorActive = true
    selectedIndex = index
  }

  function activateCursor() {
    if (!cursorActive || itemCount === 0) return
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
    if (activeTab === 1 && selectedIndex === 0) {
      setBluetoothAutoSwitch(!bluetoothAutoSwitch)
      return
    }
    if (activeTab === 1 && selectedIndex === 1) {
      bluetoothPreferenceDropdown.toggle()
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
    if (!card || !card.name || !profile || profileSetProc.running) return
    error = ""
    pendingSharedProfile = card.bluetooth && card.address ? {
      address: String(card.address),
      profile: String(profile)
    } : null
    profileSetProc.command = [pluginScript("audio-profile-set"), String(card.name), profile]
    profileSetProc.running = true
  }

  function setAudioPort(port, value) {
    if (!port || !value || portSetProc.running) return
    error = ""
    portSetProc.command = [pluginScript("audio-port-set"), port.direction, port.endpoint, value]
    portSetProc.running = true
  }

  function setBluetoothAutoSwitch(enabled) {
    if (!bluetoothAutoSwitchLoaded || bluetoothAutoswitchProc.running) return
    error = ""
    autoswitchMutation = true
    bluetoothAutoswitchProc.command = [pluginScript("audio-bluetooth-autoswitch"), enabled ? "on" : "off"]
    bluetoothAutoswitchProc.running = true
  }

  function setBluetoothProfilePreference(value) {
    if (!bluetoothProfilePreferenceLoaded || bluetoothPreferenceProc.running
        || (value !== "quality" && value !== "latency")) return
    error = ""
    bluetoothProfilePreference = value
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

  Process {
    id: profilesProc
    command: [root.pluginScript("audio-profiles")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseAudioProfiles(text)
    }
    onExited: function(exitCode) {
      root.profilesLoaded = true
      if (exitCode !== 0 && window.visible) root.error = "Could not load audio profiles"
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
      if (exitCode !== 0 && window.visible) root.error = "Could not load audio ports"
    }
  }

  Process {
    id: profileSetProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.error = "Could not change the audio profile"
      else {
        root.error = ""
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
      if (exitCode !== 0) root.error = "Could not change the audio port"
      else root.error = ""
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
      if (root.autoswitchMutation && exitCode !== 0)
        root.error = "Could not change automatic headset mode"
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
      if (root.bluetoothProfilePreferenceMutation && exitCode !== 0)
        root.error = "Could not change Bluetooth profile preference"
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
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide("ssupt.audio-control")
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
                  text: "Configure audio devices, Bluetooth codecs, and headset behavior."
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
                { value: "bluetooth", label: "Bluetooth", icon: "󰂯" }
              ]
              value: root.activeTab === 0 ? "devices" : "bluetooth"
              focusable: false
              foreground: root.foreground
              background: root.background
              fontFamily: root.fontFamily
              onChanged: function(value) { root.selectTab(value === "bluetooth" ? 1 : 0) }
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

    function togglePortMenu() { portDropdown.toggle() }
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
        enabled: !portSetProc.running
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

    function toggleProfileMenu() { profileDropdown.toggle() }
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
        enabled: !profileSetProc.running
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
