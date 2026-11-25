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
      var code = 0
      if (failure) {
        if (failure.outcome === "unknown") code = 4
        else if (failure.code === "group_in_use" || failure.code === "member_unavailable") code = 3
        else code = 1
      }
      root.operationFinished(action, String(result && result.id || params.id || ""),
        !failure, code)
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
