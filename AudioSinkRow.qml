import QtQuick
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Output device row — cursor target inside the "output" section. Mouse
// hover claims the panel cursor via the claimed() signal; visuals come
// entirely from hasCursor/current via CursorSurface, never from containsMouse.
CursorSurface {
  id: root

  required property var node
  required property int rowIndex
  required property var bar
  required property string preferredName
  required property bool defaultSetBusy
  required property string label

  signal claimed(string section, int index)
  signal activated(var node)

  readonly property bool isActive: root.node && String(root.node.name || "") === root.preferredName

  current: root.isActive
  implicitHeight: deviceInner.implicitHeight + Style.spacing.xl

  Row {
    id: deviceInner
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(8)

    Text {
      text: Model.sinkGlyph(root.node)
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.title
      width: Style.space(22)
      horizontalAlignment: Text.AlignHCenter
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: root.label
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: root.isActive
      elide: Text.ElideRight
      width: parent.width - Style.space(22) - Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !root.defaultSetBusy
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onContainsMouseChanged: if (containsMouse) root.claimed("output", root.rowIndex)
    onClicked: root.activated(root.node)
  }
}
