import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property var card
  required property int rowIndex
  required property string currentProfile
  required property var options
  required property bool menuEnabled
  property string fontFamily: Style.font.family

  signal cursorRequested()
  signal profileSelected(string profile)
  signal menuToggled(bool open)

  width: parent ? parent.width : 0
  implicitHeight: Math.max(profileLabels.implicitHeight, profileDropdown.implicitHeight) + Style.space(18)
  bordered: true

  function toggleProfileMenu() { if (profileDropdown.enabled) profileDropdown.toggle() }
  function closeProfileMenu() { profileDropdown.close() }

  Component.onDestruction: if (profileDropdown.popupOpen) root.menuToggled(false)

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
        text: root.card.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        visible: root.card.bluetooth === true
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
      value: root.currentProfile
      options: root.options
      hasCursor: root.hasCursor
      enabled: root.menuEnabled
      opacity: enabled ? 1 : 0.6
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.verticalCenter: parent.verticalCenter

      onHovered: function(on) { if (on) root.cursorRequested() }
      onChanged: function(profile) { root.profileSelected(profile) }
      onPopupOpenChanged: root.menuToggled(popupOpen)
    }
  }
}
