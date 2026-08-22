import QtQuick
import qs.Ui
import qs.Commons

CursorSurface {
  id: root

  required property string preference
  required property bool menuEnabled
  property string fontFamily: Style.font.family

  signal cursorRequested()
  signal preferenceSelected(string value)
  signal menuToggled(bool open)

  width: parent ? parent.width : 0
  implicitHeight: Math.max(preferenceLabels.implicitHeight, preferenceDropdown.implicitHeight) + Style.space(18)
  bordered: true

  function togglePreferenceMenu() { if (preferenceDropdown.enabled) preferenceDropdown.toggle() }
  function closePreferenceMenu() { preferenceDropdown.close() }

  Row {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(12)
    anchors.rightMargin: Style.space(12)
    spacing: Style.space(16)

    Column {
      id: preferenceLabels
      width: Math.max(Style.space(180), parent.width * 0.4)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(3)

      Text {
        width: parent.width
        text: "Profile preference"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: "Automatic profile selection"
        color: Qt.darker(root.foreground, 1.35)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    AudioDropdown {
      id: preferenceDropdown
      width: parent.width - preferenceLabels.width - parent.spacing
      showLabel: false
      popupDirection: "down"
      value: root.preference
      options: [
        { value: "quality", label: "Prefer quality" },
        { value: "latency", label: "Prefer lower latency" }
      ]
      hasCursor: root.hasCursor
      enabled: root.menuEnabled
      opacity: enabled ? 1 : 0.6
      foreground: root.foreground
      fontFamily: root.fontFamily
      anchors.verticalCenter: parent.verticalCenter

      onHovered: function(on) { if (on) root.cursorRequested() }
      onChanged: function(value) { root.preferenceSelected(value) }
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
