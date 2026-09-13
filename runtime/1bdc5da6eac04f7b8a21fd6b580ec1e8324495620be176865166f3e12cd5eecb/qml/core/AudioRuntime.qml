import QtQuick
import "ReleasePaths.js" as ReleasePaths

// Resolve packaged helpers for both panels.
QtObject {
  readonly property string scriptsDir: localPath(Qt.resolvedUrl(ReleasePaths.root + "scripts/")).replace(/\/$/, "")

  function localPath(url) {
    return decodeURIComponent(String(url).replace(/^file:\/\//, ""))
  }

  function script(name) {
    return scriptsDir + "/" + String(name || "")
  }

  function scriptCommand(name, args) {
    return ["/bin/bash", script(name)].concat(args || [])
  }
}
