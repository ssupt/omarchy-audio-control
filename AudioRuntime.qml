import QtQuick
import Quickshell

// Shared filesystem contract for both plugin entry points and their domain
// controllers. Keeping it here prevents new tabs from inventing another copy
// of the XDG fallback or URL-to-path conversion.
QtObject {
  id: root

  readonly property string configHome: {
    var configured = Quickshell.env("XDG_CONFIG_HOME")
    return configured || Quickshell.env("HOME") + "/.config"
  }
  readonly property string settingsPath: configHome + "/omarchy/audio-control.json"
  readonly property string preferencesPath: configHome + "/omarchy/audio-preferences.json"
  readonly property string scenesPath: configHome + "/omarchy/audio-scenes.json"
  readonly property string rulesPath: configHome + "/omarchy/audio-rules.json"
  readonly property string scriptsDir: localPath(Qt.resolvedUrl("scripts/"))

  function localPath(url) {
    return decodeURIComponent(String(url).replace(/^file:\/\//, ""))
  }

  function script(name) {
    return scriptsDir + "/" + String(name || "")
  }
}
