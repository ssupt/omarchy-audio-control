import QtQuick
import QtQuick.Window
import Quickshell

ShellRoot {
  id: root
  property string pluginRoot: ROOT_URL
  property string server: SERVER_URL
  property var labels: []

  function payload(path) { return '<img src="' + server + '/' + path + '"> Speaker & <b>name</b>' }
  function create(path, parent, properties) {
    var component = Qt.createComponent(pluginRoot + path)
    if (component.status !== Component.Ready) {
      console.error(component.errorString()); Qt.exit(1); return null
    }
    var item = component.createObject(parent, properties)
    if (!item) { console.error("Could not create", path); Qt.exit(1) }
    return item
  }
  function expectLabel(item, text) { labels.push({item: item, text: text}) }
  function containsLabel(item, text) {
    var pending = [item], seen = []
    while (pending.length) {
      var next = pending.pop()
      if (!next || seen.indexOf(next) !== -1) continue
      seen.push(next)
      if (next.textFormat !== undefined && next.text === text) return true
      var children = next.data || next.children || []
      for (var i = 0; i < children.length; i++) pending.push(children[i])
      if (next.contentItem) pending.push(next.contentItem)
    }
    return false
  }

  Window {
    id: window
    width: 900; height: 600; visible: true
    Column {
      id: rows
      width: parent.width
      Text { text: '<img src="' + root.server + '/control">'; textFormat: Text.AutoText }
    }
    Component.onCompleted: {
      var profile = root.create("qml/devices/AudioProfileRow.qml", rows, {
        card: {bluetooth: true, label: root.payload("profile")}, rowIndex: 0,
        currentProfile: "a2dp", options: [{value: "a2dp", label: "A2DP"}], menuEnabled: true
      })
      root.expectLabel(profile, root.payload("profile"))
      var dropdown = root.create("qml/components/AudioDropdown.qml", rows, {
        width: 800, label: root.payload("dropdown-header"), value: "selected",
        options: [{value: "selected", label: root.payload("dropdown-option")}]
      })
      root.expectLabel(dropdown, root.payload("dropdown-header"))
      root.expectLabel(dropdown, root.payload("dropdown-option"))
    }
  }
  Timer {
    interval: 1500; running: true
    onTriggered: {
      if (root.labels.length !== 3) {
        console.error("Themed controls were not created"); Qt.exit(1); return
      }
      for (var i = 0; i < root.labels.length; i++) {
        if (!root.containsLabel(root.labels[i].item, root.labels[i].text)) {
          console.error("Original label was lost", root.labels[i].text); Qt.exit(1); return
        }
      }
      console.log("TEXT_RENDERING_READY"); Qt.quit()
    }
  }
}
