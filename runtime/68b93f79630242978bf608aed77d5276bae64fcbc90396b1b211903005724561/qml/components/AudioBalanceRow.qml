import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property var node
  required property string label
  required property int rowIndex
  required property string deviceLabel
  required property real balanceValue
  property string fontFamily: Style.font.family

  signal cursorRequested()
  signal balanceMoved(real value)

  width: parent ? parent.width : 0
  implicitHeight: balanceColumn.implicitHeight + Style.space(18)
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
        text: root.label + " · " + root.deviceLabel
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
          var value = root.balanceValue
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
        value: root.balanceValue
        tickCount: 3
        onMoved: function(value) { root.balanceMoved(value) }
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
    onContainsMouseChanged: if (containsMouse) root.cursorRequested()
  }
}
