import QtQuick
import qs.Ui

// Omarchy's visual slider with one pointer owner for the entire drag. The
// panel can scroll, so the press must keep its grab outside the slider too.
PanelSlider {
  id: root

  function cancelDrag() {
    dragging = false
    liveValue = value
  }

  onEnabledChanged: if (!enabled) cancelDrag()
  onVisibleChanged: if (!visible) cancelDrag()

  MouseArea {
    id: pointer
    z: 1000
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    preventStealing: true

    function valueFromX(x) {
      var width = Math.max(1, root.width)
      var fraction = Math.max(0, Math.min(1, x / width))
      var next = root.minimum + fraction * (root.maximum - root.minimum)
      if (root.integer) next = Math.round(next)
      return Math.max(root.minimum, Math.min(root.maximum, next))
    }

    onPressed: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragging = true
      root.liveValue = valueFromX(mouse.x)
      root.moved(root.liveValue)
    }
    onPositionChanged: function(mouse) {
      if (!root.dragging) return
      if (!(mouse.buttons & Qt.LeftButton)) { root.cancelDrag(); return }
      root.liveValue = valueFromX(mouse.x)
      root.moved(root.liveValue)
    }
    onReleased: function(mouse) {
      if (mouse.button !== Qt.LeftButton || !root.dragging) return
      root.dragging = false
      root.released(root.liveValue)
      root.liveValue = root.value
    }
    onCanceled: root.cancelDrag()
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton) root.rightClicked()
    }
    onWheel: function(wheel) {
      var delta = wheel.angleDelta.y > 0 ? root.step : -root.step
      var next = Math.max(root.minimum, Math.min(root.maximum, root.liveValue + delta))
      if (root.integer) next = Math.round(next)
      root.liveValue = next
      root.moved(next)
      root.released(next)
    }
  }
}
