import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property var port
  required property int rowIndex
  required property bool menuEnabled
  property string fontFamily: Style.font.family

  signal cursorRequested()
  signal portSelected(string value)
  signal menuToggled(bool open)

  width: parent ? parent.width : 0
  implicitHeight: Math.max(portLabels.implicitHeight, portDropdown.implicitHeight) + Style.space(18)
  bordered: true

  function togglePortMenu() { if (portDropdown.enabled) portDropdown.toggle() }
  function closePortMenu() { portDropdown.close() }

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(16)

    Column {
      id: portLabels
      width: Math.max(Style.space(180), parent.width * 0.4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: root.port.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: root.port.direction === "output" ? "Output port" : "Input port"
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    AudioDropdown {
      id: portDropdown
      width: parent.width - portLabels.width - parent.spacing
      showLabel: false
      popupDirection: "down"
      value: String(root.port.activePort || "")
      options: root.port.ports
      hasCursor: root.hasCursor
      enabled: root.menuEnabled
      opacity: enabled ? 1 : 0.6
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.verticalCenter: parent.verticalCenter

      onHovered: function(on) { if (on) root.cursorRequested() }
      onChanged: function(value) { root.portSelected(value) }
      onPopupOpenChanged: root.menuToggled(popupOpen)
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.NoButton
    hoverEnabled: true
    onContainsMouseChanged: if (containsMouse) root.cursorRequested()
  }
}
