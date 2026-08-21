import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property string deviceLabel
  required property string state
  required property int secondsRemaining
  required property real level
  required property bool microphoneMuted
  required property string error
  property string fontFamily: Style.font.family
  property color urgent: Color.urgent

  signal primaryActivated()
  signal discarded()
  signal hovered()

  readonly property bool running: state === "recording" || state === "stopping"
    || state === "playing"
  readonly property bool ready: state === "ready"
  readonly property bool primaryEnabled: state !== "stopping"
    && (running || ready || !microphoneMuted)
  readonly property string description: {
    if (error !== "") return error
    if (state === "recording")
      return "Recording… " + Math.max(0, secondsRemaining) + " seconds remaining."
    if (state === "stopping") return "Finishing the partial recording…"
    if (state === "ready") return "Private test clip ready. Play it back or discard it."
    if (state === "playing") return "Playing the private test clip through the current output."
    if (microphoneMuted) return "Unmute the microphone before recording a test."
    return "Record five seconds from the current input, then choose when to play it back."
  }
  readonly property string primaryIcon: running ? "󰓛" : (ready ? "󰐊" : "󰑊")
  readonly property string primaryTooltip: state === "stopping" ? "Finishing microphone test"
    : (running ? "Stop and keep microphone test"
    : (ready ? "Play microphone test" : "Record five-second microphone test")
    )

  implicitHeight: content.implicitHeight + Style.space(18)
  bordered: true

  Column {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(7)

    Row {
      width: parent.width
      spacing: Style.space(10)

      Column {
        width: parent.width - actions.width - parent.spacing
        spacing: Style.space(3)

        Text {
          width: parent.width
          text: "Microphone test · " + root.deviceLabel
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: root.description
          color: root.error !== "" ? root.urgent : Qt.darker(root.foreground, 1.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      Row {
        id: actions
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        PanelActionButton {
          iconText: root.primaryIcon
          tooltipText: root.primaryTooltip
          foreground: root.foreground
          fontFamily: root.fontFamily
          bordered: true
          enabled: root.enabled && root.primaryEnabled
          hasCursor: root.hasCursor
          onClicked: root.primaryActivated()
        }

        PanelActionButton {
          visible: root.ready && !root.running
          iconText: "󰆴"
          tooltipText: "Discard microphone test"
          foreground: root.foreground
          hoverColor: root.urgent
          fontFamily: root.fontFamily
          bordered: true
          enabled: root.enabled
          onClicked: root.discarded()
        }
      }
    }

    Rectangle {
      width: parent.width
      height: Math.max(Style.space(5), Style.spacing.xs)
      color: Util.alpha(root.foreground, 0.18)
      opacity: root.microphoneMuted ? 0.35 : 1

      Rectangle {
        height: parent.height
        width: parent.width * Math.max(0, Math.min(1, root.level))
        color: root.level >= 0.98 ? root.urgent : root.foreground
        Behavior on width { NumberAnimation { duration: 70 } }
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    hoverEnabled: true
    onContainsMouseChanged: if (containsMouse) root.hovered()
  }
}
