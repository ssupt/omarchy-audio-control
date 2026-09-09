import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property var definition
  required property real value
  property string fontFamily: Style.font.family

  signal committed(real value)
  signal hovered()

  implicitHeight: content.implicitHeight + Style.space(18)
  bordered: true

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(6)

    Item {
      width: parent.width
      height: Math.max(labels.implicitHeight, percentage.implicitHeight)

      Column {
        id: labels
        width: parent.width - percentage.width - Style.space(16)
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

      Text {
        id: percentage
        text: Math.round((slider.dragging ? slider.liveValue : root.value) * 100) + "%"
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.top: parent.top
      }
    }

    PanelSlider {
      id: slider
      width: parent.width
      minimum: 0
      maximum: 1
      step: 0.05
      tickCount: 5
      value: root.value
      enabled: root.enabled
      onReleased: function(value) { root.committed(value) }
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    hoverEnabled: true
    onContainsMouseChanged: if (containsMouse) root.hovered()
  }
}
