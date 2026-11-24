import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons
import qs.Commons as Commons

CursorSurface {
  id: root

  required property string groupName
  required property var selectedMembers
  required property var options
  required property bool busy
  property string fontFamily: Style.font.family

  signal nameEdited(string value)
  signal membersEdited(var values)
  signal createRequested()
  signal cursorRequested()
  signal menuToggled(bool open)

  property bool memberMenuReportedOpen: false
  readonly property bool nameFocused: groupNameField.activeFocus

  readonly property bool ready: groupName.trim() !== ""
    && selectedMembers && selectedMembers.length >= 2 && !busy

  width: parent ? parent.width : 0
  implicitHeight: Math.max(groupNameField.implicitHeight,
    Math.max(memberSelect.implicitHeight, createButton.height)) + Style.space(18)
  bordered: true

  function activate() {
    if (root.groupName.trim() === "") {
      groupNameField.forceActiveFocus()
      groupNameField.selectAll()
    } else if (!root.selectedMembers || root.selectedMembers.length < 2) {
      if (memberSelect.enabled) memberSelect.toggle()
    } else if (root.ready) {
      root.createRequested()
    }
  }
  function closeMemberMenu() { memberSelect.close() }
  function reportMemberMenu(open) {
    var next = open === true
    if (memberMenuReportedOpen === next) return
    memberMenuReportedOpen = next
    menuToggled(next)
  }
  function syncMemberValues() {
    memberSelect.values = root.selectedMembers || []
  }
  function syncNameText() {
    if (groupNameField.text !== root.groupName) groupNameField.text = root.groupName
  }
  function focusName() {
    groupNameField.forceActiveFocus()
    groupNameField.selectAll()
  }

  onGroupNameChanged: syncNameText()
  onSelectedMembersChanged: syncMemberValues()
  Component.onCompleted: {
    syncNameText()
    syncMemberValues()
  }
  Component.onDestruction: reportMemberMenu(false)

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(10)

    TextField {
      id: groupNameField
      width: Math.max(Style.space(150), parent.width * 0.28)
      text: root.groupName
      placeholderText: "Group name"
      color: root.foreground
      placeholderTextColor: Qt.darker(root.foreground, 1.8)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      selectByMouse: true
      enabled: !root.busy
      verticalAlignment: TextInput.AlignVCenter
      background: Rectangle {
        color: "transparent"
        border.width: 1
        border.color: groupNameField.activeFocus ? Commons.Color.accent
          : Qt.darker(root.foreground, 1.8)
        radius: 0
      }
      onTextEdited: root.nameEdited(text)
      onAccepted: {
        if (root.ready) root.createRequested()
        else if (memberSelect.enabled) memberSelect.toggle()
      }
      Keys.onEscapePressed: groupNameField.focus = false
      onActiveFocusChanged: if (activeFocus) root.cursorRequested()
    }

    MultiSelect {
      id: memberSelect
      width: parent.width - groupNameField.width - createButton.width - parent.spacing * 2
      showLabel: false
      values: []
      options: root.options
      triggerLabel: "Choose at least two outputs"
      noSelectionText: "Choose at least two outputs"
      emptyText: "Connect two outputs to create a group"
      hasCursor: root.hasCursor
      enabled: !root.busy && root.options.length >= 2
      opacity: enabled ? 1 : 0.6
      foreground: root.foreground
      fontFamily: root.fontFamily

      onHovered: function(on) { if (on) root.cursorRequested() }
      onChanged: function(values) { root.membersEdited(values) }
      onPopupOpenChanged: root.reportMemberMenu(popupOpen)
    }

    PanelActionButton {
      id: createButton
      iconText: "󰐕"
      tooltipText: "Create output group"
      foreground: root.foreground
      fontFamily: root.fontFamily
      bordered: true
      enabled: root.ready
      anchors.verticalCenter: parent.verticalCenter
      onClicked: root.createRequested()
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    hoverEnabled: true
    onContainsMouseChanged: if (containsMouse) root.cursorRequested()
  }
}
