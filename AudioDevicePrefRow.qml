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
  signal aliasCancelled()
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
        id: titleText
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
        id: deviceCodeText
        width: parent.width
        visible: !root.editingAlias
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
        // Occupy the title and device-code slots together so the outer
        // rectangle keeps its size while renaming.
        implicitHeight: titleText.implicitHeight + Style.space(3)
          + deviceCodeText.implicitHeight
        text: root.aliasValue
        placeholderText: "Custom name"
        color: root.foreground
        placeholderTextColor: Qt.darker(root.foreground, 1.8)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        selectByMouse: true
        verticalAlignment: TextInput.AlignVCenter
        background: Rectangle {
          color: "transparent"
          border.width: 1
          border.color: Color.accent
          radius: Style.space(3)
        }
        onVisibleChanged: {
          if (!visible) return
          text = root.aliasValue
          forceActiveFocus()
          selectAll()
        }
        onAccepted: root.aliasCommitted(text)
        Keys.onEscapePressed: root.aliasCancelled()
      }
    }

    Row {
      id: prefActions
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      // While renaming, only the actions that belong to the edit remain.
      PanelActionButton {
        visible: root.editingAlias
        iconText: "󰄬"
        tooltipText: "Save name"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.enabled
        onClicked: root.aliasCommitted(aliasField.text)
      }

      PanelActionButton {
        visible: root.editingAlias
        iconText: "󰅖"
        tooltipText: "Cancel renaming"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.enabled
        onClicked: root.aliasCancelled()
      }

      PanelActionButton {
        visible: !root.editingAlias
        iconText: "󰏫"
        tooltipText: "Rename device"
        foreground: root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.enabled && root.interactive
        onClicked: root.aliasEditStarted()
      }

      PanelActionButton {
        visible: !root.editingAlias
        iconText: root.favorite ? "󰓎" : "󰓒"
        tooltipText: root.favorite ? "Remove from favorites" : "Add to favorites"
        foreground: root.favorite ? Color.accent : root.foreground
        fontFamily: root.fontFamily
        bordered: true
        enabled: root.enabled && root.interactive
        onClicked: root.favoriteToggled()
      }

      PanelActionButton {
        visible: !root.editingAlias
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
