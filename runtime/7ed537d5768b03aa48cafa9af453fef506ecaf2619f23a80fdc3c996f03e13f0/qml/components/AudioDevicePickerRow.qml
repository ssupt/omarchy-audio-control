import QtQuick
import qs.Ui
import qs.Commons

// Compact device picker: a single row naming the current device that
// expands the section's full device list in place. Shown instead of the
// list when the compact layout is enabled and the list is collapsed.
CursorSurface {
  id: root

  required property var bar
  required property string section
  required property string glyph
  required property string label
  required property int deviceCount
  readonly property bool expandable: deviceCount > 1

  signal claimed(string section, int index)
  signal activated()

  implicitHeight: pickerInner.implicitHeight + Style.spacing.xl

  Row {
    id: pickerInner
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: root.glyph
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.title
      width: Style.space(22)
      horizontalAlignment: Text.AlignHCenter
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      textFormat: Text.PlainText
      text: root.label
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideRight
      width: parent.width - Style.space(22)
        - (pickerHint.visible ? pickerHint.width + Style.space(16) : Style.space(8))
      anchors.verticalCenter: parent.verticalCenter
    }

    Row {
      id: pickerHint
      visible: root.expandable
      spacing: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter

      Text {
        textFormat: Text.PlainText
        text: String(root.deviceCount)
        color: Qt.darker(root.bar.foreground, 1.4)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        textFormat: Text.PlainText
        text: "󰅀"
        color: Qt.darker(root.bar.foreground, 1.2)
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: root.expandable
    hoverEnabled: root.expandable
    cursorShape: Qt.PointingHandCursor
    onContainsMouseChanged: if (containsMouse) root.claimed(root.section, 0)
    onClicked: root.activated()
  }
}
