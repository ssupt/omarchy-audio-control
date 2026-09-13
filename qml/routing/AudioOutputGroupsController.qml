import QtQuick
import Quickshell.Io
import "../core"

// Owns only the lifecycle edge around PipeWire's virtual combine sinks. Group
// definitions remain in AudioRulesController, while every existing routing
// path continues to treat a live group as an ordinary output node.
Item {
  id: root
  property var service: null

  required property string scriptPath
  property string error: ""
  readonly property bool busy: groupProc.running
  readonly property bool mutating: busy && groupProc.action !== "reconcile"

  signal operationFinished(string action, string groupId, bool success, int exitCode)


  function run(action, args, groupId) {
    if (busy) return false
    error = ""
    groupProc.action = action
    groupProc.groupId = String(groupId || "")
    groupProc.command = ["/bin/bash", scriptPath, action].concat(args || [])
    groupProc.running = true
    return true
  }

  function createGroup(name, members) {
    return run("create", [String(name || ""), JSON.stringify(members || [])], "")
  }

  function updateGroup(groupId, name, members) {
    return run("update", [String(groupId || ""), String(name || ""),
      JSON.stringify(members || [])], groupId)
  }

  function deleteGroup(groupId) {
    return run("delete", [String(groupId || "")], groupId)
  }

  AudioCommand {
    service: root.service
    id: groupProc
    property string action: ""
    property string groupId: ""

    onExited: function(exitCode) {
      var completedAction = action
      var completedId = groupId
      var success = exitCode === 0
      if (success) root.error = ""
      else if (completedAction === "reconcile")
        root.error = "Some output groups could not be restored"
      else if (exitCode === 3)
        root.error = "That output group is unavailable or still in use"
      else if (exitCode === 4)
        root.error = "The output group changed and could not be fully restored"
      else
        root.error = "Could not update the output group"

      action = ""
      groupId = ""
      root.operationFinished(completedAction, completedId, success, exitCode)

    }
  }
}
