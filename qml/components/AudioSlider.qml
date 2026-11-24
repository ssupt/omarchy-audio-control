import QtQuick
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Sharp rectangular slider with a square cursor and one pointer owner for
// the entire drag. The panel can scroll, so the press must keep its grab
// outside the slider too.
Item {
  id: root

  property QtObject bar: null
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool integer: false
  property bool hasCursor: false
  property color trackColor: Style.selectedFillFor(
    bar ? bar.foreground : Commons.Color.foreground, Commons.Color.accent)
  property color fillColor: bar ? bar.foreground : Commons.Color.foreground
  property color knobColor: bar ? bar.foreground : Commons.Color.foreground
  property bool dragging: false
  property real trackHeight: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
    + (meterEnabled ? Math.max(2, Style.space(2)) : 0)
  property real knobSize: Math.max(14, Math.round(Style.spacing.controlHeight * 0.38))
  property real liveValue: value

  // Optional notches cut into the track in the panel background color.
  property int tickCount: 0
  property color tickColor: bar ? bar.background : Commons.Color.background

  // Optional live level meter drawn inside the track. The volume fill dims
  // so the solid meter reads through it; the square cursor marks the volume.
  // Levels are fractions of the full track, matching the volume scale.
  property bool meterEnabled: false
  property real meterLevel: 0
  property real meterHold: 0
  property bool meterAlert: false
  property color meterAlertColor: Commons.Color.urgent
  readonly property color meterColor: meterAlert ? meterAlertColor
    : (bar ? bar.foreground : Commons.Color.foreground)

  onValueChanged: if (!dragging) liveValue = value

  signal moved(real value)
  signal released(real value)
  signal rightClicked()

  implicitWidth: Style.space(200)
  implicitHeight: Math.max(Style.space(22), knobSize + Style.spacing.md)

  readonly property real range: Math.max(0.0001, maximum - minimum)
  readonly property real progress: Math.max(0, Math.min(1, (liveValue - minimum) / range))
  readonly property bool _hot: pointer.containsMouse || root.dragging
  readonly property bool mirrored: LayoutMirroring.enabled

  function trackX(fraction) {
    return track.x + track.width * (root.mirrored ? 1 - fraction : fraction)
  }

  function cancelDrag() {
    dragging = false
    liveValue = value
  }

  onEnabledChanged: if (!enabled) cancelDrag()
  onVisibleChanged: if (!visible) cancelDrag()

  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: root.knobSize / 2
    anchors.rightMargin: root.knobSize / 2
    height: root.trackHeight
    radius: 0
    color: root.trackColor
  }

  Rectangle {
    id: fill
    anchors.verticalCenter: track.verticalCenter
    anchors.left: track.left
    height: track.height
    radius: 0
    color: root.meterEnabled ? Util.alpha(root.fillColor, 0.38) : root.fillColor
    width: track.width * root.progress

    Behavior on width {
      enabled: !root.dragging
      NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
    }
  }

  Rectangle {
    id: meterBar
    visible: root.meterEnabled
    anchors.verticalCenter: track.verticalCenter
    anchors.left: track.left
    height: track.height
    radius: 0
    width: track.width * Math.max(0, Math.min(1, root.meterLevel))
    color: root.meterColor

    Behavior on width { NumberAnimation { duration: 70 } }
  }

  Rectangle {
    id: meterHoldTick
    visible: root.meterEnabled && root.meterHold > 0.02
    width: Math.max(1, Style.space(2))
    height: track.height + Style.space(4)
    radius: 0
    anchors.verticalCenter: track.verticalCenter
    x: Math.max(track.x, Math.min(track.x + track.width - width,
      root.trackX(Math.min(1, root.meterHold)) - width / 2))
    color: root.meterHold >= 0.98 ? root.meterAlertColor : root.meterColor
  }

  Repeater {
    model: root.tickCount > 1 ? root.tickCount : 0
    Rectangle {
      required property int index
      width: Math.max(1, Style.space(2))
      height: track.height + Style.space(4)
      radius: 0
      color: root.tickColor
      anchors.verticalCenter: track.verticalCenter
      x: root.trackX(index / (root.tickCount - 1)) - width / 2
    }
  }

  BorderSurface {
    id: knob
    width: root.knobSize
    height: root.knobSize
    radius: 0
    color: root.knobColor
    borderSpec: Border.flat(root.bar ? root.bar.background : Commons.Color.background,
      Math.max(1, Style.space(2)))
    anchors.verticalCenter: track.verticalCenter
    x: root.trackX(root.progress) - width / 2
    scale: root._hot ? 1.12 : 1.0

    Behavior on x {
      enabled: !root.dragging
      NumberAnimation { duration: Style.duration(140); easing.type: Easing.OutCubic }
    }

    Behavior on scale {
      NumberAnimation { duration: Style.duration(110); easing.type: Easing.OutCubic }
    }
  }

  Rectangle {
    anchors.fill: parent
    radius: 0
    color: "transparent"
    border.color: root.fillColor
    border.width: root.hasCursor ? 1 : 0
  }

  MouseArea {
    id: pointer
    z: 1000
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    preventStealing: true

    function valueFromX(x) {
      if (track.width <= 0) return root.minimum
      var fraction = Math.max(0, Math.min(1, (x - track.x) / track.width))
      if (root.mirrored) fraction = 1 - fraction
      var next = root.minimum + fraction * root.range
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
