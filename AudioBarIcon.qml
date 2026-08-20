import QtQuick
import qs.Ui
import qs.Commons

Item {
  id: root

  property string outputGlyph: ""
  property int recordingCount: 0
  property bool microphoneMuted: false
  property real iconSize: Style.bar.iconFont
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color badgeBorder: Color.popups.background
  property string fontFamily: Style.font.family

  OpticalGlyph {
    anchors.fill: parent
    text: root.outputGlyph
    fontFamily: root.fontFamily
    fontSize: root.iconSize
    color: root.foreground
  }

  BorderSurface {
    id: badge
    readonly property real badgeHeight: Math.max(Style.space(8), Math.round(root.iconSize * 0.58))
    visible: root.recordingCount > 0
    width: Math.max(badgeHeight, badgeText.implicitWidth + Style.space(3))
    height: badgeHeight
    radius: height / 2
    color: root.urgent
    borderSpec: Border.flat(root.badgeBorder, 1)
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    opacity: root.microphoneMuted ? 0.68 : 1
    scale: visible ? 1 : 0.65

    Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
    Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }

    Text {
      id: badgeText
      anchors.centerIn: parent
      text: root.recordingCount > 9 ? "9+" : String(root.recordingCount)
      color: Color.background
      font.family: root.fontFamily
      font.pixelSize: Math.max(6, Math.round(parent.height * 0.62))
      font.bold: true
      renderType: Text.NativeRendering
    }
  }
}
