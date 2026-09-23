import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property string title
  required property string description
  required property string icon
  property bool actionEnabled: true
  property bool busy: false
  property bool urgentAction: false
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal activated()
  signal hovered()

  implicitHeight: content.implicitHeight + Style.space(18)
  bordered: true
  opacity: actionEnabled ? 1 : 0.55

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(10)

    Column {
      width: parent.width - action.width - parent.spacing
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: root.title
        color: root.urgentAction ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: root.description
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    PanelActionButton {
      id: action
      iconText: root.busy ? "󰔟" : root.icon
      tooltipText: root.title
      foreground: root.foreground
      hoverColor: root.urgentAction ? root.urgent : root.foreground
      fontFamily: root.fontFamily
      bordered: true
      hasCursor: root.hasCursor
      enabled: root.enabled && root.actionEnabled && !root.busy
      anchors.verticalCenter: parent.verticalCenter
      onClicked: root.activated()
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.actionEnabled && !root.busy
    acceptedButtons: Qt.NoButton
    hoverEnabled: true
    onContainsMouseChanged: if (containsMouse) root.hovered()
  }
}
