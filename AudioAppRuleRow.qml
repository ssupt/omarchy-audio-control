import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property string appLabel
  required property string direction
  required property string targetLabel
  required property bool targetAvailable
  required property var options
  required property string currentValue
  required property bool menuEnabled
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal targetChosen(string value)
  signal deleted()
  signal cursorRequested()
  signal menuToggled(bool open)

  width: parent ? parent.width : 0
  implicitHeight: Math.max(ruleLabels.implicitHeight,
    Math.max(targetDropdown.implicitHeight, deleteButton.height)) + Style.space(18)
  bordered: true

  function toggleTargetMenu() { if (targetDropdown.enabled) targetDropdown.toggle() }
  function closeTargetMenu() { targetDropdown.close() }

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(10)

    Column {
      id: ruleLabels
      width: Math.max(Style.space(150), parent.width * 0.28 - deleteButton.width - parent.spacing * 2)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: root.appLabel
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: (root.direction === "recording" ? "Recording" : "Playback")
          + " · " + (root.targetLabel !== "" ? root.targetLabel : "unknown device")
          + (root.targetAvailable ? "" : " · not connected")
        color: root.targetAvailable ? Qt.darker(root.foreground, 1.35) : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    AudioDropdown {
      id: targetDropdown
      width: parent.width - ruleLabels.width - deleteButton.width - parent.spacing * 2
      showLabel: false
      popupDirection: "down"
      value: root.currentValue
      options: root.options
      hasCursor: root.hasCursor
      enabled: root.menuEnabled
      opacity: enabled ? 1 : 0.6
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.verticalCenter: parent.verticalCenter

      onHovered: function(on) { if (on) root.cursorRequested() }
      onChanged: function(value) { root.targetChosen(value) }
      onPopupOpenChanged: root.menuToggled(popupOpen)
    }

    PanelActionButton {
      id: deleteButton
      iconText: "󰆴"
      tooltipText: "Delete rule"
      foreground: root.foreground
      hoverColor: root.urgent
      fontFamily: root.fontFamily
      bordered: true
      enabled: root.enabled && root.menuEnabled
      anchors.verticalCenter: parent.verticalCenter
      onClicked: root.deleted()
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    hoverEnabled: true
    onContainsMouseChanged: if (containsMouse) root.cursorRequested()
  }
}
