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

  AudioRuntime { id: runtime }

  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var rawSource: Pipewire.defaultAudioSource
  // PipeWire permits a sink monitor to be the default source. Treating that
  // loopback node as a microphone would expose the wrong mute/level controls
  // and produce misleading capture state in the panel.
  readonly property var source: usableInputNode(rawSource) && mutableAudioNode(rawSource)
    ? rawSource : null
  AudioRulesController {
    id: rulesStore
    nodes: root.nodes
    rulesPath: runtime.rulesPath
    scriptPath: runtime.script("audio-app-rules")
    onRulesChanged: {
      root.resetRoutingEnforcement()
      Qt.callLater(root.enforceRoutingRules)
      Qt.callLater(root.scheduleOutputTopologyRecovery)
    }
    onWriteFinished: function(success) {
      if (success) return
      root.streamRouteSetError = "Application route changed, but its saved rule could not be updated"
      root.resetRoutingEnforcement()
      Qt.callLater(root.enforceRoutingRules)
    }
  }
  AudioOutputGroupsController {
    id: outputGroups
    scriptPath: runtime.script("audio-output-groups")
    groups: rulesStore.outputGroups
    // A degraded group that is still the default must first move its
    // following streams to a surviving member. Reconciliation can safely
    // unload the virtual sink after that transactional default change ends.
    autoReconcile: !defaultSinkProc.running
    onOperationFinished: function(_action, _groupId, success, _exitCode) {
      if (success) Qt.callLater(root.enforceRoutingRules)
    }
  }
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var appLibrary: bar && bar.shell ? bar.shell.appLibrary : null
  readonly property var mediaService: bar && bar.shell
    ? bar.shell.firstPartyServiceFor("omarchy.media") : null
  readonly property var activeMediaPlayer: mediaService ? mediaService.activePlayer : null
  property var audioPreferences: Model.parseAudioPreferences("")
  property bool audioPreferencesLoaded: false
  property bool outputOverdrive: false
  property bool captureNotifications: true
  property bool audioControlSettingsLoaded: false
  property bool notificationsAvailable: false
  property var audioScenes: []
  property bool audioScenesLoaded: false
  readonly property var audioRules: rulesStore.rules
  readonly property bool rulesLoaded: rulesStore.loaded
  property string sceneFeedback: ""
  property bool sceneFeedbackIsError: false
  property var observedRecordingLabels: []
  property bool recordingObservationReady: false
  property real inputPeakHold: 0
  property bool inputClipping: false
  readonly property real outputVolumeMaximum: outputOverdrive ? 1.5 : 1.0
  onOutputOverdriveChanged: enforceOutputVolumeLimit()

  readonly property var candidateSinks: rulesStore.sinks
  readonly property var candidateSources: rulesStore.sources
  readonly property var candidateStreams: rulesStore.playbackStreams
  readonly property var candidateRecordingStreams: rulesStore.recordingStreams

  property var sinkAvailability: ({})
  property bool sinkAvailabilityLoaded: false

  function usableInputNode(node) {
    try {
      return !!node && node.ready === true && !!node.audio
        && node.isStream !== true && node.isSink !== true
        && Model.nodeName(node) !== "" && Model.isAudioSource(node)
        && !Model.isMonitorSource(node)
        && !Model.isInternalAudioNode(Model.nodeName(node), Model.nodeProps(node))
    } catch (_error) {
      return false
    }
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

  // A combine sink can survive temporarily while one of its physical members
  // is disconnected. Keep the current default visible so the user can move
  // away from it, but never offer a degraded or unowned group as a new route.
  function outputSinkRouteAvailable(node) {
    var name = Model.nodeName(node)
    if (name === "" || !sinkAvailable(node)) return false
    if (!Model.isOutputGroupSink(name)) return true
    var group = rulesStore.groupForSink(name)
    return !!group && rulesStore.outputGroupAvailable(group)
  }

  readonly property var rawAudioSinks: {
    var list = []
    for (var i = 0; i < candidateSinks.length; i++) {
      var candidate = candidateSinks[i]
      var candidateName = Model.nodeName(candidate)
      if (candidateName !== "" && outputSinkRouteAvailable(candidate)
          && !deviceHidden(candidateName)) list.push(candidate)
    }
    var sinkName = Model.nodeName(sink)
    if (sinkName !== "" && !deviceHidden(sinkName) && list.indexOf(sink) < 0)
      list.unshift(sink)
    var sorted = list.slice()
    sorted.sort(Model.deviceSortComparator(audioRules.devices.favorites))
    return sorted
  }

  readonly property var rawAudioSources: {
    var list = []
    for (var i = 0; i < candidateSources.length; i++) {
      var candidate = candidateSources[i]
      var candidateName = Model.nodeName(candidate)
      if (candidateName !== "" && usableInputNode(candidate)
          && mutableAudioNode(candidate) && !deviceHidden(candidateName)) list.push(candidate)
    }
    var sourceName = Model.nodeName(source)
    if (sourceName !== "" && usableInputNode(source) && mutableAudioNode(source)
        && !deviceHidden(sourceName)
        && list.indexOf(source) < 0) list.unshift(source)
    var sorted = list.slice()
    sorted.sort(Model.deviceSortComparator(audioRules.devices.favorites))
    return sorted
  }

  readonly property var cachedVisibleAudioSinks: cachedAudioSinks.filter(function(node) {
    var name = Model.nodeName(node)
    return name !== "" && outputSinkRouteAvailable(node) && !deviceHidden(name)
  })
  readonly property var cachedVisibleAudioSources: cachedAudioSources.filter(function(node) {
    var name = Model.nodeName(node)
    return name !== "" && usableInputNode(node) && mutableAudioNode(node)
      && !deviceHidden(name)
  })
  readonly property var audioSinks: rawAudioSinks.length > 0
    ? rawAudioSinks : cachedVisibleAudioSinks
  readonly property var audioSources: rawAudioSources.length > 0
    ? rawAudioSources : cachedVisibleAudioSources
  readonly property var routingSinks: candidateSinks.filter(function(node) {
    return root.outputSinkRouteAvailable(node)
  })
  readonly property var routingSources: candidateSources
  readonly property string preferredOutputName: Model.preferredAudioNodeName(
    audioPreferences, "output", sink, audioSinks)
  readonly property string preferredInputName: Model.preferredAudioNodeName(
    audioPreferences, "input", source, audioSources)

  readonly property var audioStreams: {
    var list = []
    for (var i = 0; i < candidateStreams.length; i++) {
      try {
        if (candidateStreams[i] && candidateStreams[i].audio) list.push(candidateStreams[i])
      } catch (_error) { }
    }
    return list
  }

  readonly property var recordingStreams: {
    var list = []
    for (var i = 0; i < candidateRecordingStreams.length; i++) {
      try {
        if (candidateRecordingStreams[i] && candidateRecordingStreams[i].audio)
          list.push(candidateRecordingStreams[i])
      } catch (_error) { }
    }
    return list
  }

  readonly property var activeRecordingLabels: Model.uniqueRecordingStreamLabels(recordingStreams)
  readonly property int recordingApplicationCount: activeRecordingLabels.length
  readonly property real inputPeakLevel: {
    if (inputMuted) return 0
    var value = Number(inputPeakMonitor.peak)
    return isFinite(value) ? Math.max(0, Math.min(1, value)) : 0
  }
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
  // The Repeaters below use only the snapshot lengths as their models and
  // resolve each node by index. Passing native PwNode objects as JavaScript
  // list rows makes Qt synthesize delegate properties from an object that may
  // disappear mid-regeneration when hardware is unplugged.
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
  property int streamOutputMenuCount: 0
  readonly property bool streamOutputMenuOpen: streamOutputMenuCount > 0
  property string streamRouteReadError: ""
  property string streamRouteSetError: ""
  readonly property string streamRouteError: streamRouteSetError !== ""
    ? streamRouteSetError : streamRouteReadError
  property string defaultOutputError: ""
  property string defaultInputError: ""
  // Suppress immediate retry loops after a transactional fallback failure.
  // A new physical topology makes the attempt eligible again.
  property string degradedGroupFallbackFrom: ""
  property string degradedGroupFallbackBlockedSink: ""
  property string degradedGroupFallbackBlockedTopology: ""
  readonly property string defaultDeviceError: defaultOutputError !== ""
    ? defaultOutputError : defaultInputError
  readonly property string panelError: defaultDeviceError !== ""
    ? defaultDeviceError : (streamRouteError !== "" ? streamRouteError
      : (outputGroups.error !== "" ? outputGroups.error : rulesStore.error))
  property var pendingStreamRoute: null
  readonly property bool routeMutationBusy: defaultSinkProc.running
    || defaultSourceProc.running || streamRouteSetProc.running
    || pendingStreamRoute !== null || rulesStore.busy || outputGroups.busy
  readonly property bool directDeviceMutationBusy: sceneController.busy
    || defaultSinkProc.running || defaultSourceProc.running
  onDirectDeviceMutationBusyChanged: if (!directDeviceMutationBusy)
    enforceOutputVolumeLimit()
  readonly property bool sceneMutationBusy: sceneController.busy || routeMutationBusy
    || streamOutputMenuOpen
  readonly property bool outputTopologyRecoveryBusy: !rulesLoaded
    || sceneController.busy || rulesStore.busy || outputGroups.busy
    || defaultSinkProc.running || defaultSourceProc.running
    || streamRouteSetProc.running || pendingStreamRoute !== null

  // The default is ordered first and named by behavior. Applications on that
  // option follow later default changes; all other choices are persistent.
  readonly property var streamRouteSinks: displayAudioSinks.filter(function(node) {
    return root.outputSinkRouteAvailable(node)
  })
  readonly property var streamOutputOptions: Model.streamOutputOptions(
    streamRouteSinks, sink, routeNodeLabel)
  readonly property var recordingInputOptions: Model.recordingInputOptions(
    displayAudioSources, source, nodeLabel)

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
  property bool volumeSinkResolvePending: false

  // Carry sub-notch touchpad deltas between wheel events.
  property real wheelAccumulator: 0

  readonly property var volumeSink: {
    try {
      if (volumeSinkName === "" || !sink) return sink
      if (volumeSinkName === Model.nodeName(sink)) return sink
      var match = null
      for (var i = 0; i < nodes.length && i < 4096; i++) {
        var n = nodes[i]
        if (!n || !n.isSink || n.isStream || Model.nodeName(n) !== volumeSinkName
            || !n.audio) continue
        if (match) return sink
        match = n
      }
      return match || sink
    } catch (_error) {
      return sink
    }
  }
  onVolumeSinkChanged: enforceOutputVolumeLimit()

  // Re-resolve whenever the selected output changes; the timer below is only a
  // safety net for the tuning being applied or removed underneath us.
  onSinkChanged: {
    if (Model.nodeName(sink) !== degradedGroupFallbackBlockedSink) {
      degradedGroupFallbackBlockedSink = ""
      degradedGroupFallbackBlockedTopology = ""
    }
    // Never expose the physical endpoint resolved for the previous default
    // while a newer asynchronous lookup is still in flight.
    volumeSinkName = ""
    resolveVolumeSink()
    Qt.callLater(scheduleOutputTopologyRecovery)
  }

  function resolveVolumeSink() {
    if (volumeSinkProc.running) {
      volumeSinkResolvePending = true
      return
    }
    volumeSinkResolvePending = false
    volumeSinkProc.response = ""
    volumeSinkProc.requestedDefaultName = Model.nodeName(sink)
    volumeSinkProc.requestedDefaultObjectId = Model.nodeObjectId(sink)
    volumeSinkProc.running = true
  }

  readonly property real outputVolume: audioNodeVolume(volumeSink)
  readonly property bool outputMuted: audioNodeMuted(volumeSink)
  readonly property real inputVolume: audioNodeVolume(source)
  readonly property bool inputMuted: audioNodeMuted(source)

  // A deferred display snapshot can outlive its PipeWire object. Resolve the
  // object id back through the current graph before every direct mutation and
  // reject duplicate ids, replacements, and nodes that are not fully bound.
  function mutableAudioNode(node) {
    try {
      if (!node || node.ready !== true || !node.audio
          || nodes.length > 4096) return false
      var objectId = Model.nodeObjectId(node)
      if (objectId === "") return false
      var match = null
      for (var i = 0; i < nodes.length; i++) {
        var candidate = nodes[i]
        if (!candidate || Model.nodeObjectId(candidate) !== objectId) continue
        if (match) return false
        match = candidate
      }
      return match === node
    } catch (_error) {
      return false
    }
  }

  function audioNodeVolume(node) {
    if (!mutableAudioNode(node)) return 0
    try {
      var value = Number(node.audio.volume)
      return isFinite(value) ? value : 0
    } catch (_error) {
      return 0
    }
  }

  function audioNodeMuted(node) {
    if (!mutableAudioNode(node)) return false
    try { return node.audio.muted === true } catch (_error) { return false }
  }

  function setAudioNodeVolume(node, value, maximum) {
    var requested = Number(value)
    var ceiling = Number(maximum)
    if (!mutableAudioNode(node) || !isFinite(requested)
        || !isFinite(ceiling) || ceiling < 0) return false
    try {
      node.audio.volume = Math.max(0, Math.min(ceiling, requested))
      return true
    } catch (_error) {
      return false
    }
  }

  function setAudioNodeMuted(node, muted) {
    if (!mutableAudioNode(node)) return false
    try {
      node.audio.muted = muted === true
      return true
    } catch (_error) {
      return false
    }
  }

  function toggleAudioNodeMute(node) {
    if (!mutableAudioNode(node)) return false
    try {
      node.audio.muted = node.audio.muted !== true
      return true
    } catch (_error) {
      return false
    }
  }

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
  readonly property bool hasOutput: mutableAudioNode(volumeSink)
  readonly property bool hasInput: mutableAudioNode(source)
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
    if (section === "input") return displayAudioSources.length > 0 || hasInput
    if (section === "streams") return displayAudioStreams.length > 0
    if (section === "recording") return displayRecordingStreams.length > 0
    return false
  }

  function sectionHasSlider(section) {
    if (section === "output") return true
    if (section === "input") return hasInput
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
    if (directDeviceMutationBusy) return
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
      var playbackVolume = audioNodeVolume(s) + Number(delta)
      if (isFinite(playbackVolume)) setAudioNodeVolume(s, playbackVolume, 1.5)
      return
    }
    if (focusSection === "recording" && selectedIndex >= 0 && selectedIndex < displayRecordingStreams.length) {
      var recording = displayRecordingStreams[selectedIndex]
      var recordingVolume = audioNodeVolume(recording) + Number(delta)
      if (isFinite(recordingVolume)) setAudioNodeVolume(recording, recordingVolume, 1.5)
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
      if (row && row.routeMenuAvailable) row.toggleOutputMenu()
      else {
        var st = displayAudioStreams[selectedIndex]
        if (!sceneController.busy) toggleAudioNodeMute(st)
      }
      return
    }
    if (focusSection === "recording" && selectedIndex >= 0) {
      var recordingRow = recordingStreamRepeater.itemAt(selectedIndex)
      if (recordingRow && recordingRow.routeMenuAvailable) recordingRow.toggleOutputMenu()
      else {
        var recordingStream = displayRecordingStreams[selectedIndex]
        if (!sceneController.busy) toggleAudioNodeMute(recordingStream)
      }
    }
  }

  function openAdvancedAudio() {
    if (sceneMutationBusy) return
    controller.hide()
    if (bar && bar.shell && typeof bar.shell.summon === "function")
      bar.shell.summon("ssupt.audio-control", '{"view":"advanced"}')
    else
      Quickshell.execDetached([
        "omarchy-shell", "shell", "summon", "ssupt.audio-control", '{"view":"advanced"}'
      ])
  }

  function updateStreamOutputMenu(open) {
    streamOutputMenuCount = Math.max(0, streamOutputMenuCount + (open ? 1 : -1))
  }

  onOpenedChanged: {
    if (opened) {
      if (appLibrary && typeof appLibrary.refreshIcons === "function") appLibrary.refreshIcons()
      // Populate through the debounced refresh: assigning the display models
      // synchronously inside this signal regenerates every Repeater while
      // PipeWire nodes may still be churning from a device change, which has
      // crashed Quickshell during delegate incubation.
      scheduleDisplayAudioModelRefresh()
      focusSection = "output"
      headerIndex = 1
      selectedIndex = -1  // first keyboard cursor reveal starts on the output slider
      cursorActive = false
      Qt.callLater(resetScroll)
    } else {
      streamOutputMenuCount = 0
      clearDisplayAudioModels()
    }
  }

  // Clamp / repair the cursor whenever any list refreshes underneath us.
  // Stream changes also re-run routing rules so a pinned application is
  // routed as soon as it appears, panel open or not.
  onAudioSinksChanged: {
    scheduleDisplayAudioModelRefresh()
    scheduleOutputTopologyRecovery()
    Qt.callLater(enforceRoutingRules)
  }
  onAudioSourcesChanged: {
    scheduleDisplayAudioModelRefresh()
    Qt.callLater(enforceRoutingRules)
  }
  onAudioStreamsChanged: {
    scheduleDisplayAudioModelRefresh()
    Qt.callLater(enforceRoutingRules)
  }
  onRecordingStreamsChanged: {
    scheduleDisplayAudioModelRefresh()
    Qt.callLater(enforceRoutingRules)
  }

  function listSnapshot(list) {
    return Model.listSnapshot(list)
  }

  // Repeaters rebuild every delegate when their model array is reassigned,
  // even if the contents are identical. During device churn those redundant
  // destroy+incubate cycles are exactly what crashes Quickshell's QJSEngine,
  // so only reassign when the node membership actually changed. Row sliders
  // and meters bind nodes directly and stay live without a reassignment.
  function serialSignature(list) {
    var parts = []
    for (var i = 0; i < list.length; i++) {
      var node = list[i]
      try {
        parts.push(node ? [
          Model.nodeSerial(node),
          Model.nodeObjectId(node),
          Model.nodeName(node),
          node.isSink === true,
          node.isStream === true
        ] : null)
      } catch (_error) {
        // Force a single model refresh when a cached native QObject vanished;
        // the next current-graph signature will then replace this sentinel.
        parts.push(["vanished", i])
      }
    }
    return JSON.stringify(parts)
  }

  function refreshDisplayAudioModels() {
    if (!opened) return
    var nextSinks = listSnapshot(audioSinks)
    var nextSources = listSnapshot(audioSources)
    var nextStreams = listSnapshot(audioStreams)
    var nextRecording = listSnapshot(recordingStreams)
    if (serialSignature(displayAudioSinks) !== serialSignature(nextSinks))
      displayAudioSinks = nextSinks
    if (serialSignature(displayAudioSources) !== serialSignature(nextSources))
      displayAudioSources = nextSources
    if (serialSignature(displayAudioStreams) !== serialSignature(nextStreams))
      displayAudioStreams = nextStreams
    if (serialSignature(displayRecordingStreams) !== serialSignature(nextRecording))
      displayRecordingStreams = nextRecording
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
    var response = Model.parseAudioStreamRoutes(raw)
    if (!response.valid) {
      streamRouteReadError = "Could not read application routes"
      return
    }
    var playback = response.playback
    var recording = response.recording
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
  }

  function streamSerial(node) {
    var group = Model.isRecordingStream(node) ? recordingStreams : audioStreams
    return Model.uniqueNodeSerial(group, node)
  }

  function streamRoute(node) {
    var serial = streamSerial(node)
    if (serial === "") return null
    var route = Model.mapValue(streamRoutes, serial, null)
    return route && typeof route === "object" ? route : null
  }

  function recordingStreamRoute(node) {
    var serial = streamSerial(node)
    if (serial === "") return null
    var route = Model.mapValue(recordingStreamRoutes, serial, null)
    return route && typeof route === "object" ? route : null
  }

  function setStreamRoute(node, optionValue, direction) {
    var streamSerialValue = streamSerial(node)
    var route = Model.parseStreamOutputOption(optionValue)
    if (streamSerialValue === "" || route.sink === "" || route.mode === ""
        || sceneController.busy || routeMutationBusy) return

    // Keep the offline rules layer in sync: when the edited application has
    // a stored rule, a manual choice rewrites that rule instead of being
    // fought over by enforcement on the next appearance.
    lastManualRouteSync = null
    var existingRule = Model.findAppRule(audioRules.appRules, direction, rawStreamLabel(node))
    if (existingRule) {
      var targetName = ""
      if (route.mode === "override")
        targetName = deviceNameForSerial(direction === "recording" ? audioSources : audioSinks, route.sink)
      if (route.mode !== "override" || targetName !== "")
        lastManualRouteSync = {
          app: existingRule.app,
          direction: direction,
          target: route.mode === "override" ? targetName : ""
        }
    }

    var routes = direction === "recording" ? recordingStreamRoutes : streamRoutes
    var next = ({})
    for (var key in routes)
      if (Model.hasOwn(routes, key)) next[key] = routes[key]
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
    streamRouteSetProc.command = runtime.scriptCommand("audio-stream-route-set", [
      direction,
      streamSerialValue,
      route.sink,
      route.mode
    ])
    streamRouteSetProc.running = true
  }

  property var lastManualRouteSync: null

  function deviceNameForSerial(list, serial) {
    var match = ""
    var matches = 0
    for (var i = 0; i < list.length && i < 512; i++) {
      var node = list[i]
      if (!node || Model.nodeSerial(node) !== String(serial)) continue
      matches++
      match = Model.nodeName(node)
      if (matches > 1) return ""
    }
    return matches === 1 ? match : ""
  }

  // Enforcement runs outside the panel too: rules matter most when an
  // application starts while the mixer is closed. A per-stream cache keeps
  // a satisfied rule from issuing repeated moves.
  readonly property var enforceableGroups: [
    { nodes: audioStreams, direction: "playback", devices: routingSinks },
    { nodes: recordingStreams, direction: "recording", devices: routingSources }
  ]
  property var enforcedStreamRoutes: ({})

  function resetRoutingEnforcement() {
    enforcedStreamRoutes = ({})
  }

  function pruneRoutingEnforcement() {
    var live = ({})
    for (var g = 0; g < enforceableGroups.length; g++) {
      var group = enforceableGroups[g]
      for (var i = 0; i < group.nodes.length; i++) {
        var serial = Model.uniqueNodeSerial(group.nodes, group.nodes[i])
        var objectId = Model.nodeObjectId(group.nodes[i])
        var key = group.direction + ":" + serial + ":" + objectId
        if (serial !== "" && objectId !== "" && Model.hasOwn(enforcedStreamRoutes, key))
          live[key] = enforcedStreamRoutes[key]
      }
    }
    enforcedStreamRoutes = live
  }

  function enforceRoutingRules() {
    if (!rulesLoaded || rulesStore.busy || sceneController.busy
        || outputGroups.busy
        || defaultSinkProc.running || defaultSourceProc.running || streamRouteSetProc.running
        || pendingStreamRoute || streamOutputMenuOpen) return
    pruneRoutingEnforcement()
    for (var g = 0; g < enforceableGroups.length; g++) {
      var group = enforceableGroups[g]
      for (var i = 0; i < group.nodes.length; i++) {
        var node = group.nodes[i]
        if (!mutableAudioNode(node)) continue
        var serial = Model.uniqueNodeSerial(group.nodes, node)
        var streamObjectId = Model.nodeObjectId(node)
        if (serial === "" || streamObjectId === "") continue
        var rule = Model.findAppRule(audioRules.appRules, group.direction, rawStreamLabel(node))
        if (!rule) continue
        var cacheKey = group.direction + ":" + serial + ":" + streamObjectId

        var targetNode = null
        var targetMatches = 0
        for (var d = 0; d < group.devices.length; d++) {
          if (Model.nodeName(group.devices[d]) === rule.target) {
            targetMatches++
            targetNode = group.devices[d]
            if (targetMatches > 1) break
          }
        }
        // An absent target falls back to WirePlumber's own choice; the rule
        // is enforced the moment the device appears.
        if (targetMatches !== 1 || !mutableAudioNode(targetNode)) continue
        var targetSerial = Model.uniqueNodeSerial(group.devices, targetNode)
        var targetObjectId = Model.nodeObjectId(targetNode)
        if (targetSerial === "" || targetObjectId === "") continue
        var targetIdentity = JSON.stringify([rule.target, targetSerial, targetObjectId])
        if (Model.mapValue(enforcedStreamRoutes, cacheKey, "") === targetIdentity) continue

        enforcedStreamRoutes[cacheKey] = targetIdentity
        streamRouteSetProc.command = runtime.scriptCommand("audio-stream-route-set", [
          group.direction,
          serial,
          targetSerial,
          "override"
        ])
        streamRouteSetProc.running = true
        return
      }
    }
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
    if (!hasOutput) return ""
    if (isHeadphones(sink)) return "󰋋"
    if (outputMuted) return ""
    var v = volume === undefined ? outputVolume : volume
    if (v >= 0.67) return ""
    if (v >= 0.34) return ""
    if (v > 0) return ""
    return ""
  }

  function inputIcon() {
    if (!hasInput) return "󰍭"
    return inputMuted ? "󰍭" : "󰍬"
  }

  // Playful mood-name for a given output volume. Mirrors the brightness
  // panel's brightnessName ladder; bands are wide enough that small
  // tweaks don't rename the room you're in.
  function outputVolumeName(volume, muted) {
    return Model.outputVolumeName(volume, muted)
  }

  function setOutputVolume(v) {
    if (directDeviceMutationBusy || !mutableAudioNode(volumeSink)) return outputVolume
    var requested = Number(v)
    if (!isFinite(requested)) return outputVolume
    var volume = Math.max(0, Math.min(outputVolumeMaximum, requested))
    return setAudioNodeVolume(volumeSink, volume, outputVolumeMaximum) ? volume : outputVolume
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
    if (directDeviceMutationBusy || !mutableAudioNode(source)) return inputVolume
    var requested = Number(v)
    if (!isFinite(requested)) return inputVolume
    var volume = Math.max(0, Math.min(1, requested))
    return setAudioNodeVolume(source, volume, 1) ? volume : inputVolume
  }

  function toggleOutputMute() {
    if (!directDeviceMutationBusy) toggleAudioNodeMute(volumeSink)
  }

  function toggleInputMute() {
    if (!directDeviceMutationBusy) toggleAudioNodeMute(source)
  }

  // The hero switch is the whole panel's on/off, so it carries both channels
  // at once. It reads as on while anything is still audible, which keeps
  // muting a single channel from the row below flipping the master switch.
  function toggleAllMuted() {
    if (directDeviceMutationBusy) return
    var mute = anyAudible
    if (hasOutput) setAudioNodeMuted(volumeSink, mute)
    if (hasInput) setAudioNodeMuted(source, mute)
  }

  function scheduleOutputTopologyRecovery() {
    outputTopologyRecoveryTimer.restart()
  }

  function recoverDegradedDefaultGroup() {
    if (outputTopologyRecoveryBusy) return false
    var currentSinkName = Model.nodeName(sink)
    var group = rulesStore.groupForSink(currentSinkName)
    if (!group || rulesStore.outputGroupAvailable(group)) return false

    var topology = serialSignature(rulesStore.physicalSinks)
    if (degradedGroupFallbackBlockedSink === group.sink
        && degradedGroupFallbackBlockedTopology === topology) return false

    var fallback = rulesStore.outputGroupFallbackNode(group)
    if (!mutableAudioNode(fallback)) return false
    degradedGroupFallbackFrom = group.sink
    if (setDefaultSink(fallback)) return true
    degradedGroupFallbackFrom = ""
    return false
  }

  function setDefaultSink(node) {
    var objectId = Model.nodeObjectId(node)
    var name = Model.nodeName(node)
    if (!mutableAudioNode(node) || objectId === "" || name === ""
        || sceneController.busy || routeMutationBusy) return false
    var previousSinkName = Model.nodeName(sink)
    var previousSinkObjectId = Model.nodeObjectId(sink)
    defaultOutputError = ""
    defaultSinkProc.command = runtime.scriptCommand("audio-output-set-default", [
      objectId,
      name,
      previousSinkName,
      previousSinkObjectId
    ])
    defaultSinkProc.running = true
    return true
  }

  function setDefaultSource(node) {
    var objectId = Model.nodeObjectId(node)
    var name = Model.nodeName(node)
    if (!mutableAudioNode(node) || objectId === "" || name === ""
        || sceneController.busy || routeMutationBusy) return
    var previousSourceName = Model.nodeName(source)
    var previousSourceObjectId = Model.nodeObjectId(source)
    defaultInputError = ""
    defaultSourceProc.command = runtime.scriptCommand("audio-input-set-default", [
      objectId,
      name,
      previousSourceName,
      previousSourceObjectId
    ])
    defaultSourceProc.running = true
  }

  function sinkAvailable(node) {
    var name = Model.nodeName(node)
    if (name === "" || !sinkAvailabilityLoaded) return true
    return Model.mapValue(sinkAvailability, name, true) !== false
  }

  function updateSinkAvailability(raw) {
    sinkAvailability = Model.parseSinkAvailability(raw)
    sinkAvailabilityLoaded = true
  }

  function friendlyDeviceLabel(text) {
    return Model.friendlyDeviceLabel(text)
  }

  function deviceAlias(name) {
    return rulesStore.aliasFor(name)
  }

  function deviceHidden(name) {
    return rulesStore.isHidden(name)
  }

  function nodeLabel(node) {
    var name = Model.nodeName(node)
    if (name !== "") {
      var alias = deviceAlias(name)
      if (alias !== "") return alias
    }
    return Model.nodeLabel(node)
  }

  function routeNodeLabel(node) {
    var label = nodeLabel(node)
    return Model.isOutputGroupSink(node) ? label + " · Output group" : label
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
    var themed = Quickshell.iconPath(name, true)
    if (themed) return themed
    if (appLibrary && appLibrary.iconIndex
        && Model.mapValue(appLibrary.iconIndex, name, null)
        && typeof appLibrary.iconSource === "function") return appLibrary.iconSource(name)
    return ""
  }

  function streamRepresentsPlayer(node, player) {
    return Model.streamRepresentsPlayer(node, player, mprisPlayers, displayAudioStreams)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PwNodePeakMonitor {
    id: inputPeakMonitor
    node: root.source
    enabled: (root.opened || root.recordingApplicationCount > 0) && !!root.source
  }

  FileView {
    id: settingsFile
    path: runtime.settingsPath
    watchChanges: true
    printErrors: false
    onLoaded: function() {
      var raw = text()
      if (!Model.isAudioControlSettingsDocument(raw)) {
        if (!root.audioControlSettingsLoaded) {
          root.loadAudioControlSettings("")
          root.audioControlSettingsLoaded = true
        }
        return
      }
      root.loadAudioControlSettings(raw)
      root.audioControlSettingsLoaded = true
    }
    onLoadFailed: if (!root.audioControlSettingsLoaded) {
      root.loadAudioControlSettings("")
      root.audioControlSettingsLoaded = true
    }
    onFileChanged: reload()
  }

  FileView {
    path: runtime.preferencesPath
    watchChanges: true
    printErrors: false
    onLoaded: function() {
      var raw = text()
      if (!Model.isAudioPreferencesDocument(raw)) {
        if (!root.audioPreferencesLoaded) {
          root.loadAudioPreferences("")
          root.audioPreferencesLoaded = true
        }
        return
      }
      root.loadAudioPreferences(raw)
      root.audioPreferencesLoaded = true
    }
    onLoadFailed: if (!root.audioPreferencesLoaded) {
      root.loadAudioPreferences("")
      root.audioPreferencesLoaded = true
    }
    onFileChanged: reload()
  }

  FileView {
    path: runtime.scenesPath
    watchChanges: true
    printErrors: false
    onLoaded: function() {
      var raw = text()
      if (!Model.isAudioScenesDocument(raw)) {
        if (!root.audioScenesLoaded) root.audioScenes = []
        root.audioScenesLoaded = true
        return
      }
      root.audioScenes = Model.parseAudioScenes(raw).scenes
      root.audioScenesLoaded = true
    }
    onLoadFailed: function() {
      if (!root.audioScenesLoaded) root.audioScenes = []
      root.audioScenesLoaded = true
    }
    onFileChanged: reload()
  }

  AudioSceneController {
    id: sceneController
    scriptsDir: runtime.scriptsDir
    outputVolumeMaximum: root.outputVolumeMaximum
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
    if (!scene || sceneMutationBusy) return
    sceneController.apply(scene)
  }

  Process {
    id: sinkAvailabilityProc
    command: runtime.scriptCommand("audio-sink-availability")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: sinkAvailabilityProc.response = String(text || "")
    }
    property string response: ""
    onExited: function(exitCode) {
      if (exitCode === 0) root.updateSinkAvailability(response)
      response = ""
    }
  }

  // Capture notifications are best-effort; probe once so a missing
  // notify-send never turns into repeated spawn failures.
  Process {
    id: notificationProbeProc
    running: true
    command: ["/bin/sh", "-c", "command -v notify-send >/dev/null 2>&1"]
    onExited: function(exitCode) { root.notificationsAvailable = exitCode === 0 }
  }

  Process {
    id: volumeSinkProc
    property string response: ""
    property string requestedDefaultName: ""
    property string requestedDefaultObjectId: ""
    command: runtime.scriptCommand("audio-resolve-output-sink")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: volumeSinkProc.response = String(text || "").trim()
    }
    onExited: function(exitCode) {
      var resolved = Model.sanitizeIdentifier(response, 160)
      var currentDefaultName = Model.nodeName(root.sink)
      var currentDefaultObjectId = Model.nodeObjectId(root.sink)
      var requestStillCurrent = requestedDefaultName === currentDefaultName
        && requestedDefaultObjectId === currentDefaultObjectId
      var retry = root.volumeSinkResolvePending || !requestStillCurrent
      if (requestStillCurrent)
        root.volumeSinkName = exitCode === 0 && resolved !== "" ? resolved : ""
      response = ""
      requestedDefaultName = ""
      requestedDefaultObjectId = ""
      root.volumeSinkResolvePending = false
      if (retry) Qt.callLater(root.resolveVolumeSink)
    }
  }

  Process {
    id: defaultSinkProc
    onExited: function(exitCode) {
      var fallbackFrom = root.degradedGroupFallbackFrom
      root.degradedGroupFallbackFrom = ""
      root.defaultOutputError = exitCode === 0 ? ""
        : (exitCode === 2 ? "Default output changed, but its preference could not be saved"
          : (exitCode === 4 ? "Default output change could not be fully restored"
            : "Could not change the default audio output"))
      if (fallbackFrom === "") return

      if (Model.nodeName(root.sink) !== fallbackFrom) {
        root.degradedGroupFallbackBlockedSink = ""
        root.degradedGroupFallbackBlockedTopology = ""
        root.scheduleOutputTopologyRecovery()
      } else {
        root.degradedGroupFallbackBlockedSink = fallbackFrom
        root.degradedGroupFallbackBlockedTopology = root.serialSignature(
          rulesStore.physicalSinks)
        outputTopologyRecoveryTimer.stop()
        outputGroups.scheduleReconcile()
      }
    }
  }

  Process {
    id: defaultSourceProc
    onExited: function(exitCode) {
      root.defaultInputError = exitCode === 0 ? ""
        : (exitCode === 2 ? "Default input changed, but its preference could not be saved"
          : (exitCode === 4 ? "Default input change could not be fully restored"
            : "Could not change the default audio input"))
    }
  }

  Process {
    id: streamRoutesProc
    property string response: ""
    command: runtime.scriptCommand("audio-stream-routes")
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: streamRoutesProc.response = String(text || "")
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.updateStreamRoutes(response)
      response = ""
      if (exitCode !== 0 && root.opened
          && (root.displayAudioStreams.length > 0 || root.displayRecordingStreams.length > 0))
        root.streamRouteReadError = "Could not read application routes"
    }
  }

  Process {
    id: streamRouteSetProc
    onExited: function(exitCode) {
      if (exitCode === 4)
        root.streamRouteSetError = "Application route changed and its previous state could not be fully restored"
      else if (exitCode !== 0) root.streamRouteSetError = "Could not change the application route"
      else root.streamRouteSetError = ""
      root.pendingStreamRoute = null

      // Persist manual edits of ruled applications; unruled applications
      // keep WirePlumber's native per-stream restoration.
      var sync = root.lastManualRouteSync
      root.lastManualRouteSync = null
      if (exitCode === 0 && sync) {
        var args = sync.target === ""
          ? ["del-app", sync.app, sync.direction]
          : ["set-app", sync.app, sync.direction, sync.target]
        if (!rulesStore.write(args)) {
          root.streamRouteSetError = "Application route changed, but its saved rule could not be updated"
          root.resetRoutingEnforcement()
        }
      }

      // A failed enforcement would otherwise stay cached as satisfied.
      if (exitCode !== 0) root.resetRoutingEnforcement()
      streamRouteRefreshTimer.restart()
      Qt.callLater(root.enforceRoutingRules)
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
    id: outputTopologyRecoveryTimer
    interval: 350
    repeat: false
    onTriggered: {
      if (!root.rulesLoaded) return
      if (root.outputTopologyRecoveryBusy) {
        restart()
        return
      }
      if (!root.recoverDegradedDefaultGroup()) outputGroups.scheduleReconcile()
    }
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
            if (!sceneController.busy) root.toggleAudioNodeMute(s)
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
                enabled: !root.sceneMutationBusy
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
                    enabled: !root.sceneMutationBusy
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
                enabled: root.hasOutput && !root.directDeviceMutationBusy

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
              model: root.displayAudioSinks.length

              AudioSinkRow {
                id: sinkDelegate
                required property int index
                width: panelColumn.width
                node: root.displayAudioSinks[index]
                rowIndex: index
                bar: root.bar
                preferredName: root.preferredOutputName
                label: root.nodeLabel(sinkDelegate.node)
                outputGroup: Model.isOutputGroupSink(sinkDelegate.node)
                defaultSetBusy: root.sceneMutationBusy
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
            visible: root.displayAudioSources.length > 0 || root.hasInput
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.displayAudioSources.length > 0 || root.hasInput

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
              visible: root.hasInput
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
                  enabled: root.hasInput && !root.directDeviceMutationBusy

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
              model: root.displayAudioSources.length

              AudioSourceRow {
                id: sourceDelegate
                required property int index
                width: panelColumn.width
                node: root.displayAudioSources[index]
                rowIndex: index
                bar: root.bar
                preferredName: root.preferredInputName
                label: root.nodeLabel(sourceDelegate.node)
                defaultSetBusy: root.sceneMutationBusy
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
              model: root.displayAudioStreams.length

              AudioStreamRow {
                id: streamDelegate
                required property int index
                width: panelColumn.width
                node: root.displayAudioStreams[index]
                nodeLive: root.mutableAudioNode(streamDelegate.node)
                rowIndex: index
                recording: false
                bar: root.bar
                monitorEnabled: root.opened
                representsPlayer: root.streamRepresentsPlayer(streamDelegate.node, root.activeMediaPlayer)
                currentRoute: streamDelegate.recording
                  ? root.recordingStreamRoute(streamDelegate.node)
                  : root.streamRoute(streamDelegate.node)
                routeOptions: streamDelegate.recording
                  ? root.recordingInputOptions : root.streamOutputOptions
                streamLabel: streamDelegate.recording
                  ? root.recordingStreamLabel(streamDelegate.node)
                  : root.streamLabel(streamDelegate.node)
                iconSource: root.streamIconSource(streamDelegate.node)
                routeAvailable: root.streamSerial(streamDelegate.node) !== ""
                routeSetBusy: streamRouteSetProc.running
                  || defaultSinkProc.running || defaultSourceProc.running
                  || root.pendingStreamRoute !== null || rulesStore.busy
                mutationBlocked: sceneController.busy
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
                onVolumeRequested: function(value) {
                  root.setAudioNodeVolume(streamDelegate.node, value, 1.5)
                }
                onMuteRequested: root.toggleAudioNodeMute(streamDelegate.node)
                onRouteChosen: function(route) {
                  root.setStreamRoute(streamDelegate.node, route,
                    streamDelegate.recording ? "recording" : "playback")
                }
                onPopupToggled: function(open) {
                  root.updateStreamOutputMenu(open)
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
              model: root.displayRecordingStreams.length

              AudioStreamRow {
                id: recordingStreamDelegate
                required property int index
                width: panelColumn.width
                node: root.displayRecordingStreams[index]
                nodeLive: root.mutableAudioNode(recordingStreamDelegate.node)
                rowIndex: index
                recording: true
                bar: root.bar
                monitorEnabled: root.opened
                representsPlayer: root.streamRepresentsPlayer(recordingStreamDelegate.node, root.activeMediaPlayer)
                currentRoute: recordingStreamDelegate.recording
                  ? root.recordingStreamRoute(recordingStreamDelegate.node)
                  : root.streamRoute(recordingStreamDelegate.node)
                routeOptions: recordingStreamDelegate.recording
                  ? root.recordingInputOptions : root.streamOutputOptions
                streamLabel: recordingStreamDelegate.recording
                  ? root.recordingStreamLabel(recordingStreamDelegate.node)
                  : root.streamLabel(recordingStreamDelegate.node)
                iconSource: root.streamIconSource(recordingStreamDelegate.node)
                routeAvailable: root.streamSerial(recordingStreamDelegate.node) !== ""
                routeSetBusy: streamRouteSetProc.running
                  || defaultSinkProc.running || defaultSourceProc.running
                  || root.pendingStreamRoute !== null || rulesStore.busy
                mutationBlocked: sceneController.busy
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
                onVolumeRequested: function(value) {
                  root.setAudioNodeVolume(recordingStreamDelegate.node, value, 1.5)
                }
                onMuteRequested: root.toggleAudioNodeMute(recordingStreamDelegate.node)
                onRouteChosen: function(route) {
                  root.setStreamRoute(recordingStreamDelegate.node, route,
                    recordingStreamDelegate.recording ? "recording" : "playback")
                }
                onPopupToggled: function(open) {
                  root.updateStreamOutputMenu(open)
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
