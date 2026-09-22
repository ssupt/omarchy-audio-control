import QtQuick

Item {
  id: root
  property var service: null
  property string error: ""
  property bool busy: false
  readonly property bool mutating: busy

  signal operationFinished(string action, string groupId, bool success, int exitCode)

  function run(action, params) {
    if (busy || !service || !service.ready) return false
    error = ""
    busy = true
    params.generation = String(service.state.generation || "")
    service.request("groups." + action, params, function(result, failure) {
      root.busy = false
      root.error = failure ? failure.message : ""
      root.operationFinished(action, String(result && result.id || params.id || ""),
        !failure, failure ? (failure.outcome === "unknown" ? 4 : 3) : 0)
    }, { mutating: true, timeout: 35000 })
    return true
  }

  function createGroup(name, members) {
    return run("create", { name: String(name || ""), members: members || [] })
  }

  function updateGroup(groupId, name, members) {
    return run("update", { id: String(groupId || ""), name: String(name || ""), members: members || [] })
  }

  function deleteGroup(groupId) {
    return run("delete", { id: String(groupId || "") })
  }
}
