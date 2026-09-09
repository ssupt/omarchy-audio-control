import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property string groupName
  required property string groupId
  required property var members
  required property var memberLevels
  required property var options
  required property bool available
  required property string statusText
  required property bool busy
  property bool memberVolumeBusy: false
  property real volumeMaximum: 1
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal membersChosen(var values)
  signal deleted()
  signal cursorRequested()
  signal menuToggled(bool open)
  signal memberVolumeMoved(var node, real value)

  property bool memberMenuReportedOpen: false

  width: parent ? parent.width : 0
  implicitHeight: groupContent.implicitHeight + Style.space(18)
  bordered: true

  function toggleMemberMenu() { if (memberSelect.enabled) memberSelect.toggle() }
  function closeMemberMenu() { memberSelect.close() }
  function reportMemberMenu(open) {
    var next = open === true
    if (memberMenuReportedOpen === next) return
    memberMenuReportedOpen = next
    menuToggled(next)
  }
  function syncMemberValues() { memberSelect.values = root.members || [] }

  onMembersChanged: syncMemberValues()
  Component.onCompleted: syncMemberValues()
  Component.onDestruction: reportMemberMenu(false)

  Column {
    id: groupContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(9)

    Row {
      id: groupHeader
      width: parent.width
      spacing: Style.space(10)

      Column {
        id: groupLabels
        width: Math.max(Style.space(150), parent.width * 0.28 - deleteButton.width)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(3)

        Text {
          width: parent.width
          text: root.groupName
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: root.statusText
          color: root.available ? Qt.darker(root.foreground, 1.35) : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      MultiSelect {
        id: memberSelect
        width: parent.width - groupLabels.width - deleteButton.width - parent.spacing * 2
        showLabel: false
        values: []
        options: root.options
        triggerLabel: "Choose outputs"
        emptyText: "No physical outputs available"
        hasCursor: root.hasCursor
        enabled: !root.busy
        opacity: enabled ? 1 : 0.6
        foreground: root.foreground
        fontFamily: root.fontFamily

        onHovered: function(on) { if (on) root.cursorRequested() }
        onChanged: function(values) {
          root.membersChosen(values)
          // The helper commits transactionally. Retain the stored selection
          // until the watched rules file confirms the new member set.
          Qt.callLater(function() { memberSelect.values = root.members })
        }
        onPopupOpenChanged: root.reportMemberMenu(popupOpen)
      }

      PanelActionButton {
        id: deleteButton
        iconText: "󰆴"
        tooltipText: "Delete output group"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        bordered: true
        enabled: !root.busy
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.deleted()
      }
    }

    Column {
      width: parent.width
      visible: root.memberLevels.length > 0
      spacing: Style.space(6)

      Rectangle {
        width: parent.width
        height: 1
        color: Util.alpha(root.foreground, 0.14)
      }

      Item {
        width: parent.width
        height: Math.max(memberLevelsTitle.implicitHeight, sharedVolumeHint.implicitHeight)

        Text {
          id: memberLevelsTitle
          text: "MEMBER LEVELS"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          id: sharedVolumeHint
          text: "SHARED DEVICE VOLUME"
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      Repeater {
        model: root.memberLevels.length

        AudioOutputGroupMemberLevel {
          required property int index
          readonly property var descriptor: root.memberLevels[index]
          width: groupContent.width
          label: descriptor ? String(descriptor.label || descriptor.name || "Output") : "Output"
          node: descriptor ? descriptor.node : null
          connected: !!descriptor && descriptor.connected === true
          maximum: root.volumeMaximum
          busy: root.memberVolumeBusy
          foreground: root.foreground
          urgent: root.urgent
          fontFamily: root.fontFamily
          onVolumeMoved: function(node, value) { root.memberVolumeMoved(node, value) }
        }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    hoverEnabled: true
    onContainsMouseChanged: if (containsMouse) root.cursorRequested()
  }
}
