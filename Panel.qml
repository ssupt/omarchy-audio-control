import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "omarchy.audio"
  ipcTarget: "omarchy.audio"

  function pluginScript(name) {
    var url = String(Qt.resolvedUrl("scripts/" + name))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var appLibrary: bar && bar.shell ? bar.shell.appLibrary : null
  readonly property var mediaService: bar && bar.shell
    ? bar.shell.firstPartyServiceFor("omarchy.media") : null
  readonly property var activeMediaPlayer: mediaService ? mediaService.activePlayer : null
  readonly property string settingsPath: {
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome) configHome = Quickshell.env("HOME") + "/.config"
    return configHome + "/omarchy/audio-control.json"
  }
  readonly property string audioPreferencesPath: {
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome) configHome = Quickshell.env("HOME") + "/.config"
    return configHome + "/omarchy/audio-preferences.json"
  }
  readonly property string scenesPath: {
    var configHome = Quickshell.env("XDG_CONFIG_HOME")
    if (!configHome) configHome = Quickshell.env("HOME") + "/.config"
    return configHome + "/omarchy/audio-scenes.json"
  }
  readonly property string scriptsDir: {
    var url = String(Qt.resolvedUrl("scripts/"))
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }
  property var audioPreferences: Model.parseAudioPreferences("")
  property bool outputOverdrive: false
  property bool captureNotifications: true
  property bool notificationsAvailable: false
  property var audioScenes: []
  property bool scenesLoaded: false
  property string sceneFeedback: ""
  property bool sceneFeedbackIsError: false
  property var observedRecordingLabels: []
  property bool recordingObservationReady: false
  property real inputPeakHold: 0
  property bool inputClipping: false
  readonly property real outputVolumeMaximum: outputOverdrive ? 1.5 : 1.0

  readonly property var candidateSinks: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream) list.push(n)
    }
    return list
  }

  readonly property var candidateSources: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && !n.isSink && !n.isStream && isAudioSource(n)) {
        var name = String(n.name || "").toLowerCase()
        if (name === "quickshell") continue
        list.push(n)
      }
    }
    return list
  }

  readonly property var candidateStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !n.isStream || !isPlaybackStream(n)) continue
      // A tuning's output is a playback stream too, but it is the processing
      // itself rather than an application, so it does not belong in the list.
      var nodeName = String(n.name || "")
      if (nodeName.indexOf("omarchy_speaker_tuning") === 0
          || nodeName.indexOf("omarchy_audio_test") === 0) continue
      list.push(n)
    }
    return list
  }

  readonly property var candidateRecordingStreams: {
    var list = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || !isRecordingStream(n)) continue
      // The microphone peak meter creates its own capture stream while this
      // panel is open; it is instrumentation, not a recording application.
      var nodeName = String(n.name || "").toLowerCase()
      if (nodeName === "quickshell" || nodeName.indexOf("omarchy_audio_test") === 0) continue
      list.push(n)
    }
    return list
  }

  property var sinkAvailability: ({})
  property bool sinkAvailabilityLoaded: false

  // Identify true playback streams without reading node.properties here:
  // PwNode.properties is invalid until the node is bound, and reading it while
  // capture streams are appearing (for example, when Voxtype starts recording)
  // can destabilize Quickshell's Pipewire service. Quickshell versions differ
  // in how `type` is exposed (media.class, enum name, or numeric enum), but
  // playback streams consistently accept audio input from clients and publish
  // `isSink: true`; capture streams publish as stream sources.
  function isPlaybackStream(node) {
    return Model.isPlaybackStream(node)
  }

  function isRecordingStream(node) {
    return Model.isRecordingStream(node)
  }

  function isAudioSource(node) {
    return Model.isAudioSource(node)
  }

  function loadAudioPreferences(raw) {
    audioPreferences = Model.parseAudioPreferences(raw)
  }

  function observeRecordingApplications() {
    var current = listSnapshot(activeRecordingLabels)
    var additions = Model.addedRecordingStreamLabels(observedRecordingLabels, current)
    observedRecordingLabels = current
    if (!captureNotifications || additions.length === 0 || !notificationsAvailable) return

    var summary = "Microphone access started"
    var body = additions.length === 1
      ? additions[0] + " is now using the microphone."
      : additions.length + " applications started using the microphone: " + additions.join(", ")
    Quickshell.execDetached([
      "notify-send",
      "--app-name", "Advanced Audio Control",
      "--icon", "audio-input-microphone-symbolic",
      "--urgency", "normal",
      "--expire-time", "8000",
      summary,
      body
    ])
  }

  property var cachedAudioSinks: []
  property var cachedAudioSources: []

  readonly property var rawAudioSinks: {
    var list = []
    for (var i = 0; i < candidateSinks.length; i++)
      if (sinkAvailable(candidateSinks[i])) list.push(candidateSinks[i])
    if (sink && list.indexOf(sink) < 0) list.unshift(sink)
    return list
  }

  readonly property var rawAudioSources: {
    var list = candidateSources.slice()
    if (source && list.indexOf(source) < 0) list.unshift(source)
    return list
  }

  readonly property var audioSinks: rawAudioSinks.length > 0 ? rawAudioSinks : cachedAudioSinks
  readonly property var audioSources: rawAudioSources.length > 0 ? rawAudioSources : cachedAudioSources
  readonly property string preferredOutputName: Model.preferredAudioNodeName(
    audioPreferences, "output", sink, audioSinks)
  readonly property string preferredInputName: Model.preferredAudioNodeName(
    audioPreferences, "input", source, audioSources)

  readonly property var audioStreams: {
    var list = []
    for (var i = 0; i < candidateStreams.length; i++)
      if (candidateStreams[i].audio) list.push(candidateStreams[i])
    return list
  }

  readonly property var recordingStreams: {
    var list = []
    for (var i = 0; i < candidateRecordingStreams.length; i++)
      if (candidateRecordingStreams[i].audio) list.push(candidateRecordingStreams[i])
    return list
  }

  readonly property var activeRecordingLabels: Model.uniqueRecordingStreamLabels(recordingStreams)
  readonly property int recordingApplicationCount: activeRecordingLabels.length
  readonly property real inputPeakLevel: inputMuted
    ? 0 : Math.max(0, Math.min(1, Number(inputPeakMonitor.peak || 0)))
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string recordingTooltip: {
    var microphoneAction = hasInput
      ? "Middle-click to " + (inputMuted ? "unmute" : "mute") + " microphone"
      : ""
    if (recordingApplicationCount === 0) {
      var outputStatus = outputMuted ? "Output muted" : "Output " + Math.round(outputVolume * 100) + "%"
      return microphoneAction === "" ? outputStatus : outputStatus + "\n" + microphoneAction
    }

    var access = recordingApplicationCount === 1
      ? "Microphone access · " + activeRecordingLabels[0]
      : "Microphone access by " + recordingApplicationCount + " apps\n"
        + activeRecordingLabels.join(", ")
    var state = inputMuted ? "Microphone muted"
      : (inputClipping ? "Microphone clipping" : "Microphone in use")
    return access + "\n" + state + (microphoneAction === "" ? "" : " · " + microphoneAction)
  }
  onActiveRecordingLabelsChanged: {
    if (recordingObservationReady) recordingChangeTimer.restart()
    else observedRecordingLabels = listSnapshot(activeRecordingLabels)
  }
  onInputPeakLevelChanged: {
    if (inputPeakLevel > inputPeakHold) {
      inputPeakHold = inputPeakLevel
      inputPeakHoldTimer.restart()
    }
    if (inputPeakLevel >= 0.98) {
      inputClipping = true
      inputClippingTimer.restart()
    }
  }
  onInputMutedChanged: if (inputMuted) {
    inputPeakHold = 0
    inputClipping = false
  }

  // Feed Repeaters with panel-local snapshots instead of the live PipeWire
  // model. PipeWire can remove nodes while Quickshell is dispatching the
  // removal signal; rebuilding a Repeater from that signal path has crashed
  // in Quickshell's PipeWire service. The snapshot timer lets that mutation
  // settle first, and closed panels keep their repeaters detached entirely.
  property var displayAudioSinks: []
  property var displayAudioSources: []
  property var displayAudioStreams: []
  property var displayRecordingStreams: []

  // Per-application routing is separate from the preferred default sink.
  // WirePlumber persists explicit targets by application identity and restores
  // them when a stream is recreated; returning to the default option clears
  // that target. pactl and Quickshell expose the same PipeWire object.serial
  // values, so this live-state map remains exact even when several applications
  // share a display name.
  property var streamRoutes: ({})
  property var recordingStreamRoutes: ({})
  property bool streamOutputMenuOpen: false
  property string streamRouteReadError: ""
  property string streamRouteSetError: ""
  readonly property string streamRouteError: streamRouteSetError !== ""
    ? streamRouteSetError : streamRouteReadError
  property string defaultOutputError: ""
  property string defaultInputError: ""
  property var previousDefaultSink: null
  property var previousDefaultSource: null
  readonly property string defaultDeviceError: defaultOutputError !== ""
    ? defaultOutputError : defaultInputError
  readonly property string panelError: defaultDeviceError !== ""
    ? defaultDeviceError : streamRouteError
  property var pendingStreamRoute: null

  // The default is ordered first and named by behavior. Applications on that
  // option follow later default changes; all other choices are persistent.
  readonly property var streamOutputOptions: Model.streamOutputOptions(displayAudioSinks, sink)
  readonly property var recordingInputOptions: Model.recordingInputOptions(displayAudioSources, source)

  // A DSP sink -- a speaker tuning, or EasyEffects -- can be the selected output
  // without being where loudness lives: changing its volume alters the level going
  // *into* the processing, so the slider would move while the speakers did not,
  // and on a chain with a limiter it would change the tone as well.
  //
  // omarchy-audio-output-sink resolves the *current* default output through any
  // such sink to the physical one, which is the same definition the volume keys
  // and the output switcher use. Resolving the default (rather than "whatever a
  // tuning fronts") is what keeps this correct when headphones or HDMI are
  // selected while a tuning still exists.
  property string volumeSinkName: ""

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  readonly property var volumeSink: {
    if (volumeSinkName === "" || !sink) return sink
    if (volumeSinkName === String(sink.name)) return sink
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === volumeSinkName && n.audio)
        return n
    }
    return sink
  }
  onVolumeSinkChanged: enforceOutputVolumeLimit()

  // Re-resolve whenever the selected output changes; the timer below is only a
  // safety net for the tuning being applied or removed underneath us.
  onSinkChanged: resolveVolumeSink()

  function resolveVolumeSink() {
    if (!volumeSinkProc.running) volumeSinkProc.running = true
  }

  readonly property real outputVolume: volumeSink && volumeSink.audio ? volumeSink.audio.volume : 0
  readonly property bool outputMuted: volumeSink && volumeSink.audio ? volumeSink.audio.muted : false
  readonly property real inputVolume: source && source.audio ? source.audio.volume : 0
  readonly property bool inputMuted: source && source.audio ? source.audio.muted : false

  onRawAudioSinksChanged: if (rawAudioSinks.length > 0) cachedAudioSinks = rawAudioSinks
  onRawAudioSourcesChanged: if (rawAudioSources.length > 0) cachedAudioSources = rawAudioSources

  // Single cursor model shared by keyboard and mouse. Sections:
  //   "scenes"  — saved scene chips (apply on activation)
  //   "output"  — output slider + sink device list
  //   "input"   — input slider + source device list
  //   "streams"   — per-app playback streams
  //   "recording" — per-app recording streams
  // selectedIndex semantics within a section:
  //   -1            → on the slider row (h/l adjusts volume, m/Enter mute)
  //   0..N-1        → on the Nth device/stream row
  // Visuals derive from hasCursor/current via CursorSurface, never
  // from containsMouse — that's what keeps the highlight unique across
  // keyboard + mouse like wifi does.
  property string focusSection: "output"
  property int selectedIndex: -1
  property bool cursorActive: false
  property int headerIndex: 1

  // "header" is a virtual horizontal section for advanced settings + mute.
  readonly property bool settingsHeaderHasCursor: cursorActive && focusSection === "header" && headerIndex === 0
  readonly property bool powerHeaderHasCursor: cursorActive && focusSection === "header" && headerIndex === 1
  // Only channels that actually exist get a vote. A box with no default source
  // would otherwise report "input unmuted" forever, leaving the hero switch
  // able to mute but never to unmute.
  readonly property bool hasOutput: !!(volumeSink && volumeSink.audio)
  readonly property bool hasInput: !!(source && source.audio)
  readonly property bool anyAudible: (hasOutput && !outputMuted) || (hasInput && !inputMuted)
  readonly property string toggleHint: anyAudible ? "Mute" : "Unmute"

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : "transparent"

  function sectionCount(section) {
    if (section === "scenes") return audioScenes.length
    if (section === "output") return displayAudioSinks.length
    if (section === "input") return displayAudioSources.length
    if (section === "streams") return displayAudioStreams.length
    if (section === "recording") return displayRecordingStreams.length
    return 0
  }

  function sectionVisible(section) {
    if (section === "scenes") return audioScenes.length > 0
    if (section === "output") return true
    if (section === "input") return displayAudioSources.length > 0 || !!source
    if (section === "streams") return displayAudioStreams.length > 0
    if (section === "recording") return displayRecordingStreams.length > 0
    return false
  }

  function sectionHasSlider(section) {
    if (section === "output") return true
    if (section === "input") return !!source
    return false  // stream rows carry their own sliders inline; not a section-level slider
  }

  // Order of visible sections, recomputed reactively so dropping a section
  // (e.g. no input devices) doesn't leave the cursor pointing at it.
  readonly property var visibleSections: {
    var list = []
    if (sectionVisible("scenes")) list.push("scenes")
    if (sectionVisible("output")) list.push("output")
    if (sectionVisible("input")) list.push("input")
    if (sectionVisible("streams")) list.push("streams")
    if (sectionVisible("recording")) list.push("recording")
    return list
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (sections.length === 0) return
    if (focusSection === "header") {
      if (delta > 0) { focusSection = sections[0]; selectedIndex = sectionHasSlider(sections[0]) ? -1 : 0 }
      return
    }
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) { focusSection = sections[0]; selectedIndex = sectionHasSlider(focusSection) ? -1 : 0; return }

    var idx = selectedIndex
    var max = sectionCount(focusSection) - 1  // last device index
    var hasSlider = sectionHasSlider(focusSection)
    var floor = hasSlider ? -1 : 0  // -1 = slider row

    if (delta > 0) {
      if (idx < max) { selectedIndex = idx + 1; return }
      // Fall through to next section.
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
      }
    } else {
      if (idx > floor) { selectedIndex = idx - 1; return }
      // Escape upward.
      if (sIdx > 0) {
        focusSection = sections[sIdx - 1]
        var prevMax = sectionCount(focusSection) - 1
        selectedIndex = prevMax >= 0 ? prevMax : (sectionHasSlider(focusSection) ? -1 : 0)
      } else {
        focusSection = "header"
      }
    }
  }

  function setHeaderCursor(index) {
    cursorActive = true
    focusSection = "header"
    headerIndex = Math.max(0, Math.min(1, index))
    selectedIndex = -1
  }

  function adjustCursorHorizontal(delta) {
    if (focusSection === "header") {
      headerIndex = Math.max(0, Math.min(1, headerIndex + delta))
      return
    }
    adjustVolume(delta * 0.05)
  }

  function moveSection(delta) {
    var sections = visibleSections
    if (sections.length === 0) return
    var current = sections.indexOf(focusSection)
    if (current < 0) current = delta > 0 ? -1 : 0
    var next = (current + delta + sections.length) % sections.length
    focusSection = sections[next]
    selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
    cursorActive = true
  }

  // Adjust the slider associated with the focused section. Output and
  // input sliders are real volume controls; on stream rows h/l adjusts
  // that stream's volume (so keyboard parity with the inline slider).
  // For device rows (selectedIndex >= 0 in output/input) h/l is a no-op
  // — the cursor is on a discrete row, not on the slider, and silently
  // moving the global slider would surprise the user.
  function adjustVolume(delta) {
    if (focusSection === "output" && selectedIndex === -1) {
      setOutputVolume(outputVolume + delta)
      return
    }
    if (focusSection === "input" && selectedIndex === -1) {
      setInputVolume(inputVolume + delta)
      return
    }
    if (focusSection === "streams" && selectedIndex >= 0 && selectedIndex < displayAudioStreams.length) {
      var s = displayAudioStreams[selectedIndex]
      if (s && s.audio) s.audio.volume = Math.max(0, Math.min(1.5, s.audio.volume + delta))
      return
    }
    if (focusSection === "recording" && selectedIndex >= 0 && selectedIndex < displayRecordingStreams.length) {
      var recording = displayRecordingStreams[selectedIndex]
      if (recording && recording.audio)
        recording.audio.volume = Math.max(0, Math.min(1.5, recording.audio.volume + delta))
    }
  }

  // Enter/Space: activate whatever the cursor is on.
  function activateCursor() {
    if (focusSection === "header") {
      if (headerIndex === 0) openAdvancedAudio()
      else toggleAllMuted()
      return
    }
    if (focusSection === "scenes") {
      applySceneAt(selectedIndex)
      return
    }
    if (focusSection === "output") {
      if (selectedIndex === -1) { toggleOutputMute(); return }
      var sink = displayAudioSinks[selectedIndex]
      if (sink) setDefaultSink(sink)
      return
    }
    if (focusSection === "input") {
      if (selectedIndex === -1) { toggleInputMute(); return }
      var src = displayAudioSources[selectedIndex]
      if (src) setDefaultSource(src)
      return
    }
    if (focusSection === "streams" && selectedIndex >= 0) {
      var row = streamRepeater.itemAt(selectedIndex)
      if (row && displayAudioSinks.length > 1) row.toggleOutputMenu()
      else {
        var st = displayAudioStreams[selectedIndex]
        if (st && st.audio) st.audio.muted = !st.audio.muted
      }
      return
    }
    if (focusSection === "recording" && selectedIndex >= 0) {
      var recordingRow = recordingStreamRepeater.itemAt(selectedIndex)
      if (recordingRow && displayAudioSources.length > 1) recordingRow.toggleOutputMenu()
      else {
        var recordingStream = displayRecordingStreams[selectedIndex]
        if (recordingStream && recordingStream.audio)
          recordingStream.audio.muted = !recordingStream.audio.muted
      }
    }
  }

  function openAdvancedAudio() {
    controller.hide()
    if (bar && bar.shell && typeof bar.shell.summon === "function")
      bar.shell.summon("ssupt.audio-control", "{}")
    else
      Quickshell.execDetached(["omarchy-shell", "shell", "summon", "ssupt.audio-control", "{}"])
  }

  onOpenedChanged: {
    if (opened) {
      if (appLibrary && typeof appLibrary.refreshIcons === "function") appLibrary.refreshIcons()
      refreshDisplayAudioModels()
      focusSection = "output"
      headerIndex = 1
      selectedIndex = -1  // first keyboard cursor reveal starts on the output slider
      cursorActive = false
      Qt.callLater(resetScroll)
    } else {
      streamOutputMenuOpen = false
      clearDisplayAudioModels()
    }
  }

  // Clamp / repair the cursor whenever any list refreshes underneath us.
  onAudioSinksChanged: scheduleDisplayAudioModelRefresh()
  onAudioSourcesChanged: scheduleDisplayAudioModelRefresh()
  onAudioStreamsChanged: scheduleDisplayAudioModelRefresh()
  onRecordingStreamsChanged: scheduleDisplayAudioModelRefresh()

  function listSnapshot(list) {
    return Model.listSnapshot(list)
  }

  function refreshDisplayAudioModels() {
    if (!opened) return
    displayAudioSinks = listSnapshot(audioSinks)
    displayAudioSources = listSnapshot(audioSources)
    displayAudioStreams = listSnapshot(audioStreams)
    displayRecordingStreams = listSnapshot(recordingStreams)
    if (displayAudioStreams.length === 0) streamRoutes = ({})
    if (displayRecordingStreams.length === 0) recordingStreamRoutes = ({})
    refreshStreamRoutes()
    clampCursor()
  }

  function scheduleDisplayAudioModelRefresh() {
    if (!opened) return
    audioModelRefreshTimer.restart()
  }

  function clearDisplayAudioModels() {
    audioModelRefreshTimer.stop()
    displayAudioSinks = []
    displayAudioSources = []
    displayAudioStreams = []
    displayRecordingStreams = []
    streamRoutes = ({})
    recordingStreamRoutes = ({})
    streamRouteReadError = ""
    streamRouteSetError = ""
    pendingStreamRoute = null
  }

  function refreshStreamRoutes() {
    if (!opened || (displayAudioStreams.length === 0 && displayRecordingStreams.length === 0)
        || streamRoutesProc.running) return
    streamRoutesProc.running = true
  }

  function updateStreamRoutes(raw) {
    try {
      var routes = JSON.parse(String(raw || "{}"))
      if (!routes || typeof routes !== "object") routes = ({})
      var playback = routes.playback && typeof routes.playback === "object" ? routes.playback : ({})
      var recording = routes.recording && typeof routes.recording === "object" ? routes.recording : ({})
      if (pendingStreamRoute) {
        var pendingRoutes = pendingStreamRoute.direction === "recording" ? recording : playback
        pendingRoutes[pendingStreamRoute.stream] = {
          target: pendingStreamRoute.target,
          mode: pendingStreamRoute.mode
        }
      }
      streamRoutes = playback
      recordingStreamRoutes = recording
      streamRouteReadError = ""
    } catch (e) {
      streamRoutes = ({})
      recordingStreamRoutes = ({})
      streamRouteReadError = "Could not read application routes"
    }
  }

  function streamSerial(node) {
    return Model.nodeSerial(node)
  }

  function streamRoute(node) {
    var serial = streamSerial(node)
    if (serial === "") return null
    var route = streamRoutes[serial]
    return route && typeof route === "object" ? route : null
  }

  function recordingStreamRoute(node) {
    var serial = streamSerial(node)
    if (serial === "") return null
    var route = recordingStreamRoutes[serial]
    return route && typeof route === "object" ? route : null
  }

  function setStreamRoute(node, optionValue, direction) {
    var streamSerialValue = streamSerial(node)
    var route = Model.parseStreamOutputOption(optionValue)
    if (streamSerialValue === "" || route.sink === "" || route.mode === "" || streamRouteSetProc.running) return

    var routes = direction === "recording" ? recordingStreamRoutes : streamRoutes
    var next = ({})
    for (var key in routes) next[key] = routes[key]
    next[streamSerialValue] = { target: route.sink, mode: route.mode }
    if (direction === "recording") recordingStreamRoutes = next
    else streamRoutes = next
    streamRouteSetError = ""
    pendingStreamRoute = {
      direction: direction,
      stream: streamSerialValue,
      target: route.sink,
      mode: route.mode
    }
    streamRouteSetProc.command = [
      pluginScript("audio-stream-route-set"),
      direction,
      streamSerialValue,
      route.sink,
      route.mode
    ]
    streamRouteSetProc.running = true
  }

  // Scroll the mixer back to the top when it reopens. Following the keyboard
  // cursor while it moves is handled separately by ensureCursorVisible.
  function resetScroll() {
    if (!scrollArea) return
    var flick = scrollArea.contentItem
    if (flick && flick.contentY !== undefined) flick.contentY = 0
  }

  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var margin = 6
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    if (maxY <= Style.space(24) || (root.focusSection === "output" && root.selectedIndex === -1)) {
      flick.contentY = 0
      return
    }
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var viewTop = flick.contentY
    var viewBottom = viewTop + flick.height
    if (top < viewTop + margin) flick.contentY = Math.max(0, Math.min(maxY, top - margin))
    else if (bottom > viewBottom - margin)
      flick.contentY = Math.max(0, Math.min(maxY, bottom + margin - flick.height))
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections || !sections.length) return
    // "header" is virtual and never appears in visibleSections, so it has to
    // be let through: muting republishes the PipeWire snapshot, and clamping
    // would knock the cursor off the hero switch on every toggle.
    if (focusSection === "header") return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = visibleSections[0]
      selectedIndex = sectionHasSlider(focusSection) ? -1 : 0
      return
    }
    var count = sectionCount(focusSection)
    var hasSlider = sectionHasSlider(focusSection)
    var floor = hasSlider ? -1 : 0
    if (selectedIndex > count - 1) selectedIndex = Math.max(floor, count - 1)
    if (selectedIndex < floor) selectedIndex = floor
  }

  function outputIcon(volume) {
    // Match the old Waybar pulseaudio glyph set. The Material Design speaker
    // icons render visually smaller in JetBrainsMono Nerd Font.
    if (!sink || !sink.audio) return ""
    if (isHeadphones(sink)) return "󰋋"
    if (outputMuted) return ""
    var v = volume === undefined ? outputVolume : volume
    if (v >= 0.67) return ""
    if (v >= 0.34) return ""
    if (v > 0) return ""
    return ""
  }

  function inputIcon() {
    if (!source || !source.audio) return "󰍭"
    return inputMuted ? "󰍭" : "󰍬"
  }

  // Playful mood-name for a given output volume. Mirrors the brightness
  // panel's brightnessName ladder; bands are wide enough that small
  // tweaks don't rename the room you're in.
  function outputVolumeName(volume, muted) {
    return Model.outputVolumeName(volume, muted)
  }

  function setOutputVolume(v) {
    if (!volumeSink || !volumeSink.audio) return outputVolume
    var volume = Math.max(0, Math.min(outputVolumeMaximum, v))
    volumeSink.audio.volume = volume
    return volume
  }

  function enforceOutputVolumeLimit() {
    if (!outputOverdrive && outputVolume > 1) setOutputVolume(1)
  }

  function loadAudioControlSettings(raw) {
    var settings = Model.parseAudioControlSettings(raw)
    outputOverdrive = settings.outputOverdrive
    captureNotifications = settings.captureNotifications
    enforceOutputVolumeLimit()
  }

  function showVolumeOsd(volume) {
    if (!bar || !bar.shell) return
    bar.shell.summon("omarchy.osd", JSON.stringify({
      icon: outputIcon(volume),
      value: Math.round(volume * 100)
    }))
  }

  function setInputVolume(v) {
    if (!source || !source.audio) return
    source.audio.volume = Math.max(0, Math.min(1, v))
  }

  function toggleOutputMute() {
    if (volumeSink && volumeSink.audio) volumeSink.audio.muted = !volumeSink.audio.muted
  }

  function toggleInputMute() {
    if (source && source.audio) source.audio.muted = !source.audio.muted
  }

  // The hero switch is the whole panel's on/off, so it carries both channels
  // at once. It reads as on while anything is still audible, which keeps
  // muting a single channel from the row below flipping the master switch.
  function toggleAllMuted() {
    var mute = anyAudible
    if (hasOutput) volumeSink.audio.muted = mute
    if (hasInput) source.audio.muted = mute
  }

  function setDefaultSink(node) {
    if (!node || node.id === undefined || !node.name || defaultSinkProc.running) return
    var previousSinkName = sink && sink.name ? String(sink.name) : ""
    previousDefaultSink = sink
    Pipewire.preferredDefaultAudioSink = node
    defaultOutputError = ""
    defaultSinkProc.command = [
      pluginScript("audio-output-set-default"),
      String(node.id),
      String(node.name),
      previousSinkName
    ]
    defaultSinkProc.running = true
  }

  function setDefaultSource(node) {
    if (!node || node.id === undefined || !node.name || defaultSourceProc.running) return
    var previousSourceName = source && source.name ? String(source.name) : ""
    previousDefaultSource = source
    Pipewire.preferredDefaultAudioSource = node
    defaultInputError = ""
    defaultSourceProc.command = [
      pluginScript("audio-input-set-default"),
      String(node.id),
      String(node.name),
      previousSourceName
    ]
    defaultSourceProc.running = true
  }

  function sinkAvailable(node) {
    if (!node || !node.name || !sinkAvailabilityLoaded) return true
    var name = String(node.name)
    return sinkAvailability[name] !== false
  }

  function updateSinkAvailability(raw) {
    sinkAvailability = Model.parseSinkAvailability(raw)
    sinkAvailabilityLoaded = true
  }

  function friendlyDeviceLabel(text) {
    return Model.friendlyDeviceLabel(text)
  }

  function nodeLabel(node) {
    return Model.nodeLabel(node)
  }

  function nodeProps(node) {
    return Model.nodeProps(node)
  }

  function isHeadphones(node) {
    return Model.isHeadphones(node)
  }

  function sinkGlyph(node) {
    return Model.sinkGlyph(node)
  }

  function sourceGlyph(node) {
    return Model.sourceGlyph(node)
  }

  function friendlyStreamLabel(label) {
    return Model.friendlyStreamLabel(label)
  }

  function streamLabelKey(label) {
    return Model.streamLabelKey(label)
  }

  function streamLabelIsGeneric(label) {
    return Model.streamLabelIsGeneric(label)
  }

  function rawStreamLabel(node) {
    return Model.rawStreamLabel(node)
  }

  function mprisPlayerLabel(player) {
    return Model.mprisPlayerLabel(player)
  }

  function mprisPlayerIsProxy(player) {
    return Model.mprisPlayerIsProxy(player)
  }

  function streamRepresentsMprisPlayer(streamLabel, playerLabel) {
    return Model.streamRepresentsMprisPlayer(streamLabel, playerLabel)
  }

  function mprisLabelsFor(predicate) {
    return Model.mprisLabelsFor(mprisPlayers, predicate)
  }

  function matchingMprisStreamLabel(label) {
    return Model.matchingMprisStreamLabel(label, mprisPlayers)
  }

  function unmatchedMprisStreamLabel(label) {
    // Spotify exposes its PipeWire stream as "audio-src". For generic stream
    // names, use the one MPRIS player not already represented by another audio
    // stream (e.g. Chromium, or ALSA apps like cliamp).
    return Model.unmatchedMprisStreamLabel(label, mprisPlayers, displayAudioStreams)
  }

  function streamLabel(node) {
    return Model.streamLabel(node, mprisPlayers, displayAudioStreams)
  }

  function recordingStreamLabel(node) {
    return Model.recordingStreamLabel(node)
  }

  function streamIconSource(node) {
    var name = Model.streamIconName(node, mprisPlayers, displayAudioStreams)
    if (!name) return ""
    if (name.indexOf("file://") === 0 || name.indexOf("image://") === 0) return name
    if (name.charAt(0) === "/") return Util.fileUrl(name)
    var themed = Quickshell.iconPath(name, true)
    if (themed) return themed
    if (appLibrary && appLibrary.iconIndex && appLibrary.iconIndex[name]
        && typeof appLibrary.iconSource === "function") return appLibrary.iconSource(name)
    return ""
  }

  function streamRepresentsPlayer(node, player) {
    return Model.streamRepresentsPlayer(node, player, mprisPlayers, displayAudioStreams)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PwObjectTracker { objects: root.candidateSinks }
  PwObjectTracker { objects: root.candidateSources }
  PwObjectTracker { objects: root.audioStreams }
  PwObjectTracker { objects: root.recordingStreams }

  PwNodePeakMonitor {
    id: inputPeakMonitor
    node: root.source
    enabled: (root.opened || root.recordingApplicationCount > 0) && !!root.source
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadAudioControlSettings(text())
    onLoadFailed: root.loadAudioControlSettings("")
    onFileChanged: reload()
  }

  FileView {
    path: root.audioPreferencesPath
    watchChanges: true
    printErrors: false
    onLoaded: root.loadAudioPreferences(text())
    onLoadFailed: root.loadAudioPreferences("")
    onFileChanged: reload()
  }

  FileView {
    path: root.scenesPath
    watchChanges: true
    printErrors: false
    onLoaded: function() {
      root.audioScenes = Model.parseAudioScenes(text()).scenes
      root.scenesLoaded = true
    }
    onLoadFailed: function() {
      root.audioScenes = []
      root.scenesLoaded = true
    }
    onFileChanged: reload()
  }

  AudioSceneController {
    id: sceneController
    scriptsDir: root.scriptsDir
    onApplyFinished: function(result) {
      var text = "Applied scene '" + result.name + "'"
      if (result.errors.length > 0)
        root.showSceneFeedback(text + ", but some steps failed", true)
      else if (result.skipped.length > 0)
        root.showSceneFeedback(text + " · skipped: " + result.skipped.join(", "), false)
      else
        root.showSceneFeedback(text, false)
    }
  }

  Timer {
    id: sceneFeedbackTimer
    interval: 6000
    onTriggered: root.sceneFeedback = ""
  }

  function showSceneFeedback(text, isError) {
    sceneFeedback = text
    sceneFeedbackIsError = isError
    sceneFeedbackTimer.restart()
  }

  function applySceneAt(index) {
    var scene = index >= 0 ? audioScenes[index] : null
    if (!scene || sceneController.busy) return
    sceneController.apply(scene)
  }

  Process {
    id: sinkAvailabilityProc
    command: ["omarchy-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateSinkAvailability(text)
    }
  }

  // Capture notifications are best-effort; probe once so a missing
  // notify-send never turns into repeated spawn failures.
  Process {
    id: notificationProbeProc
    running: true
    command: ["sh", "-c", "command -v notify-send >/dev/null 2>&1"]
    onExited: function(exitCode) { root.notificationsAvailable = exitCode === 0 }
  }

  Process {
    id: volumeSinkProc
    command: ["omarchy-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumeSinkName = String(text).trim()
    }
  }

  Process {
    id: defaultSinkProc
    onExited: function(exitCode) {
      root.defaultOutputError = exitCode === 0 ? ""
        : (exitCode === 2 ? "Default output changed, but its preference could not be saved"
          : "Could not change the default audio output")
      if (exitCode !== 0 && exitCode !== 2 && root.previousDefaultSink)
        Pipewire.preferredDefaultAudioSink = root.previousDefaultSink
      root.previousDefaultSink = null
    }
  }

  Process {
    id: defaultSourceProc
    onExited: function(exitCode) {
      root.defaultInputError = exitCode === 0 ? ""
        : (exitCode === 2 ? "Default input changed, but its preference could not be saved"
          : "Could not change the default audio input")
      if (exitCode !== 0 && exitCode !== 2 && root.previousDefaultSource)
        Pipewire.preferredDefaultAudioSource = root.previousDefaultSource
      root.previousDefaultSource = null
    }
  }

  Process {
    id: streamRoutesProc
    command: [root.pluginScript("audio-stream-routes")]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.updateStreamRoutes(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.opened
          && (root.displayAudioStreams.length > 0 || root.displayRecordingStreams.length > 0))
        root.streamRouteReadError = "Could not read application routes"
    }
  }

  Process {
    id: streamRouteSetProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.streamRouteSetError = "Could not change the application route"
      else root.streamRouteSetError = ""
      root.pendingStreamRoute = null
      streamRouteRefreshTimer.restart()
    }
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!sinkAvailabilityProc.running) sinkAvailabilityProc.running = true
  }

  // Runs whether or not the panel is open: the bar shows and scrolls the output
  // volume too, so an unresolved sink there would read and change the virtual
  // tuning sink instead of the speakers.
  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.resolveVolumeSink()
  }

  Timer {
    id: audioModelRefreshTimer
    interval: 75
    repeat: false
    onTriggered: root.refreshDisplayAudioModels()
  }

  Timer {
    id: streamRouteRefreshTimer
    interval: 150
    repeat: false
    onTriggered: root.refreshStreamRoutes()
  }

  Timer {
    interval: 1500
    running: !root.recordingObservationReady
    repeat: false
    onTriggered: {
      root.observedRecordingLabels = root.listSnapshot(root.activeRecordingLabels)
      root.recordingObservationReady = true
    }
  }

  Timer {
    id: recordingChangeTimer
    interval: 150
    repeat: false
    onTriggered: root.observeRecordingApplications()
  }

  Timer {
    id: inputPeakHoldTimer
    interval: 1200
    repeat: false
    onTriggered: root.inputPeakHold = 0
  }

  Timer {
    id: inputClippingTimer
    interval: 2500
    repeat: false
    onTriggered: root.inputClipping = false
  }

  Timer {
    interval: 1500
    running: root.opened && (root.displayAudioStreams.length > 0 || root.displayRecordingStreams.length > 0)
    repeat: true
    onTriggered: if (!root.streamOutputMenuOpen && !streamRouteSetProc.running)
      root.refreshStreamRoutes()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.recordingTooltip
    iconComponent: Component {
      Item {
        AudioBarIcon {
          anchors.fill: parent
          outputGlyph: root.outputIcon()
          recordingCount: root.recordingApplicationCount
          microphoneMuted: root.inputMuted
          microphoneClipping: root.inputClipping
          foreground: root.barForeground
          urgent: root.urgent
          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        }
      }
    }
    onPressed: function(b) {
      if (b === Qt.RightButton) root.toggleAllMuted()
      else if (b === Qt.MiddleButton) root.toggleInputMute()
      else root.toggle()
    }

    onWheelMoved: function(delta) {
      if (!root.hasOutput) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      var volume = root.setOutputVolume(root.outputVolume + wheel.steps * 0.05)
      root.showVolumeOsd(volume)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.streamOutputMenuOpen
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustCursorHorizontal(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        // 'm' mutes whatever the cursor is on: focused section's slider
        // for output/input, or the focused playback/recording application.
        if (t === "m" || t === "M") {
          if (!root.cursorActive) return
          if ((root.focusSection === "streams" || root.focusSection === "recording")
              && root.selectedIndex >= 0) {
            var streams = root.focusSection === "recording"
              ? root.displayRecordingStreams : root.displayAudioStreams
            if (root.selectedIndex >= streams.length) return
            var s = streams[root.selectedIndex]
            if (s && s.audio) s.audio.muted = !s.audio.muted
          } else if (root.focusSection === "input") {
            root.toggleInputMute()
          } else if (root.focusSection !== "scenes") {
            root.toggleOutputMute()
          }
        }
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical: ScrollBar {
          id: panelScrollBar
          policy: panelColumn.implicitHeight > scrollArea.height
            ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
          interactive: false
          width: Style.space(5)
          background: Item { }
          contentItem: Rectangle {
            implicitWidth: Style.space(3)
            radius: width / 2
            color: root.bar.foreground
            opacity: panelScrollBar.active ? 0.55 : 0.25
          }
        }
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: speaker icon · title/status ----------
          Item {
            id: heroItem
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

            // Status only — the switch owns muting, mouse and keyboard alike.
            Text {
              id: heroIcon
              text: root.outputIcon()
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              opacity: root.outputMuted ? 0.5 : 1.0
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Row {
              id: heroActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)

              Button {
                id: settingsAction
                iconText: "󰒓"
                tooltipText: "Advanced audio"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                iconSize: Style.font.subtitle * 1.5
                horizontalPadding: Style.space(5)
                verticalPadding: Style.space(2)
                hasCursor: root.settingsHeaderHasCursor
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(on) { if (on) root.setHeaderCursor(0) }
                onClicked: root.openAdvancedAudio()
              }

              // Checked means something is still audible, so muting everything
              // reads as switching audio off.
              ToggleSwitch {
                id: powerSwitch
                checked: root.anyAudible
                hasCursor: root.powerHeaderHasCursor
                foreground: root.bar.foreground
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(on) { if (on) root.setHeaderCursor(1) }
                onToggled: root.toggleAllMuted()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: root.toggleHint
                  fontFamily: root.bar.fontFamily
                }
              }
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.rightMargin: heroActions.width + Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Audio"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                text: root.outputVolumeName(
                  outputSlider.dragging ? outputSlider.liveValue : root.outputVolume,
                  root.outputMuted
                ).toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---- Scenes ----
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.audioScenes.length > 0

            PanelSectionHeader {
              text: "SCENES"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Flow {
              id: sceneChipFlow
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.audioScenes

                CursorSurface {
                  id: sceneChip
                  required property var modelData
                  required property int index
                  readonly property string sceneName: modelData ? String(modelData.name || "") : ""
                  width: Math.min(sceneChipLabel.implicitWidth + Style.space(16), sceneChipFlow.width)
                  height: sceneChipLabel.implicitHeight + Style.space(10)
                  hasCursor: root.cursorActive && root.focusSection === "scenes"
                    && root.selectedIndex === sceneChip.index
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sceneChip)
                  foreground: root.bar.foreground
                  fill: root.hoverFill
                  currentFill: root.selectedFill
                  bordered: true

                  Text {
                    id: sceneChipLabel
                    anchors.centerIn: parent
                    text: sceneChip.sceneName
                    color: sceneChip.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, sceneChip.width - Style.space(12))
                  }

                  MouseArea {
                    anchors.fill: parent
                    enabled: !root.sceneController.busy
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onContainsMouseChanged: if (containsMouse) {
                      root.cursorActive = true
                      root.focusSection = "scenes"
                      root.selectedIndex = sceneChip.index
                    }
                    onClicked: root.applySceneAt(sceneChip.index)
                  }
                }
              }
            }

            Text {
              visible: root.sceneFeedback !== ""
              width: parent.width
              text: root.sceneFeedback
              color: root.sceneFeedbackIsError
                ? root.urgent : Qt.darker(root.bar.foreground, 1.35)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---- Output devices ----
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Item {
              width: parent.width
              implicitHeight: Math.max(outputHeader.implicitHeight, outputPercent.implicitHeight)

              PanelSectionHeader {
                id: outputHeader
                text: "OUTPUT"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: outputPercent
                text: Math.round((outputSlider.dragging ? outputSlider.liveValue : root.outputVolume) * 100) + "%"
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.outputMuted ? 0.5 : 1.0
              }
            }

            CursorSurface {
              id: outputSliderRow
              width: parent.width
              height: outputSlider.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "output" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(outputSliderRow)
              foreground: root.bar.foreground
              outline: true

              PanelSlider {
                id: outputSlider
                bar: root.bar
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                minimum: 0
                maximum: root.outputVolumeMaximum
                step: 0.05
                value: root.outputVolume
                opacity: root.outputMuted ? 0.5 : 1.0
                enabled: !!root.sink

                onMoved: function(v) { root.setOutputVolume(v) }
                onRightClicked: root.toggleOutputMute()
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "output"
                  root.selectedIndex = -1
                }
              }
            }

            Repeater {
              model: root.displayAudioSinks

              AudioSinkRow {
                id: sinkDelegate
                required property var modelData
                required property int index
                width: panelColumn.width
                node: modelData
                rowIndex: index
                bar: root.bar
                preferredName: root.preferredOutputName
                defaultSetBusy: defaultSinkProc.running
                hasCursor: root.cursorActive && root.focusSection === "output"
                  && root.selectedIndex === sinkDelegate.rowIndex
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sinkDelegate)
                foreground: root.bar.foreground
                fill: root.hoverFill
                currentFill: root.selectedFill
                onClaimed: function(section, index) {
                  root.cursorActive = true
                  root.focusSection = section
                  root.selectedIndex = index
                }
                onActivated: function(node) { root.setDefaultSink(node) }
              }
            }
          }

          // ---- Input ----
          PanelSeparator {
            visible: root.displayAudioSources.length > 0 || !!root.source
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.displayAudioSources.length > 0 || !!root.source

            Item {
              width: parent.width
              implicitHeight: Math.max(microphoneHeader.implicitHeight, microphonePercent.implicitHeight)

              PanelSectionHeader {
                id: microphoneHeader
                text: "INPUT"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: microphonePercent
                text: root.inputClipping
                  ? "CLIPPING"
                  : Math.round((inputSlider.dragging ? inputSlider.liveValue : root.inputVolume) * 100) + "%"
                color: root.inputClipping ? root.urgent : Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                opacity: root.inputMuted ? 0.5 : 1.0
              }
            }

            CursorSurface {
              id: inputSliderRow
              visible: !!root.source
              width: parent.width
              height: inputControls.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "input" && root.selectedIndex === -1
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(inputSliderRow)
              foreground: root.bar.foreground
              outline: true

              Column {
                id: inputControls
                anchors.fill: parent
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(5)

                PanelSlider {
                  id: inputSlider
                  bar: root.bar
                  width: parent.width
                  minimum: 0
                  maximum: 1
                  step: 0.05
                  value: root.inputVolume
                  opacity: root.inputMuted ? 0.5 : 1.0
                  enabled: !!root.source

                  onMoved: function(v) { root.setInputVolume(v) }
                  onRightClicked: root.toggleInputMute()
                }

                Rectangle {
                  width: parent.width
                  height: Math.max(Style.space(5), Style.spacing.xs)
                  color: Util.alpha(root.bar.foreground, 0.18)
                  opacity: root.inputMuted ? 0.35 : 1.0

                  Rectangle {
                    height: parent.height
                    width: parent.width * root.inputPeakLevel
                    color: root.inputClipping ? root.urgent : root.bar.foreground
                    Behavior on width { NumberAnimation { duration: 70 } }
                  }

                  Rectangle {
                    visible: root.inputPeakHold > 0.02
                    width: Math.max(1, Style.space(2))
                    height: parent.height + Style.space(4)
                    x: Math.max(0, Math.min(parent.width - width,
                      parent.width * root.inputPeakHold - width / 2))
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.inputPeakHold >= 0.98 ? root.urgent : root.bar.foreground
                  }
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) {
                  root.cursorActive = true
                  root.focusSection = "input"
                  root.selectedIndex = -1
                }
              }
            }

            Repeater {
              model: root.displayAudioSources

              AudioSourceRow {
                id: sourceDelegate
                required property var modelData
                required property int index
                width: panelColumn.width
                node: modelData
                rowIndex: index
                bar: root.bar
                preferredName: root.preferredInputName
                defaultSetBusy: defaultSourceProc.running
                hasCursor: root.cursorActive && root.focusSection === "input"
                  && root.selectedIndex === sourceDelegate.rowIndex
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sourceDelegate)
                foreground: root.bar.foreground
                fill: root.hoverFill
                currentFill: root.selectedFill
                onClaimed: function(section, index) {
                  root.cursorActive = true
                  root.focusSection = section
                  root.selectedIndex = index
                }
                onActivated: function(node) { root.setDefaultSource(node) }
              }
            }
          }

          // ---- Per-app playback and recording streams ----
          PanelSeparator {
            visible: root.displayAudioStreams.length > 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displayAudioStreams.length > 0

            PanelSectionHeader {
              text: "PLAYBACK"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              id: streamRepeater
              model: root.displayAudioStreams

              AudioStreamRow {
                id: streamDelegate
                required property var modelData
                required property int index
                width: panelColumn.width
                node: modelData
                rowIndex: index
                recording: false
                bar: root.bar
                monitorEnabled: root.opened
                representsPlayer: root.streamRepresentsPlayer(streamDelegate.node, root.activeMediaPlayer)
                currentRoute: streamDelegate.recording
                  ? root.recordingStreamRoute(streamDelegate.node)
                  : root.streamRoute(streamDelegate.node)
                targetCount: streamDelegate.recording
                  ? root.displayAudioSources.length : root.displayAudioSinks.length
                routeOptions: streamDelegate.recording
                  ? root.recordingInputOptions : root.streamOutputOptions
                streamLabel: streamDelegate.recording
                  ? root.recordingStreamLabel(streamDelegate.node)
                  : root.streamLabel(streamDelegate.node)
                iconSource: root.streamIconSource(streamDelegate.node)
                routeAvailable: root.streamSerial(streamDelegate.node) !== ""
                routeSetBusy: streamRouteSetProc.running
                hasCursor: root.cursorActive
                  && root.focusSection === (streamDelegate.recording ? "recording" : "streams")
                  && root.selectedIndex === streamDelegate.rowIndex
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(streamDelegate)
                foreground: root.bar.foreground
                fill: root.hoverFill
                onClaimed: function(section, index) {
                  root.cursorActive = true
                  root.focusSection = section
                  root.selectedIndex = index
                }
                onRouteChosen: function(route) {
                  root.setStreamRoute(streamDelegate.node, route,
                    streamDelegate.recording ? "recording" : "playback")
                }
                onPopupToggled: function(open) {
                  root.streamOutputMenuOpen = open
                  if (!open) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                }
              }
            }
          }

          PanelSeparator {
            visible: root.displayRecordingStreams.length > 0
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.displayRecordingStreams.length > 0

            PanelSectionHeader {
              text: "RECORDING"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              id: recordingStreamRepeater
              model: root.displayRecordingStreams

              AudioStreamRow {
                id: recordingStreamDelegate
                required property var modelData
                required property int index
                width: panelColumn.width
                node: modelData
                rowIndex: index
                recording: true
                bar: root.bar
                monitorEnabled: root.opened
                representsPlayer: root.streamRepresentsPlayer(recordingStreamDelegate.node, root.activeMediaPlayer)
                currentRoute: recordingStreamDelegate.recording
                  ? root.recordingStreamRoute(recordingStreamDelegate.node)
                  : root.streamRoute(recordingStreamDelegate.node)
                targetCount: recordingStreamDelegate.recording
                  ? root.displayAudioSources.length : root.displayAudioSinks.length
                routeOptions: recordingStreamDelegate.recording
                  ? root.recordingInputOptions : root.streamOutputOptions
                streamLabel: recordingStreamDelegate.recording
                  ? root.recordingStreamLabel(recordingStreamDelegate.node)
                  : root.streamLabel(recordingStreamDelegate.node)
                iconSource: root.streamIconSource(recordingStreamDelegate.node)
                routeAvailable: root.streamSerial(recordingStreamDelegate.node) !== ""
                routeSetBusy: streamRouteSetProc.running
                hasCursor: root.cursorActive
                  && root.focusSection === (recordingStreamDelegate.recording ? "recording" : "streams")
                  && root.selectedIndex === recordingStreamDelegate.rowIndex
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(recordingStreamDelegate)
                foreground: root.bar.foreground
                fill: root.hoverFill
                onClaimed: function(section, index) {
                  root.cursorActive = true
                  root.focusSection = section
                  root.selectedIndex = index
                }
                onRouteChosen: function(route) {
                  root.setStreamRoute(recordingStreamDelegate.node, route,
                    recordingStreamDelegate.recording ? "recording" : "playback")
                }
                onPopupToggled: function(open) {
                  root.streamOutputMenuOpen = open
                  if (!open) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                }
              }
            }
          }

          Text {
            visible: root.panelError !== ""
            width: parent.width
            text: root.panelError
            color: root.bar.urgent
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

}
