import QtQuick

// Runs against the real entry points and a private PipeWire graph.
Item {
  id: root
  required property var panel
  required property var advanced
  property bool done: false
  property int phase: 0
  property int ticks: 0
  property var streamRow: null
  property var slider: null
  property var deviceRows: []

  function check(condition, message) {
    if (condition) return true
    console.log("RUNTIME_FAILURE", message)
    Qt.quit()
    return false
  }
  function descendants(item) {
    var found = [], pending = [item]
    while (pending.length) {
      var next = pending.pop()
      if (!next || found.indexOf(next) !== -1) continue
      found.push(next)
      var children = next.data || next.children || []
      for (var i = 0; i < children.length; i++) pending.push(children[i])
      if (next.contentItem) pending.push(next.contentItem)
    }
    return found
  }
  function managedRows() {
    return descendants(advanced).filter(function(item) {
      return item.deviceName !== undefined && item.aliasValue !== undefined
    })
  }
  function level(value) {
    return streamRow && Math.abs(panel.audioNodeVolume(streamRow.node) - value) < .01
  }
  Timer {
    interval: 50; repeat: true; running: !root.done
    onTriggered: {
      if (!root.check(++root.ticks < 300, "volume/tab controls timed out at phase " + root.phase)) return
      if (root.panel.directDeviceMutationBusy || root.advanced.audioControlWritePending) return
      switch (root.phase) {
      case 0:
        if (!root.advanced.managedDevices.length) return
        var restored = root.panel.candidateStreams.find(function(node) { return node.name === "audio_test_playback" })
        if (!restored || !root.panel.mutableAudioNode(restored)
            || Math.abs(root.panel.audioNodeVolume(restored) - 1) > .01) return
        if (!root.check(root.managedRows().length === 0, "unused routing tab created device rows")) return
        root.advanced.newOutputGroupName = "Unfinished group"
        root.advanced.selectTab(4)
        root.panel.open()
        root.phase++
        break
      case 1:
        if (!root.panel.displayAudioStreams.length) return
        root.deviceRows = root.managedRows()
        if (!root.check(root.deviceRows.length === root.advanced.managedDevices.length, "routing tab did not populate")) return
        for (var tab = 0; tab < 6; tab++) root.advanced.selectTab(tab)
        root.advanced.selectTab(4)
        var returned = root.managedRows()
        if (!root.check(returned.length === root.deviceRows.length && returned.every(function(row) {
          return root.deviceRows.indexOf(row) !== -1
        }) && root.advanced.newOutputGroupName === "Unfinished group", "tab return recreated controls or lost draft")) return
        root.streamRow = root.descendants(root.panel).find(function(item) {
          return item.routeSection === "streams" && item.node && item.node.name === "audio_test_playback"
        })
        if (!root.check(!!root.streamRow, "playback row was not created")) return
        root.slider = root.descendants(root.streamRow).find(function(item) {
          return item.maximum !== undefined && typeof item.moved === "function"
        })
        if (!root.check(root.slider && root.slider.maximum === 1, "unboosted slider exceeds 100%")) return
        root.slider.moved(1.2)
        root.phase++
        break
      case 2:
        if (!root.level(1)) return
        root.panel.focusSection = "streams"
        root.panel.selectedIndex = root.streamRow.rowIndex
        root.panel.adjustVolume(.1)
        root.phase++
        break
      case 3:
        if (!root.check(root.level(1), "unboosted keyboard exceeds 100%")) return
        root.advanced.setOutputOverdrive(true)
        root.phase++
        break
      case 4:
        if (!root.panel.outputOverdrive) return
        if (!root.check(root.slider.maximum === 1.5, "boosted slider did not reach 150%")) return
        root.slider.moved(1.2)
        root.phase++
        break
      case 5:
        if (!root.level(1.2)) return
        root.panel.adjustVolume(.5)
        root.phase++
        break
      case 6:
        if (!root.level(1.5)) return
        root.advanced.setOutputOverdrive(false)
        root.phase++
        break
      case 7:
        if (root.panel.outputOverdrive || !root.level(1)) return
        if (!root.check(root.slider.maximum === 1, "disabled boost left the slider extended")) return
        root.panel.close()
        root.advanced.selectTab(0)
        root.done = true
        console.log("RUNTIME_UI_SUCCESS slider, keyboard, boost reset, deferred tabs and retained controls")
      }
    }
  }
}
