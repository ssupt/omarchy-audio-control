import QtQuick
import qs.Ui

// Keep Omarchy's slider appearance, but clear a drag if its MouseArea loses
// the release event to a disabled control, hidden panel or scroll gesture.
PanelSlider {
  id: root

  function cancelDrag() {
    dragging = false
    liveValue = value
  }

  onEnabledChanged: if (!enabled) cancelDrag()
  onVisibleChanged: if (!visible) cancelDrag()

  PointHandler {
    id: pointer
    acceptedButtons: Qt.LeftButton
    onActiveChanged: if (!active) {
      root.dragging = false
      // Let the MouseArea emit released with its final value first.
      Qt.callLater(function() {
        if (!pointer.active) root.liveValue = root.value
      })
    }
    onCanceled: root.cancelDrag()
  }
}
