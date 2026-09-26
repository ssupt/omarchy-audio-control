import QtQuick
import "Model.js" as Model

// Keep delegates alive when another node appears, disappears or moves.
// Model roles contain strings; native QObjects stay outside the item model.
ListModel {
  id: root
  property var nodes: []
  property string generation: ""
  property var objects: ({})

  onNodesChanged: synchronize()
  onGenerationChanged: synchronize()

  function nodeForKey(key) {
    return Model.mapValue(objects, key, null)
  }

  function synchronize() {
    var next = {}, keys = []
    for (var i = 0; i < nodes.length && i < 4096; i++) {
      var node = nodes[i]
      var id = Model.nodeObjectId(node)
      if (id === "") continue
      var key = generation + ":" + id + ":" + Model.nodeSerial(node)
      if (Model.hasOwn(next, key)) continue
      next[key] = node
      keys.push(key)
    }
    var changed = Object.keys(objects).length !== keys.length
    for (var k = 0; !changed && k < keys.length; k++)
      changed = Model.mapValue(objects, keys[k], null) !== next[keys[k]]
    if (changed) objects = next

    for (var row = 0; row < keys.length; row++) {
      if (row < count && get(row).nodeKey === keys[row]) continue
      var found = -1
      for (var later = row + 1; later < count; later++) {
        if (get(later).nodeKey === keys[row]) { found = later; break }
      }
      if (found >= 0) move(found, row, 1)
      else insert(row, {nodeKey: keys[row]})
    }
    if (count > keys.length) remove(keys.length, count - keys.length)
  }
}
