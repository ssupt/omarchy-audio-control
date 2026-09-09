import QtQuick
import Quickshell

// Shared filesystem contract for both plugin entry points and their domain
// controllers. Keeping it here prevents new tabs from inventing another copy
// of the XDG fallback or URL-to-path conversion.
QtObject {
  id: root

  readonly property string configHome: {
    var configured = Quickshell.env("XDG_CONFIG_HOME")
    var home = Quickshell.env("HOME")
    return configured || (home ? home + "/.config" : "")
  }
  readonly property string settingsPath: configPath("audio-control.json")
  readonly property string preferencesPath: configPath("audio-preferences.json")
  readonly property string scenesPath: configPath("audio-scenes.json")
  readonly property string rulesPath: configPath("audio-rules.json")
  readonly property string scriptsDir: localPath(Qt.resolvedUrl("../../scripts/")).replace(/\/$/, "")

  function localPath(url) {
    return decodeURIComponent(String(url).replace(/^file:\/\//, ""))
  }

  function script(name) {
    return scriptsDir + "/" + String(name || "")
  }

  function configPath(name) {
    return configHome === "" ? "" : configHome + "/omarchy/" + name
  }

  function scriptCommand(name, args) {
    return ["/bin/bash", script(name)].concat(args || [])
  }
}
