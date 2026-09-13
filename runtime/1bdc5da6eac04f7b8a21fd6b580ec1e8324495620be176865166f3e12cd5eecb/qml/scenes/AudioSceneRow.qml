import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property string sceneName
  required property string summary
  required property bool actionEnabled
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal activated()
  signal deleted()
  signal hovered()

  readonly property string description: actionEnabled
    ? (summary !== "" ? summary : "Apply this scene to every saved device.")
    : "Finishing the current scene operation…"

  implicitHeight: content.implicitHeight + Style.space(18)
  bordered: true

  // Declared beneath the content so the action buttons stay clickable;
  // clicks landing anywhere else on the row still apply the scene.
  MouseArea {
    anchors.fill: parent
    enabled: root.actionEnabled
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onContainsMouseChanged: if (containsMouse) root.hovered()
    onClicked: root.activated()
  }

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(10)

    Column {
      width: parent.width - actions.width - parent.spacing
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: root.sceneName
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: root.description
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Row {
      id: actions
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      PanelActionButton {
        iconText: "󰆴"
        tooltipText: "Delete scene"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.enabled && root.actionEnabled
        onClicked: root.deleted()
      }

      PanelActionButton {
        iconText: "󰐊"
        tooltipText: "Apply scene"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.enabled && root.actionEnabled
        onClicked: root.activated()
      }
    }
  }
}
