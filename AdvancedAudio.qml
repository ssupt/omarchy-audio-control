import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
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
  property bool bluetoothAutoSwitch: true
  property bool bluetoothAutoSwitchLoaded: false
  property bool autoswitchMutation: false
  property string error: ""
  property int activeTab: 0  // 0 = devices, 1 = Bluetooth
  property bool cursorActive: false
  property int selectedIndex: 0
  property bool profileMenuOpen: false

  readonly property color foreground: Color.foreground
  readonly property color background: Color.background
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: Style.font.family
  readonly property var bluetoothCards: Model.audioCardsByBluetooth(audioCards, true)
  readonly property var deviceCards: Model.audioCardsByBluetooth(audioCards, false)
  readonly property int itemCount: activeTab === 0 ? deviceCards.length : 1 + bluetoothCards.length
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)

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
  }

  function parseAudioProfiles(raw) {
    audioCards = Model.parseAudioProfiles(raw)
    clampCursor()
  }

  function profileOptions(card) {
    return Model.audioProfileOptions(card)
  }

  function clampCursor() {
    selectedIndex = Math.max(0, Math.min(Math.max(0, itemCount - 1), selectedIndex))
  }

  function moveCursor(delta) {
    if (itemCount === 0) return
    selectedIndex = Math.max(0, Math.min(itemCount - 1, selectedIndex + delta))
  }

  function closeProfileMenus() {
    var repeaters = [deviceProfileRepeater, bluetoothProfileRepeater]
    for (var r = 0; r < repeaters.length; r++) {
      var repeater = repeaters[r]
      for (var i = 0; i < repeater.count; i++) {
        var row = repeater.itemAt(i)
        if (row) row.closeProfileMenu()
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
    if (activeTab === 1 && selectedIndex === 0) {
      setBluetoothAutoSwitch(!bluetoothAutoSwitch)
      return
    }
    var row = activeTab === 0
      ? deviceProfileRepeater.itemAt(selectedIndex)
      : bluetoothProfileRepeater.itemAt(selectedIndex - 1)
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
    if (!card || !profile || profileSetProc.running) return
    error = ""
    profileSetProc.command = [pluginScript("audio-profile-set"), card, profile]
    profileSetProc.running = true
  }

  function setBluetoothAutoSwitch(enabled) {
    if (!bluetoothAutoSwitchLoaded || bluetoothAutoswitchProc.running) return
    error = ""
    autoswitchMutation = true
    bluetoothAutoswitchProc.command = [pluginScript("audio-bluetooth-autoswitch"), enabled ? "on" : "off"]
    bluetoothAutoswitchProc.running = true
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

  Process {
    id: profilesProc
    command: [root.pluginScript("audio-profiles")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseAudioProfiles(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && window.visible) root.error = "Could not load audio profiles"
    }
  }

  Process {
    id: profileSetProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.error = "Could not change the audio profile"
      else root.error = ""
      profileRefreshTimer.restart()
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

  Timer {
    id: profileRefreshTimer
    interval: 200
    repeat: false
    onTriggered: if (window.visible && !profilesProc.running) profilesProc.running = true
  }

  Timer {
    interval: 2000
    running: window.visible
    repeat: true
    onTriggered: if (!root.profileMenuOpen && !profilesProc.running && !profileSetProc.running)
      profilesProc.running = true
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

            Column {
              id: content
              width: scrollArea.availableWidth
              spacing: Style.space(18)

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
                        text: "Switch to communication audio when an application records from the headset microphone."
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
              }

              PanelSeparator {
                visible: root.activeTab === 1
                foreground: root.foreground
              }

              Column {
                width: parent.width
                spacing: Style.space(12)

                Text {
                  visible: profilesProc.running
                    && ((root.activeTab === 0 && root.deviceCards.length === 0)
                      || (root.activeTab === 1 && root.bluetoothCards.length === 0))
                  text: "Loading device profiles…"
                  color: Qt.darker(root.foreground, 1.35)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  visible: !profilesProc.running
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
                      rowIndex: 1 + index
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
                      rowIndex: index
                    }
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
        value: String(profileRow.card.activeProfile || "off")
        options: root.profileOptions(profileRow.card)
        hasCursor: profileRow.hasCursor
        enabled: !profileSetProc.running
        opacity: enabled ? 1 : 0.6
        foreground: root.foreground
        fontFamily: root.fontFamily
        anchors.verticalCenter: parent.verticalCenter

        onHovered: function(on) { if (on) root.setCursor(profileRow.rowIndex) }
        onChanged: function(profile) { root.setAudioProfile(profileRow.card.name, profile) }
        onPopupOpenChanged: {
          root.profileMenuOpen = popupOpen
          if (!popupOpen) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
        }
      }
    }
  }
}
