import QtQuick
import QtQuick.Controls
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property string deviceName
  required property string title
  required property bool favorite
  required property bool hidden
  required property bool editingAlias
  required property string aliasValue
  required property bool busy
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family

  signal aliasEditStarted()
  signal aliasCommitted(string text)
  signal favoriteToggled()
  signal hiddenToggled()
  signal cursorRequested()

  readonly property bool interactive: !root.busy

  width: parent ? parent.width : 0
  implicitHeight: prefContent.implicitHeight + Style.space(18)
  bordered: true

  Row {
    id: prefContent
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(10)

    Column {
      width: parent.width - prefActions.width - parent.spacing
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        visible: !root.editingAlias
        text: root.title
        color: root.hidden ? Qt.darker(root.foreground, 1.6) : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        font.strikeout: root.hidden
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: root.deviceName
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      TextField {
        id: aliasField
        visible: root.editingAlias
        width: parent.width
        text: root.aliasValue
        placeholderText: "Custom name"
        color: root.foreground
        placeholderTextColor: Qt.darker(root.foreground, 1.8)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        selectByMouse: true
        background: Rectangle {
          color: "transparent"
          border.width: 1
          border.color: root.hasCursor ? Color.accent : Qt.darker(root.foreground, 1.5)
          radius: Style.space(3)
        }
        onAccepted: root.aliasCommitted(text)
        onActiveFocusChanged: if (!activeFocus && visible) root.aliasCommitted(text)
        Component.onCompleted: if (visible) forceActiveFocus()
        onVisibleChanged: if (visible) forceActiveFocus()
      }
    }

    Row {
      id: prefActions
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      PanelActionButton {
        iconText: "󰏫"
        tooltipText: "Rename device"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.enabled && root.interactive
        onClicked: root.aliasEditStarted()
      }

      PanelActionButton {
        iconText: root.favorite ? "󰓎" : "󰓒"
        tooltipText: root.favorite ? "Remove from favorites" : "Add to favorites"
        foreground: root.favorite ? Color.accent : root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.enabled && root.interactive
        onClicked: root.favoriteToggled()
      }

      PanelActionButton {
        iconText: "󰈉"
        tooltipText: root.hidden ? "Show device" : "Hide device"
        foreground: root.hidden ? root.urgent : root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.enabled && root.interactive
        onClicked: root.hiddenToggled()
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    enabled: !root.editingAlias
    acceptedButtons: Qt.NoButton
    hoverEnabled: true
    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    onContainsMouseChanged: if (containsMouse) root.cursorRequested()
  }

  TapHandler {
    enabled: !root.editingAlias && root.interactive
    onTapped: root.aliasEditStarted()
  }
}
