import QtQuick
import QtQuick.Window
import QtTest as Test

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
  property string sceneName: ""
  property int sceneCount: 0
  property var policy: null
  property int sliderMoves: 0
  property real lastMoved: -1
  property real lastReleased: -1

  Test.TestCase { id: pointer; name: "AudioPointer"; when: false; optional: true }
  Window { id: pointerWindow; width: 320; height: 100; visible: false }
  Connections {
    target: root.slider
    function onMoved(value) { root.sliderMoves++; root.lastMoved = value }
    function onReleased(value) { root.lastReleased = value }
  }

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
      if (!root.check(++root.ticks < 300, "UI controls timed out at phase " + root.phase)) return
      if (root.panel.directDeviceMutationBusy || root.advanced.audioControlWritePending) return
      switch (root.phase) {
      case 0:
        if (!root.advanced.managedDevices.length || !root.advanced.profilesLoaded) return
        if (!root.check(root.advanced.audioCards.length === 1
            && root.advanced.audioCards[0].activeProfile === "HiFi"
            && root.advanced.audioPorts.length === 2, "native device catalog did not reach the panel")) return
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
        if (root.advanced.sceneMutationBusy) return
        root.sceneName = root.advanced.nextSceneName()
        root.sceneCount = root.advanced.audioScenes.length
        root.advanced.saveCurrentScene()
        root.advanced.saveCurrentScene()
        if (!root.check(root.advanced.sceneMutationBusy, "scene capture did not block a duplicate save")) return
        root.phase++
        break
      case 8:
        if (root.advanced.sceneMutationBusy || root.advanced.audioScenes.length === root.sceneCount) return
        var scenes = root.advanced.audioScenes
        var savedIndex = scenes.findIndex(function(scene) { return scene.name === root.sceneName })
        if (!root.check(scenes.length === root.sceneCount + 1 && savedIndex >= 0
            && !root.advanced.sceneStatusIsError, "scene was not saved exactly once")) return
        if (!root.panel.audioScenes.some(function(scene) { return scene.name === root.sceneName })) return
        root.advanced.deleteSceneAt(savedIndex)
        root.advanced.deleteSceneAt(savedIndex)
        if (!root.check(root.advanced.sceneWritePending, "scene deletion did not guard its pending request")) return
        root.phase++
        break
      case 9:
        if (root.advanced.sceneMutationBusy || root.panel.audioScenes.length !== root.sceneCount) return
        if (!root.check(root.advanced.audioScenes.length === root.sceneCount
            && !root.advanced.sceneStatusIsError, "scene was not deleted from both panels")) return
        // Move the real control into a normal window: the headless compositor
        // does not support the quick panel's layer-shell pointer surface.
        root.slider.parent = pointerWindow.contentItem
        root.slider.x = 20
        root.slider.y = 30
        root.slider.width = 280
        pointerWindow.show()
        root.phase++
        break
      case 10:
        pointer.mousePress(root.slider, root.slider.width * .3, root.slider.height / 2)
        if (!root.check(root.slider.dragging, "pointer press did not start dragging")) return
        root.slider.enabled = false
        pointer.mouseRelease(root.slider, root.slider.width * .4, root.slider.height / 2)
        root.slider.enabled = true
        var moves = root.sliderMoves
        pointer.mouseMove(root.slider, root.slider.width * .7, root.slider.height / 2)
        if (!root.check(!root.slider.dragging && root.sliderMoves === moves,
            "canceled slider follows the mouse after release")) return
        pointer.mousePress(root.slider, root.slider.width * .2, root.slider.height / 2)
        pointer.mouseMove(root.slider, root.slider.width * .6, root.slider.height / 2)
        pointer.mouseRelease(root.slider, root.slider.width * .6, root.slider.height / 2)
        if (!root.check(!root.slider.dragging && Math.abs(root.lastReleased - root.lastMoved) < .001,
            "normal release lost the final slider value")) return
        pointer.mousePress(root.slider, root.slider.width * .3, root.slider.height / 2)
        root.slider.visible = false
        pointer.mouseRelease(pointerWindow.contentItem, 300, 80)
        root.slider.visible = true
        moves = root.sliderMoves
        pointer.mouseMove(root.slider, root.slider.width * .8, root.slider.height / 2)
        if (!root.check(!root.slider.dragging && root.sliderMoves === moves,
            "hidden slider retained its drag after release outside the control")) return
        pointerWindow.hide()
        root.panel.close()
        root.advanced.selectTab(0)
        root.policy = root.descendants(root.advanced).find(function(item) {
          return item.coreDefinitions !== undefined && typeof item.setSetting === "function"
        })
        if (!root.check(root.policy && root.policy.loaded, "policy controller is unavailable")) return
        root.policy.setSetting("node.features.audio.mono", true)
        root.phase++
        break
      case 11:
        if (root.policy.busy || root.policy.settings["node.features.audio.mono"] !== true) return
        if (!root.check(!root.policy.error, "native policy write failed")) return
        root.policy.setSetting("device.routes.default-sink-volume", .5)
        root.phase++
        break
      case 12:
        if (root.policy.busy || Math.abs(root.policy.settings["device.routes.default-sink-volume"]-.5) > .001) return
        root.advanced.setBluetoothAutoSwitch(false)
        root.phase++
        break
      case 13:
        if (root.policy.busy || root.advanced.bluetoothAutoSwitch) return
        root.advanced.setBluetoothProfilePreference("latency")
        root.phase++
        break
      case 14:
        if (root.policy.busy || root.advanced.bluetoothProfilePreference !== "latency") return
        if (!root.check(!root.policy.error, "Bluetooth policy write failed")) return
        if (root.advanced.audioMutationBusy) return
        var port = root.advanced.audioPorts.find(function(p) { return p.direction === "output" })
        if (!root.check(port && port.identity, "port identity did not reach the control")) return
        root.advanced.setAudioPort(port, "[Out] Headphones")
        if (!root.check(root.advanced.portSetPending, "port request did not guard duplicate changes")) return
        root.phase++
        break
      case 15:
        if (root.advanced.audioMutationBusy) return
        if (!root.check(!root.advanced.portSetError, "native port selection failed")) return
        var output = root.advanced.audioPorts.find(function(p) { return p.direction === "output" })
        if (!output || output.activePort !== "[Out] Headphones") return
        root.advanced.setAudioPort(output, "[Out] Speaker")
        root.phase++
        break
      case 16:
        if (root.advanced.audioMutationBusy) return
        var original = root.advanced.audioPorts.find(function(p) { return p.direction === "output" })
        if (!original || original.activePort !== "[Out] Speaker") return
        if (!root.check(!root.advanced.portSetError, "original port was not restored")) return
        root.advanced.setAudioPort(original, "missing-port")
        root.phase++
        break
      case 17:
        if (root.advanced.audioMutationBusy) return
        if (!root.check(!!root.advanced.portSetError && !root.advanced.portSetPending,
            "rejected port selection left the control blocked or hid its error")) return
        root.done = true
        console.log("RUNTIME_UI_SUCCESS volume, tabs, shared scenes, canceled pointer drag, native policies and port selection")
      }
    }
  }
}
