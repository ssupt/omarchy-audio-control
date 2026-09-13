import QtQuick
import qs.Ui
import qs.Commons

Column {
  id: root

  required property var controller
  required property bool tabActive
  required property bool cursorActive
  required property int selectedIndex
  property color foreground: Color.foreground
  property color urgent: Color.urgent
  property color fill: Style.hoverFillFor(foreground, Color.accent)
  property string fontFamily: Style.font.family

  signal cursorRequested(int index)
  signal ensureVisible(var item)
  signal recoveryRequested()

  readonly property var snapshot: controller.snapshot
  readonly property int itemCount: 4
  readonly property var defaultOutput: {
    var values = snapshot.devices || []
    for (var i = 0; i < values.length; i++)
      if (values[i].direction === "output" && values[i].default) return values[i]
    return null
  }

  width: parent ? parent.width : 0
  spacing: Style.space(18)

  function activate(index) {
    if (index === 0) controller.refresh()
    else if (index === 1) controller.toggleSpeakerTest()
    else if (index === 2) controller.copySupportReport()
    else if (index === 3 && snapshot.capabilities.recovery
        && !controller.mutationBlocked && !controller.busy) recoveryRequested()
  }

  function graphDescription() {
    if (!snapshot.graph.available) return "Graph timing is unavailable"
    var details = []
    if (snapshot.graph.rate > 0) details.push(snapshot.graph.rate + " Hz")
    if (snapshot.graph.quantum > 0) details.push(snapshot.graph.quantum + " samples")
    if (snapshot.graph.latencyMs > 0) details.push(snapshot.graph.latencyMs + " ms per cycle")
    if (details.length === 0) return "No graph timing reported"
    return (snapshot.graph.source === "active" ? "Active graph" : "Configured graph")
      + " · " + details.join(" · ")
  }

  function graphLoadDescription() {
    var load = snapshot.graph.loadPercent >= 0
      ? (Math.round(snapshot.graph.loadPercent * 10) / 10) + "% peak DSP load"
      : (snapshot.graph.active ? "DSP load unavailable" : "Graph currently idle")
    return load + " · " + snapshot.graph.errors + " XRUN/error"
      + (snapshot.graph.errors === 1 ? "" : "s")
  }

  function deviceDetails(device) {
    var details = []
    if (device.format) details.push(device.format)
    if (device.channelMap) details.push(device.channelMap)
    if (device.profile) details.push(device.profile)
    if (device.codec) details.push("codec " + device.codec)
    if (device.port) details.push(device.port)
    details.push(device.state || "unknown")
    return details.join(" · ")
  }

  Text {
    width: parent.width
    text: "Inspect the live audio graph without changing it. Support reports omit logs, account details, configuration files, and internal device identifiers."
    color: Qt.darker(root.foreground, 1.35)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.WordWrap
  }

  Column {
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: "SYSTEM HEALTH"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    BorderSurface {
      width: parent.width
      implicitHeight: healthContent.implicitHeight + Style.space(20)
      color: "transparent"
      borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
      radius: Style.cornerRadius

      Column {
        id: healthContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        spacing: Style.space(8)

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: root.controller.refreshing ? "󰔟" : (root.snapshot.healthy ? "󰄬" : "󰀦")
            color: root.snapshot.healthy ? root.foreground : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.iconLarge
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: parent.width - parent.children[0].width - parent.spacing
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: root.controller.refreshing ? "Checking audio services…"
                : (root.snapshot.healthy ? "Audio system is healthy" : "Audio needs attention")
              color: root.snapshot.healthy ? root.foreground : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: "PipeWire " + (root.snapshot.versions.pipewire || "unknown")
                + " · WirePlumber " + (root.snapshot.versions.wireplumber || "unknown")
              color: Qt.darker(root.foreground, 1.35)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Repeater {
          model: root.snapshot.services

          Row {
            required property var modelData
            width: healthContent.width
            spacing: Style.space(7)

            Rectangle {
              width: Style.space(6)
              height: width
              radius: width / 2
              color: modelData.active ? root.foreground : root.urgent
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              width: parent.width - parent.children[0].width - stateText.width - parent.spacing * 2
              text: modelData.label
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              id: stateText
              text: modelData.active ? "running"
                : modelData.activeState + "/" + modelData.subState
              color: modelData.active ? Qt.darker(root.foreground, 1.35) : root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: "PIPEWIRE GRAPH"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    BorderSurface {
      width: parent.width
      implicitHeight: graphContent.implicitHeight + Style.space(20)
      color: "transparent"
      borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
      radius: Style.cornerRadius

      Column {
        id: graphContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        spacing: Style.space(4)

        Text {
          width: parent.width
          text: root.graphDescription()
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: root.graphLoadDescription()
          color: root.snapshot.graph.errors > 0 ? root.urgent : Qt.darker(root.foreground, 1.35)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    Repeater {
      model: root.snapshot.warnings

      Text {
        required property string modelData
        width: parent.width
        text: "󰀦  " + modelData
        color: root.urgent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: "NEGOTIATED DEVICE FORMATS"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Repeater {
      model: root.snapshot.devices

      BorderSurface {
        required property var modelData
        width: parent.width
        implicitHeight: deviceContent.implicitHeight + Style.space(18)
        color: "transparent"
        borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
        radius: Style.cornerRadius

        Column {
          id: deviceContent
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(12)
          spacing: Style.space(3)

          Text {
            width: parent.width
            text: (modelData.direction === "output" ? "󰓃  " : "󰍬  ")
              + modelData.label + (modelData.default ? " · default" : "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: modelData.default
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            text: root.deviceDetails(modelData)
            color: Qt.darker(root.foreground, 1.35)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }

    Text {
      visible: root.controller.loaded && root.snapshot.devices.length === 0
      width: parent.width
      text: "No playback or recording device is currently available."
      color: Qt.darker(root.foreground, 1.35)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: "ACTIVE ROUTES"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Repeater {
      model: root.snapshot.routes

      Text {
        required property var modelData
        width: parent.width
        text: (modelData.direction === "recording" ? "󰍬  " : "󰐊  ")
          + modelData.labels.join("  →  ")
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }
    }

    Text {
      visible: root.controller.loaded && root.snapshot.routes.length === 0
      width: parent.width
      text: root.snapshot.capabilities.topology
        ? "No application audio route is active."
        : "Active route topology is unavailable."
      color: Qt.darker(root.foreground, 1.35)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }

  Column {
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: "DIAGNOSTIC ACTIONS"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    AudioDiagnosticActionRow {
      id: refreshRow
      width: parent.width
      title: "Refresh diagnostics"
      description: root.controller.refreshing ? "Collecting a new read-only snapshot…"
        : "Recheck services, graph statistics, devices, formats, and routes."
      icon: "󰑐"
      busy: root.controller.refreshing
      actionEnabled: !root.controller.copying && !root.controller.speakerTesting
        && !root.controller.recovering
      hasCursor: root.tabActive && root.cursorActive && root.selectedIndex === 0
      foreground: root.foreground
      fill: root.fill
      fontFamily: root.fontFamily
      onHasCursorChanged: if (hasCursor) root.ensureVisible(refreshRow)
      onHovered: root.cursorRequested(0)
      onActivated: root.controller.refresh()
    }

    AudioDiagnosticActionRow {
      id: speakerRow
      width: parent.width
      title: root.controller.speakerTesting ? "Stop speaker test" : "Test speaker channels"
      description: root.controller.speakerTesting
        ? "Channel identification is playing on the default output."
        : (root.snapshot.capabilities.speakerTest
          ? "Identify " + (root.defaultOutput ? root.defaultOutput.channels : 0)
            + " reported channel" + (root.defaultOutput && root.defaultOutput.channels === 1 ? "" : "s")
            + " on " + (root.defaultOutput ? root.defaultOutput.label : "the default output")
            + " at a conservative level."
          : "No testable default output or speaker-test command is available.")
      icon: root.controller.speakerTesting ? "󰓛" : "󰓃"
      actionEnabled: root.controller.speakerTesting
        || (root.snapshot.capabilities.speakerTest
          && !root.controller.mutationBlocked && !root.controller.busy)
      hasCursor: root.tabActive && root.cursorActive && root.selectedIndex === 1
      foreground: root.foreground
      fill: root.fill
      fontFamily: root.fontFamily
      onHasCursorChanged: if (hasCursor) root.ensureVisible(speakerRow)
      onHovered: root.cursorRequested(1)
      onActivated: root.controller.toggleSpeakerTest()
    }

    AudioDiagnosticActionRow {
      id: copyRow
      width: parent.width
      title: "Copy support report"
      description: root.controller.copying ? "Building the report…"
        : (root.snapshot.capabilities.clipboard
          ? "Copy a sanitized snapshot suitable for an issue report."
          : "A Wayland clipboard command is not available.")
      icon: "󰆏"
      busy: root.controller.copying
      actionEnabled: root.snapshot.capabilities.supportReport
        && root.snapshot.capabilities.clipboard && !root.controller.refreshing
        && !root.controller.speakerTesting && !root.controller.recovering
      hasCursor: root.tabActive && root.cursorActive && root.selectedIndex === 2
      foreground: root.foreground
      fill: root.fill
      fontFamily: root.fontFamily
      onHasCursorChanged: if (hasCursor) root.ensureVisible(copyRow)
      onHovered: root.cursorRequested(2)
      onActivated: root.controller.copySupportReport()
    }

    AudioDiagnosticActionRow {
      id: recoveryRow
      width: parent.width
      title: "Run Omarchy audio recovery"
      description: root.snapshot.capabilities.recovery
        ? "After confirmation, open omarchy-restart-audio in a visible terminal. Audio will be interrupted."
        : "Omarchy's recovery command or terminal launcher is not available."
      icon: "󰑓"
      actionEnabled: root.snapshot.capabilities.recovery
        && !root.controller.mutationBlocked && !root.controller.busy
      urgentAction: true
      hasCursor: root.tabActive && root.cursorActive && root.selectedIndex === 3
      foreground: root.foreground
      fill: root.fill
      urgent: root.urgent
      fontFamily: root.fontFamily
      onHasCursorChanged: if (hasCursor) root.ensureVisible(recoveryRow)
      onHovered: root.cursorRequested(3)
      onActivated: root.recoveryRequested()
    }

    Text {
      visible: root.controller.error !== "" || root.controller.status !== ""
      width: parent.width
      text: root.controller.error !== "" ? root.controller.error : root.controller.status
      color: root.controller.error !== "" || root.controller.statusIsError
        ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }
  }
}
