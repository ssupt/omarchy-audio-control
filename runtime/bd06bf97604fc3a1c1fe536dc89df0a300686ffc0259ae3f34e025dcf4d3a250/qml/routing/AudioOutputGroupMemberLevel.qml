import QtQuick
import qs.Ui
import qs.Commons
import "../components"

Item {
  id: root

  required property string label
  required property var node
  required property bool connected
  property real maximum: 1
  property bool busy: false
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal volumeMoved(var node, real value)

  readonly property real currentVolume: {
    try {
      if (!connected || !node || !node.audio) return 0
      var value = Number(node.audio.volume)
      return isFinite(value) ? value : 0
    } catch (_error) {
      return 0
    }
  }

  implicitHeight: memberContent.implicitHeight

  Column {
    id: memberContent
    width: parent.width
    spacing: Style.space(4)

    Item {
      width: parent.width
      height: Math.max(memberLabel.implicitHeight, memberValue.implicitHeight)

      Text {
        id: memberLabel
        text: root.label
        color: root.connected ? root.foreground : Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
        width: parent.width - memberValue.width - Style.space(12)
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: memberValue
        text: root.connected
          ? Math.round((memberSlider.dragging
            ? memberSlider.liveValue : root.currentVolume) * 100) + "%"
          : "OFFLINE"
        color: root.connected ? Qt.darker(root.foreground, 1.35) : root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    AudioSlider {
      id: memberSlider
      width: parent.width
      minimum: 0
      maximum: root.maximum
      step: 0.05
      tickCount: root.maximum > 1 ? 7 : 5
      value: root.currentVolume
      enabled: root.enabled && root.connected && !root.busy
      opacity: enabled ? 1 : 0.45
      onMoved: function(value) { root.volumeMoved(root.node, value) }
    }
  }
}
