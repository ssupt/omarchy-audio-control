import QtQuick

// Transitional view adapter for the existing guarded helper domains. Every
// operation is owned by Rust; destroying a view cannot interrupt a transaction.
Item {
  id: root
  property var service: null
  property var command: []
  property bool running: false
  property AudioReply stdout: null
  property bool initialized: false
  property bool active: false
  signal exited(int exitCode)

  function start() {
    if (!initialized || !running || active) return
    active = true
    if (!service || !service.ready || command.length < 2) {
      Qt.callLater(function() { root.finish(null, { outcome: "rejected" }) })
      return
    }
    var path = String(command[1] || "")
    var helper = path.substring(path.lastIndexOf("/") + 1)
    service.request("adapter.run", { helper: helper, args: command.slice(2), generation: String(service.state.generation || "") },
      function(result, error) { root.finish(result, error) })
  }
  function finish(result, error) {
    active = false
    running = false
    if (stdout) {
      stdout.text = result ? String(result.stdout || "") : ""
      stdout.streamFinished()
    }
    exited(error ? (error.outcome === "unknown" ? 4 : 1) : Number(result.exitCode))
  }
  onRunningChanged: {
    if (active && !running) running = true
    else if (running) start()
  }
  Component.onCompleted: { initialized = true; start() }
}
