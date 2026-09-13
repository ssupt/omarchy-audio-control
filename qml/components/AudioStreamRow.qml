import QtQuick
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "../core/Model.js" as Model

// Playback and recording applications share interaction and volume controls;
// only their endpoint list, route map, label, and icon differ.
CursorSurface {
  id: root

  required property var node
  required property bool nodeLive
  required property int rowIndex
  property bool recording: false
  property real volumeMaximum: 1.0
  required property var bar
  required property bool monitorEnabled
  required property bool representsPlayer
  required property var currentRoute
  required property var routeOptions
  required property string streamLabel
  required property var iconSource
  required property bool routeAvailable
  required property bool routeSetBusy
  required property bool mutationBlocked
  property bool popupReportedOpen: false

  signal claimed(string section, int index)
  signal volumeRequested(real value)
  signal muteRequested()
  signal routeChosen(string optionValue)
  signal popupToggled(bool open)

  // PipeWire nodes publish their audio interface only once bound; reading
  // it earlier — which happens while streams churn during profile or codec
  // switches — has historically destabilized Quickshell's Pipewire service.
  readonly property bool nodeReady: liveAudioReady()
  readonly property real streamVolume: liveAudioVolume()
  readonly property bool streamMuted: liveAudioMuted()
  readonly property real meterLevel: !root.nodeReady ? 0 : Model.audioMeterLevel(
    streamPeakMonitor.peaks,
    liveAudioVolumes(),
    streamPeakMonitor.peak,
    streamVolume,
    streamMuted)
  readonly property bool isActive: !root.recording && root.representsPlayer
  readonly property string routeSection: root.recording ? "recording" : "streams"
  readonly property string targetSerial: root.currentRoute ? String(root.currentRoute.target || "") : ""
  readonly property string routeMode: root.currentRoute ? String(root.currentRoute.mode || "") : ""
  readonly property string routeOptionValue: routeMode !== "" && targetSerial !== ""
    ? routeMode + ":" + targetSerial : ""
  readonly property bool routeIsExplicit: routeMode === "override"
  readonly property bool routeMenuAvailable: Model.streamRouteDestinationCount(
    root.routeOptions) > 1
    && root.targetSerial !== ""

  implicitHeight: streamColumn.implicitHeight + Style.spacing.xl

  function liveAudioReady() {
    try { return root.nodeLive && !!root.node && root.node.ready === true && !!root.node.audio }
    catch (_error) { return false }
  }

  function liveAudioVolume() {
    try {
      var value = root.nodeReady ? Number(root.node.audio.volume) : 0
      return isFinite(value) ? value : 0
    } catch (_error) { return 0 }
  }

  function liveAudioMuted() {
    try { return root.nodeReady && root.node.audio.muted === true }
    catch (_error) { return false }
  }

  function liveAudioVolumes() {
    try { return root.nodeReady && root.node.audio.volumes ? root.node.audio.volumes : [] }
    catch (_error) { return [] }
  }

  function toggleOutputMenu() {
    if (root.routeMenuAvailable && routeDropdown.enabled)
      routeDropdown.toggle()
  }
  function reportPopup(open) {
    var next = open === true
    if (popupReportedOpen === next) return
    popupReportedOpen = next
    popupToggled(next)
  }

  Component.onDestruction: root.reportPopup(false)

  PwNodePeakMonitor {
    id: streamPeakMonitor
    node: root.node
    enabled: root.monitorEnabled && root.nodeReady
  }

  Column {
    id: streamColumn
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(2)

    Item {
      id: streamHeader
      width: parent.width
      height: streamHeaderContent.implicitHeight

      Row {
        id: streamHeaderContent
        anchors.fill: parent
        spacing: Style.space(8)

        Item {
          id: streamMuteIcon
          width: Style.space(22)
          height: Style.font.title
          anchors.verticalCenter: parent.verticalCenter

          Image {
            id: streamAppIcon
            anchors.centerIn: parent
            width: Style.font.title
            height: Style.font.title
            fillMode: Image.PreserveAspectFit
            sourceSize.width: Math.round(width * Screen.devicePixelRatio)
            sourceSize.height: Math.round(height * Screen.devicePixelRatio)
            source: root.iconSource
            asynchronous: true
            visible: status === Image.Ready
            opacity: root.streamMuted ? 0.5 : 1.0
          }

          Text {
            visible: !streamAppIcon.visible
            anchors.fill: parent
            text: root.recording
              ? (root.streamMuted ? "󰍭" : "󰍬")
              : (root.streamMuted ? "󰝟" : "󰕾")
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            opacity: root.streamMuted ? 0.5 : 1.0
          }

          MouseArea {
            anchors.fill: parent
            enabled: !root.mutationBlocked
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.nodeReady) root.muteRequested()
            }
          }
        }

        Item {
          id: streamNameArea
          width: parent.width - streamMuteIcon.width - streamPct.width - Style.space(16)
          height: Math.max(streamName.implicitHeight, routeChevron.visible ? routeChevron.height : 0)

          Text {
            id: streamName
            text: root.streamLabel
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: root.isActive
            elide: Text.ElideRight
            width: Math.min(implicitWidth, parent.width
              - (routeChevron.visible ? routeChevron.width + Style.space(4) : 0))
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            id: routeChevron
            visible: root.routeMenuAvailable
            width: Style.space(22)
            text: {
              var position = root.bar ? root.bar.position : "left"
              if (position === "top") return "󰅀"
              if (position === "bottom") return "󰅃"
              return position === "right" ? "󰅁" : "󰅂"
            }
            color: root.routeIsExplicit
              ? Style.selectedStateColor(root.bar.foreground, Color.accent)
              : Qt.darker(root.bar.foreground, 1.2)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            anchors.left: streamName.right
            anchors.leftMargin: Style.space(4)
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Text {
          id: streamPct
          text: Math.round(root.streamVolume * 100) + "%"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          width: Style.space(36)
          horizontalAlignment: Text.AlignRight
          anchors.verticalCenter: parent.verticalCenter
          opacity: root.streamMuted ? 0.5 : 1.0
        }
      }

      // Routing is a property of the application, so the dropdown's actual
      // trigger spans the whole header. Its chrome is hidden: the adjacent
      // chevron communicates the submenu while the leading icon owns mute
      // and the slider below continues to own volume changes.
      AudioDropdown {
        id: routeDropdown
        anchors.left: parent.left
        anchors.leftMargin: streamMuteIcon.width
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        z: 1
        visible: root.routeMenuAvailable
        rowHeight: height
        popupRowHeight: Style.space(34)
        popupDirection: {
          var position = root.bar ? root.bar.position : "left"
          if (position === "top") return "down"
          if (position === "bottom") return "up"
          return position === "right" ? "left" : "right"
        }
        popupGap: popupDirection === "left"
          ? Style.space(6) + streamMuteIcon.width
          : (popupDirection === "right" ? Style.space(6) : Style.spacing.xxs)
        popupOffsetX: popupDirection === "down" || popupDirection === "up"
          ? -Style.space(6) - streamMuteIcon.width : 0
        popupSideAlignment: "center"
        popupAnchorHeight: streamColumn.height
        popupWidth: root.width
        chevronOnly: true
        showChevron: false
        triggerChrome: false
        value: root.routeOptionValue
        options: root.routeOptions
        enabled: root.routeAvailable && !root.routeSetBusy && !root.mutationBlocked
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily

        onHovered: function(on) { if (on) root.claimed(root.routeSection, root.rowIndex) }
        onChanged: function(route) { root.routeChosen(route) }
        onPopupOpenChanged: root.reportPopup(popupOpen)
      }
    }

    AudioSlider {
      bar: root.bar
      width: parent.width
      minimum: 0
      maximum: root.volumeMaximum
      step: 0.05
      value: root.streamVolume
      opacity: root.streamMuted ? 0.5 : 1.0
      enabled: root.nodeReady && !root.mutationBlocked

      onMoved: function(v) {
        if (!root.mutationBlocked && root.nodeReady)
          root.volumeRequested(v)
      }
      onRightClicked: {
        if (!root.mutationBlocked && root.nodeReady)
          root.muteRequested()
      }
    }

    Rectangle {
      width: parent.width
      height: Math.max(Style.space(4), Style.spacing.xs)
      color: Util.alpha(root.bar.foreground, 0.18)
      opacity: root.streamMuted ? 0.35 : 1.0

      Rectangle {
        height: parent.height
        width: parent.width * root.meterLevel
        color: root.bar.foreground
        Behavior on width { NumberAnimation { duration: 70 } }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    propagateComposedEvents: true
    onContainsMouseChanged: if (containsMouse) root.claimed(root.routeSection, root.rowIndex)
  }
}
