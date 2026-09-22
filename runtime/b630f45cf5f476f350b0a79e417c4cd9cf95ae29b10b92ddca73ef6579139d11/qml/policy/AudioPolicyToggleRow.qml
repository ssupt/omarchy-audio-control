import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property var definition
  required property bool checked
  property bool busy: false
  property string fontFamily: Style.font.family

  signal activated()
  signal hovered()

  implicitHeight: content.implicitHeight + Style.space(18)
  bordered: true

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(12)

    Column {
      width: parent.width - toggle.width - parent.spacing
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: root.definition.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: root.definition.description
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: toggle
      checked: root.checked
      busy: root.busy
      interactive: false
      cursorRing: false
      foreground: root.foreground
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.enabled
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onContainsMouseChanged: if (containsMouse) root.hovered()
    onClicked: root.activated()
  }
}
