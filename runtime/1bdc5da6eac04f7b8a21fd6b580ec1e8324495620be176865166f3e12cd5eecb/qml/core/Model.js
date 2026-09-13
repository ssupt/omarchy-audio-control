function isPlaybackStream(node) {
  try {
    if (!node || !node.isStream) return false
    if (node.isSink === true) return true
    if (node.isSink === false) return false

    var mediaClass = String(node.type || "")
    return mediaClass.indexOf("Stream/Output/Audio") !== -1
      || mediaClass.indexOf("AudioOutStream") !== -1
      || mediaClass.indexOf("Output") !== -1
  } catch (e) {
    return false
  }
}

function isRecordingStream(node) {
  try {
    if (!node || !node.isStream) return false
    if (node.isSink === false) return true
    if (node.isSink === true) return false

    var mediaClass = String(node.type || "")
    return mediaClass.indexOf("Stream/Input/Audio") !== -1
      || mediaClass.indexOf("AudioInStream") !== -1
      || mediaClass.indexOf("Input") !== -1
  } catch (e) {
    return false
  }
}

function isAudioSource(node) {
  try {
    if (!node || node.isStream || node.isSink === true) return false

    var mediaClass = String(node.type || "")
    if (mediaClass.indexOf("Audio/Source") !== -1
      || mediaClass.indexOf("AudioSource") !== -1
      || mediaClass.indexOf("Source") !== -1) return true

    // Quickshell supplies isSink=false for real capture endpoints. Merely
    // exposing an audio interface is not enough: filter/control nodes can also
    // have one and must never be presented as microphones.
    return node.isSink === false && !!node.audio
  } catch (e) {
    return false
  }
}

function isInternalAudioNode(name, properties) {
  try {
    var value = String(name || "").trim().toLowerCase()
    var props = properties && typeof properties === "object" ? properties : {}
    return value === "quickshell"
      || value.indexOf("omarchy_audio_test") === 0
      || value.indexOf("omarchy_speaker_tuning") === 0
      || value.indexOf("omarchy_audio_group_") === 0
      || value.indexOf("output.omarchy_audio_group_") === 0
      || String(props["application.id"] || "") === "ssupt.audio-control"
  } catch (e) {
    return false
  }
}

function isMonitorSource(node) {
  try {
    if (!node) return false
    var name = nodeName(node).toLowerCase()
    var properties = nodeProps(node)
    return name.endsWith(".monitor")
      || String(properties["device.class"] || "").toLowerCase() === "monitor"
  } catch (e) {
    return false
  }
}

// Keep PipeWire classification in one place so every surface excludes the
// plugin's own streams and monitor sources consistently. QML list properties
// are array-like rather than true Arrays, hence the length-based input check.
function classifyAudioNodes(nodes) {
  var values = nodes && typeof nodes.length === "number" ? nodes : []
  var result = { sinks: [], sources: [], playbackStreams: [], recordingStreams: [] }
  for (var i = 0; i < values.length && i < 4096; i++) {
    try {
      var node = values[i]
      if (!node) continue
      // PipeWire's Pulse compatibility layer exposes module-combine-sink as
      // both a sink and a live stream. Quickshell therefore reports isStream
      // on some versions even though this is the user-selectable endpoint.
      // Recognize only our fully marked endpoint before classifying streams.
      if (isOutputGroupSink(node) && node.isSink === true) {
        // An unbound endpoint has no properties yet. Track the exact reserved
        // name once so PwObjectTracker can bind it, then require all ownership
        // markers as soon as it becomes ready.
        if (result.sinks.length < 512
            && (node.ready !== true || isManagedOutputGroupSink(node)))
          result.sinks.push(node)
        continue
      }
      if (node.isStream) {
        if (isInternalAudioNode(nodeName(node), nodeProps(node))) continue
        if (isPlaybackStream(node) && result.playbackStreams.length < 512)
          result.playbackStreams.push(node)
        else if (isRecordingStream(node) && result.recordingStreams.length < 512)
          result.recordingStreams.push(node)
        continue
      }
      if (node.isSink === true && result.sinks.length < 512
          && !isInternalAudioNode(nodeName(node), nodeProps(node))) result.sinks.push(node)
      else if (result.sources.length < 512 && isAudioSource(node)
          && !isInternalAudioNode(nodeName(node), nodeProps(node)) && !isMonitorSource(node))
        result.sources.push(node)
    } catch (e) { }
  }
  return result
}

function listSnapshot(list) {
  var result = []
  try {
    var values = list && typeof list.length === "number" ? list : []
    for (var i = 0; i < values.length && i < 4096; i++) result.push(values[i])
  } catch (e) { }
  return result
}

// Configuration files contain user- and service-provided strings that become
// object keys. Plain property lookup is unsafe for names such as "constructor"
// or "__proto__", because those can resolve through (or mutate) Object's
// prototype instead of representing a real stored entry.
function hasOwn(object, key) {
  return !!object && Object.prototype.hasOwnProperty.call(object, String(key))
}

function mapValue(object, key, fallback) {
  return hasOwn(object, key) ? object[String(key)] : fallback
}

function setMapValue(object, key, value) {
  Object.defineProperty(object, String(key), {
    value: value,
    writable: true,
    enumerable: true,
    configurable: true
  })
}

function boundedSerializedInput(raw, maximumLength) {
  var text = String(raw === undefined || raw === null ? "" : raw)
  return text.length <= maximumLength ? text : null
}

function storedObjectDocument(raw, maximumLength) {
  var text = boundedSerializedInput(raw, maximumLength)
  if (text === null || text.trim() === "") return null
  try {
    var parsed = JSON.parse(text)
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed : null
  } catch (e) {
    return null
  }
}

function hasVersionOneOrNone(parsed) {
  return !hasOwn(parsed, "version") || parsed.version === 1
}

// FileView can observe an atomic replacement between rename/watch events and
// briefly fail or expose malformed external edits. These validators let the
// QML surfaces retain their last known-good state instead of interpreting a
// transient read as a request to reset every preference.
function isAudioPreferencesDocument(raw) {
  var parsed = storedObjectDocument(raw, 1048576)
  if (!parsed || !hasVersionOneOrNone(parsed)) return false
  if (hasOwn(parsed, "defaults") && (!parsed.defaults
      || typeof parsed.defaults !== "object" || Array.isArray(parsed.defaults))) return false
  if (hasOwn(parsed, "bluetoothProfiles") && (!parsed.bluetoothProfiles
      || typeof parsed.bluetoothProfiles !== "object"
      || Array.isArray(parsed.bluetoothProfiles))) return false
  return true
}

function isAudioControlSettingsDocument(raw) {
  var parsed = storedObjectDocument(raw, 65536)
  if (!parsed || !hasVersionOneOrNone(parsed)) return false
  if (hasOwn(parsed, "outputOverdrive") && typeof parsed.outputOverdrive !== "boolean")
    return false
  if (hasOwn(parsed, "captureNotifications")
      && typeof parsed.captureNotifications !== "boolean") return false
  return true
}

function isAudioScenesDocument(raw) {
  var parsed = storedObjectDocument(raw, 2097152)
  return !!parsed && hasVersionOneOrNone(parsed)
    && (!hasOwn(parsed, "scenes") || Array.isArray(parsed.scenes))
}

function isAudioRulesDocument(raw) {
  var parsed = storedObjectDocument(raw, 1048576)
  if (!parsed || !hasVersionOneOrNone(parsed)) return false
  if (hasOwn(parsed, "appRules") && !Array.isArray(parsed.appRules)) return false
  if (hasOwn(parsed, "outputGroups") && !Array.isArray(parsed.outputGroups)) return false
  if (hasOwn(parsed, "devices") && (!parsed.devices
      || typeof parsed.devices !== "object" || Array.isArray(parsed.devices))) return false
  return true
}

function normalizedBluetoothAddress(value) {
  return String(value || "").trim().toLowerCase().replace(/[^0-9a-f]/g, "")
}

function parseAudioPreferences(raw) {
  var parsed
  var text = boundedSerializedInput(raw, 1048576)
  try {
    parsed = text === null ? {} : JSON.parse(text || "{}")
  } catch (e) {
    parsed = {}
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}

  var defaults = parsed.defaults
  if (!defaults || typeof defaults !== "object" || Array.isArray(defaults)) defaults = {}
  var rawProfiles = parsed.bluetoothProfiles
  if (!rawProfiles || typeof rawProfiles !== "object" || Array.isArray(rawProfiles)) rawProfiles = {}

  var profiles = {}
  var inspectedProfiles = 0
  for (var address in rawProfiles) {
    if (inspectedProfiles++ >= 512 || Object.keys(profiles).length >= 128) break
    if (!hasOwn(rawProfiles, address)) continue
    var key = normalizedBluetoothAddress(address)
    var profile = typeof rawProfiles[address] === "string"
      ? sanitizeIdentifier(rawProfiles[address], 160) : ""
    if (/^[0-9a-f]{12}$/.test(key) && profile !== "" && !hasOwn(profiles, key))
      setMapValue(profiles, key, profile)
  }

  return {
    version: 1,
    defaults: {
      output: typeof defaults.output === "string"
        ? sanitizeIdentifier(defaults.output, 160) : "",
      input: typeof defaults.input === "string"
        ? sanitizeIdentifier(defaults.input, 160) : ""
    },
    bluetoothProfiles: profiles
  }
}

function preferredAudioProfile(preferences, address, options, activeProfile) {
  var profiles = preferences && preferences.bluetoothProfiles
  var saved = profiles
    ? String(mapValue(profiles, normalizedBluetoothAddress(address), "") || "") : ""
  var values = options && typeof options.length === "number" ? options : []
  for (var i = 0; i < values.length && i < 256; i++) {
    var value = values[i] && typeof values[i] === "object" ? values[i].value : values[i]
    if (String(value || "") === saved) return saved
  }
  return String(activeProfile || "")
}

function preferredAudioNodeName(preferences, direction, liveNode, nodes) {
  var defaults = preferences && preferences.defaults
  var saved = defaults && (direction === "output" || direction === "input")
    ? String(defaults[direction] || "") : ""
  var values = nodes && typeof nodes.length === "number" ? nodes : []
  if (saved !== "") {
    var savedMatches = 0
    for (var i = 0; i < values.length && i < 4096; i++) {
      try {
        if (nodeName(values[i]) === saved) savedMatches++
      } catch (e) { }
      if (savedMatches > 1) break
    }
    if (savedMatches === 1) return saved
  }

  // A name is the persisted identity used by the default-device helpers. A
  // transient duplicate must not make two rows look selected or invite a
  // mutation the helper will (correctly) reject as ambiguous.
  var liveName = nodeName(liveNode)
  if (liveName === "") return ""
  var liveMatches = 0
  for (i = 0; i < values.length && i < 4096; i++) {
    try {
      if (nodeName(values[i]) === liveName) liveMatches++
    } catch (e) { }
    if (liveMatches > 1) return ""
  }
  return liveName
}

function parseAudioControlSettings(raw) {
  var parsed
  var text = boundedSerializedInput(raw, 65536)
  try {
    parsed = text === null ? {} : JSON.parse(text || "{}")
  } catch (e) {
    parsed = {}
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}
  return {
    version: 1,
    outputOverdrive: parsed.outputOverdrive === true,
    captureNotifications: parsed.captureNotifications !== false
  }
}

// Bare shell summons are the same gesture Omarchy uses for its built-in audio
// pullout. Advanced views must opt in so a cloned replacement does not turn
// SUPER+CTRL+A into a settings-window shortcut. A recognized tab also counts
// as an explicit advanced request for companion plugins and old deep links.
function parseAudioOpenRequest(raw) {
  var result = { advanced: false, tab: 0 }
  var text = boundedSerializedInput(raw, 4096)
  if (text === null) return result

  var parsed
  try {
    parsed = JSON.parse(text || "{}")
  } catch (e) {
    return result
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return result
  if (parsed.view === "quick") return result

  var tabs = {
    devices: 0,
    bluetooth: 1,
    policy: 2,
    scenes: 3,
    routing: 4,
    diagnostics: 5
  }
  var tabName = typeof parsed.tab === "string" ? parsed.tab : ""
  var tab = mapValue(tabs, tabName, -1)
  return {
    advanced: parsed.view === "advanced" || parsed.advanced === true || tab >= 0,
    tab: tab >= 0 ? tab : 0
  }
}

function clampNumber(value, fallback, minimum, maximum) {
  var number = Number(value)
  if (!isFinite(number)) return fallback
  return Math.max(minimum, Math.min(maximum, number))
}

function sanitizeSceneString(value, fallback, maximumLength) {
  var text = String(value === undefined || value === null ? "" : value).trim()
  text = text.replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u2028-\u202e\u2066-\u2069]/g, " ")
    .replace(/ +/g, " ").trim()
  if (text === "") return fallback
  if (maximumLength && text.length > maximumLength) text = text.substring(0, maximumLength)
  return text
}

// Identifiers are passed back to PipeWire and must remain byte-for-byte equal
// to what it published. Labels can be cleaned for display, but silently
// trimming, truncating, or replacing characters in a node/profile identifier
// produces a preference that can never match the live object. Reject those
// identifiers instead.
function sanitizeIdentifier(value, maximumLength) {
  if (typeof value !== "string" || value === ""
      || (maximumLength && value.length > maximumLength)
      || /[\u0000-\u001f\u007f-\u009f\u200e\u200f\u2028-\u202e\u2066-\u2069]/.test(value))
    return ""
  return value
}

function normalizeAppKey(value) {
  return sanitizeSceneString(value, "", 120).replace(/[A-Z]/g, function(letter) {
    return letter.toLowerCase()
  })
}

function sanitizeSceneEntry(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null
  var name = sanitizeSceneString(raw.name, "", 48)
  if (name === "") return null

  var defaults = raw.defaults && typeof raw.defaults === "object" && !Array.isArray(raw.defaults)
    ? raw.defaults : {}
  var devices = []
  var seenDevices = {}
  var rawDevices = Array.isArray(raw.devices) ? raw.devices : []
  for (var i = 0; i < rawDevices.length && i < 256 && devices.length < 64; i++) {
    var device = rawDevices[i]
    if (!device || typeof device !== "object") continue
    var deviceName = sanitizeIdentifier(device.name, 160)
    if (device.direction !== "input" && device.direction !== "output") continue
    var direction = device.direction
    var deviceKey = direction + ":" + deviceName
    if (deviceName === "" || hasOwn(seenDevices, deviceKey)) continue
    setMapValue(seenDevices, deviceKey, true)
    devices.push({
      name: deviceName,
      direction: direction,
      volume: clampNumber(device.volume, 1, 0, 1.5),
      // Scenes restore playback audibly: a captured output mute would
      // silently silence an unrelated future session, while microphone
      // muting is a deliberate privacy state worth restoring.
      muted: direction === "input" && device.muted === true,
      balance: clampNumber(device.balance, 0, -1, 1)
    })
  }

  var ports = []
  var seenPorts = {}
  var rawPorts = Array.isArray(raw.ports) ? raw.ports : []
  for (var j = 0; j < rawPorts.length && j < 256 && ports.length < 64; j++) {
    var port = rawPorts[j]
    if (!port || typeof port !== "object") continue
    var endpoint = sanitizeIdentifier(port.endpoint, 160)
    if (port.direction !== "input" && port.direction !== "output") continue
    var portDirection = port.direction
    var portValue = sanitizeIdentifier(port.value, 160)
    var portKey = portDirection + ":" + endpoint
    if (endpoint === "" || portValue === "" || hasOwn(seenPorts, portKey)) continue
    setMapValue(seenPorts, portKey, true)
    ports.push({ direction: portDirection, endpoint: endpoint, value: portValue })
  }

  var profiles = []
  var seenProfiles = {}
  var rawProfiles = Array.isArray(raw.profiles) ? raw.profiles : []
  for (var k = 0; k < rawProfiles.length && k < 256 && profiles.length < 64; k++) {
    var profile = rawProfiles[k]
    if (!profile || typeof profile !== "object") continue
    var card = sanitizeIdentifier(profile.card, 160)
    var profileValue = sanitizeIdentifier(profile.profile, 160)
    if (card === "" || profileValue === "" || hasOwn(seenProfiles, card)) continue
    // Restoring "off" would power down cards the user may have enabled since;
    // scenes choose how a card behaves when it is used, never whether it is.
    if (profileValue === "off") continue
    setMapValue(seenProfiles, card, true)
    profiles.push({ card: card, profile: profileValue })
  }

  return {
    name: name,
    savedAt: sanitizeSceneString(raw.savedAt, "", 32),
    defaults: {
      output: sanitizeIdentifier(defaults.output, 160),
      input: sanitizeIdentifier(defaults.input, 160)
    },
    devices: devices,
    ports: ports,
    profiles: profiles
  }
}

function parseAudioScenes(raw) {
  var parsed
  var text = boundedSerializedInput(raw, 2097152)
  try {
    parsed = text === null ? {} : JSON.parse(text || "{}")
  } catch (e) {
    parsed = {}
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}

  var scenes = []
  var rawScenes = Array.isArray(parsed.scenes) ? parsed.scenes : []
  var seen = {}
  for (var i = 0; i < rawScenes.length && i < 96 && scenes.length < 24; i++) {
    var scene = sanitizeSceneEntry(rawScenes[i])
    if (!scene || hasOwn(seen, scene.name)) continue
    setMapValue(seen, scene.name, true)
    scenes.push(scene)
  }
  return { version: 1, scenes: scenes }
}

function sceneSummary(scene) {
  if (!scene || typeof scene !== "object") return ""
  var parts = []
  var deviceCount = scene.devices ? scene.devices.length : 0
  if (deviceCount > 0)
    parts.push(deviceCount + (deviceCount === 1 ? " device" : " devices"))
  if (scene.defaults && scene.defaults.output && scene.defaults.input)
    parts.push("defaults")
  else if (scene.defaults && (scene.defaults.output || scene.defaults.input))
    parts.push("default " + (scene.defaults.output ? "output" : "input"))
  var portCount = scene.ports ? scene.ports.length : 0
  if (portCount > 0)
    parts.push(portCount + (portCount === 1 ? " port" : " ports"))
  var profileCount = scene.profiles ? scene.profiles.length : 0
  if (profileCount > 0)
    parts.push(profileCount + (profileCount === 1 ? " profile" : " profiles"))
  if (parts.length === 0) return "Empty scene"
  return parts.join(" · ")
}

function parseAudioRules(raw) {
  var parsed
  var text = boundedSerializedInput(raw, 1048576)
  try {
    parsed = text === null ? {} : JSON.parse(text || "{}")
  } catch (e) {
    parsed = {}
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}

  var appRules = []
  var rawRules = Array.isArray(parsed.appRules) ? parsed.appRules : []
  var seen = {}
  for (var i = 0; i < rawRules.length && i < 256 && appRules.length < 64; i++) {
    var rule = rawRules[i]
    if (!rule || typeof rule !== "object") continue
    var app = normalizeAppKey(rule.app)
    if (rule.direction !== "recording" && rule.direction !== "playback") continue
    var direction = rule.direction
    var target = sanitizeIdentifier(rule.target, 160)
    var ruleKey = direction + ":" + app
    if (app === "" || target === "" || hasOwn(seen, ruleKey)) continue
    setMapValue(seen, ruleKey, true)
    appRules.push({ app: app, direction: direction, target: target })
  }

  var outputGroups = []
  var rawGroups = Array.isArray(parsed.outputGroups) ? parsed.outputGroups : []
  var seenGroupIds = {}
  var seenGroupNames = {}
  var seenGroupMembers = {}
  for (i = 0; i < rawGroups.length && i < 64 && outputGroups.length < 16; i++) {
    var group = rawGroups[i]
    if (!group || typeof group !== "object" || Array.isArray(group)) continue
    var groupId = typeof group.id === "string" && /^[0-9a-f]{16}$/.test(group.id)
      ? group.id : ""
    var groupName = sanitizeSceneString(group.name, "", 48)
    var groupNameKey = normalizeAppKey(groupName)
    var expectedSink = groupId === "" ? "" : "omarchy_audio_group_" + groupId
    if (groupId === "" || groupName === "" || group.sink !== expectedSink
        || hasOwn(seenGroupIds, groupId) || hasOwn(seenGroupNames, groupNameKey)) continue

    var members = []
    var rawMembers = Array.isArray(group.members) ? group.members : []
    for (var m = 0; m < rawMembers.length && m < 32 && members.length < 8; m++) {
      var member = sanitizeIdentifier(rawMembers[m], 160)
      if (!/^[A-Za-z0-9_.:-]{1,160}$/.test(member)
          || /^omarchy_audio_group_[0-9a-f]{16}$/.test(member)
          || members.indexOf(member) !== -1) continue
      members.push(member)
    }
    members.sort()
    var memberKey = members.join("\u001f")
    if (members.length < 2 || hasOwn(seenGroupMembers, memberKey)) continue
    setMapValue(seenGroupIds, groupId, true)
    setMapValue(seenGroupNames, groupNameKey, true)
    setMapValue(seenGroupMembers, memberKey, true)
    outputGroups.push({
      id: groupId,
      name: groupName,
      sink: expectedSink,
      members: members
    })
  }

  var devices = parsed.devices && typeof parsed.devices === "object" && !Array.isArray(parsed.devices)
    ? parsed.devices : {}
  var aliases = {}
  if (devices.aliases && typeof devices.aliases === "object" && !Array.isArray(devices.aliases)) {
    var inspectedAliases = 0
    for (var nodeName in devices.aliases) {
      if (inspectedAliases++ >= 256 || Object.keys(aliases).length >= 128) break
      if (!hasOwn(devices.aliases, nodeName)) continue
      var alias = sanitizeSceneString(devices.aliases[nodeName], "", 80)
      var key = sanitizeIdentifier(nodeName, 160)
      if (key !== "" && alias !== "") setMapValue(aliases, key, alias)
    }
  }

  function stringList(value, maximum) {
    var out = []
    var rawList = Array.isArray(value) ? value : []
    for (var j = 0; j < rawList.length && j < 256 && out.length < maximum; j++) {
      var entry = sanitizeIdentifier(rawList[j], 160)
      if (entry !== "" && out.indexOf(entry) === -1) out.push(entry)
    }
    return out
  }

  return {
    version: 1,
    appRules: appRules,
    outputGroups: outputGroups,
    devices: {
      aliases: aliases,
      favorites: stringList(devices.favorites, 64),
      hidden: stringList(devices.hidden, 64)
    }
  }
}

function outputGroupForSink(groups, sinkName) {
  var values = Array.isArray(groups) ? groups : []
  var name = sanitizeIdentifier(sinkName, 160)
  if (name === "") return null
  for (var i = 0; i < values.length && i < 64; i++) {
    var group = values[i]
    if (group && group.sink === name) return group
  }
  return null
}

// Pick a deterministic physical destination when a selected output group is
// degraded. A duplicated live name is deliberately skipped: changing a
// default by name in that state could address the wrong PipeWire object.
function outputGroupFallbackMember(group, liveSinkNames) {
  var members = group && Array.isArray(group.members) ? group.members : []
  var live = Array.isArray(liveSinkNames) ? liveSinkNames : []
  for (var i = 0; i < members.length && i < 8; i++) {
    var member = sanitizeIdentifier(members[i], 160)
    if (member === "" || isOutputGroupSink(member)) continue
    var matches = 0
    for (var j = 0; j < live.length && j < 512; j++) {
      if (live[j] !== member) continue
      matches++
      if (matches > 1) break
    }
    if (matches === 1) return member
  }
  return ""
}

function isOutputGroupSink(value) {
  var name = typeof value === "string" ? value : nodeName(value)
  return /^omarchy_audio_group_[0-9a-f]{16}$/.test(String(name || ""))
}

function isManagedOutputGroupSink(node) {
  try {
    if (!node || node.isSink !== true || !isOutputGroupSink(node)) return false
    var name = nodeName(node)
    var groupId = name.substring("omarchy_audio_group_".length)
    var properties = nodeProps(node)
    var virtualValue = String(properties["node.virtual"] || "").toLowerCase()
    return String(properties["application.id"] || "") === "ssupt.audio-control"
      && String(properties["omarchy.audio.group.id"] || "") === groupId
      && (virtualValue === "true" || virtualValue === "1")
  } catch (e) {
    return false
  }
}

function isOutputGroupMemberSink(node) {
  try {
    if (!node || node.ready !== true || node.isSink !== true || node.isStream === true
        || isOutputGroupSink(node)) return false
    var properties = nodeProps(node)
    var virtualValue = String(properties["node.virtual"] || "").toLowerCase()
    var deviceClass = String(properties["device.class"] || "").toLowerCase()
    var factoryName = String(properties["factory.name"] || "").toLowerCase()
    return virtualValue !== "true" && virtualValue !== "1"
      && deviceClass !== "filter" && deviceClass !== "monitor"
      && factoryName.indexOf("null-audio-sink") === -1
      && factoryName.indexOf("filter-chain") === -1
      && String(properties["application.id"] || "") !== "ssupt.audio-control"
  } catch (e) {
    return false
  }
}

// Case-insensitive lookup: rules are matched against the labels applications
// publish, and those spellings vary across launches.
function findAppRule(rules, direction, appKey) {
  var key = normalizeAppKey(appKey)
  if (key === "") return null
  var values = Array.isArray(rules) ? rules : []
  for (var i = 0; i < values.length && i < 256; i++)
    if (values[i].direction === direction && values[i].app === key) return values[i]
  return null
}

function availableRuleApplicationLabels(playbackStreams, recordingStreams, rules) {
  var candidates = []

  function consider(node, direction) {
    try {
      if (!node || node.ready !== true || !node.audio) return
      var label = sanitizeSceneString(rawStreamLabel(node), "", 120)
      if (label === "") return
      var key = normalizeAppKey(label)
      var candidate = null
      for (var i = 0; i < candidates.length && i < 512; i++) {
        if (candidates[i].key === key) {
          candidate = candidates[i]
          break
        }
      }
      if (!candidate && candidates.length < 512) {
        candidate = { key: key, label: label, playback: false, recording: false }
        candidates.push(candidate)
      }
      if (!candidate) return
      candidate[direction] = true
    } catch (e) { }
  }

  var playback = playbackStreams && typeof playbackStreams.length === "number"
    ? playbackStreams : []
  var recording = recordingStreams && typeof recordingStreams.length === "number"
    ? recordingStreams : []
  var i
  for (i = 0; i < playback.length && i < 512; i++) consider(playback[i], "playback")
  for (i = 0; i < recording.length && i < 512; i++) consider(recording[i], "recording")

  var available = []
  for (i = 0; i < candidates.length && i < 512 && available.length < 512; i++) {
    var value = candidates[i]
    if ((value.playback && !findAppRule(rules, "playback", value.key))
        || (value.recording && !findAppRule(rules, "recording", value.key)))
      available.push(value.label)
  }
  return available
}

function deviceSortComparator(favorites) {
  var values = Array.isArray(favorites) ? favorites : []
  return function(a, b) {
    var aKey = ""
    var bKey = ""
    try { aKey = String(a && typeof a === "object" ? a.name || "" : a || "") }
    catch (e) { }
    try { bKey = String(b && typeof b === "object" ? b.name || "" : b || "") }
    catch (e) { }
    var ra = values.indexOf(aKey)
    var rb = values.indexOf(bKey)
    var fa = ra >= 0 ? 0 : 1
    var fb = rb >= 0 ? 0 : 1
    if (fa !== fb) return fa - fb
    if (fa === 0 && ra !== rb) return ra - rb
    return 0
  }
}

function emptyAudioDiagnostics() {
  return {
    version: 1,
    generatedAt: "",
    healthy: false,
    versions: { plugin: "", pipewire: "", wireplumber: "" },
    graph: {
      available: false,
      active: false,
      source: "configured",
      rate: 0,
      quantum: 0,
      latencyMs: 0,
      loadPercent: -1,
      errors: 0,
      activeNodes: 0
    },
    defaults: { output: "", input: "" },
    services: [],
    devices: [],
    routes: [],
    capabilities: {
      speakerTest: false,
      supportReport: false,
      clipboard: false,
      recovery: false,
      topology: false
    },
    warnings: []
  }
}

function parseAudioDiagnostics(raw) {
  var parsed
  var text = boundedSerializedInput(raw, 8388608)
  try {
    if (text === null) throw new Error("Audio diagnostics response is too large")
    parsed = JSON.parse(text)
  } catch (e) {
    return { valid: false, value: emptyAudioDiagnostics() }
  }
  return normalizeAudioDiagnostics(parsed)
}

// Service snapshots have already crossed the bounded JSON transport. Normalize
// their objects directly rather than stringify and parse a second full report.
function normalizeAudioDiagnostics(parsed) {
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)
      || parsed.version !== 1 || !parsed.graph || typeof parsed.graph !== "object"
      || !Array.isArray(parsed.services) || !Array.isArray(parsed.devices)
      || !Array.isArray(parsed.routes) || !Array.isArray(parsed.warnings))
    return { valid: false, value: emptyAudioDiagnostics() }

  var value = emptyAudioDiagnostics()
  value.generatedAt = sanitizeSceneString(parsed.generatedAt, "", 64)
  value.healthy = parsed.healthy === true

  var versions = parsed.versions && typeof parsed.versions === "object"
    ? parsed.versions : {}
  value.versions = {
    plugin: sanitizeSceneString(versions.plugin, "", 32),
    pipewire: sanitizeSceneString(versions.pipewire, "", 32),
    wireplumber: sanitizeSceneString(versions.wireplumber, "", 32)
  }

  var graph = parsed.graph && typeof parsed.graph === "object" ? parsed.graph : {}
  value.graph = {
    available: graph.available === true,
    active: graph.active === true,
    source: graph.source === "active" ? "active" : "configured",
    rate: Math.round(clampNumber(graph.rate, 0, 0, 768000)),
    quantum: Math.round(clampNumber(graph.quantum, 0, 0, 1048576)),
    latencyMs: clampNumber(graph.latencyMs, 0, 0, 60000),
    loadPercent: clampNumber(graph.loadPercent, -1, -1, 100000),
    errors: Math.round(clampNumber(graph.errors, 0, 0, 1000000000)),
    activeNodes: Math.round(clampNumber(graph.activeNodes, 0, 0, 1000000))
  }

  var defaults = parsed.defaults && typeof parsed.defaults === "object"
    ? parsed.defaults : {}
  value.defaults = {
    output: sanitizeSceneString(defaults.output, "", 240),
    input: sanitizeSceneString(defaults.input, "", 240)
  }

  var rawServices = Array.isArray(parsed.services) ? parsed.services : []
  for (var i = 0; i < rawServices.length && i < 32 && value.services.length < 8; i++) {
    var service = rawServices[i]
    if (!service || typeof service !== "object") continue
    var serviceName = sanitizeSceneString(service.name, "", 80)
    if (serviceName === "") continue
    value.services.push({
      name: serviceName,
      label: sanitizeSceneString(service.label, serviceName, 80),
      loadState: sanitizeSceneString(service.loadState, "unknown", 32),
      activeState: sanitizeSceneString(service.activeState, "unknown", 32),
      subState: sanitizeSceneString(service.subState, "unknown", 32),
      active: service.active === true,
      restarts: Math.round(clampNumber(service.restarts, 0, 0, 1000000))
    })
  }

  var rawDevices = Array.isArray(parsed.devices) ? parsed.devices : []
  for (var j = 0; j < rawDevices.length && j < 256 && value.devices.length < 64; j++) {
    var device = rawDevices[j]
    if (!device || typeof device !== "object") continue
    if (device.direction !== "input" && device.direction !== "output") continue
    var deviceName = sanitizeSceneString(device.name, "", 240)
    var label = sanitizeSceneString(device.label, deviceName, 160)
    if (deviceName === "" || label === "") continue
    value.devices.push({
      direction: device.direction,
      name: deviceName,
      label: label,
      state: sanitizeSceneString(device.state, "unknown", 32),
      format: sanitizeSceneString(device.format, "", 96),
      channelMap: sanitizeSceneString(device.channelMap, "", 240),
      channels: Math.round(clampNumber(device.channels, 0, 0, 64)),
      port: sanitizeSceneString(device.port, "", 160),
      profile: sanitizeSceneString(device.profile, "", 160),
      codec: sanitizeSceneString(device.codec, "", 64),
      bluetooth: device.bluetooth === true,
      default: device.default === true
    })
  }

  var rawRoutes = Array.isArray(parsed.routes) ? parsed.routes : []
  for (var k = 0; k < rawRoutes.length && k < 256 && value.routes.length < 64; k++) {
    var route = rawRoutes[k]
    if (!route || typeof route !== "object" || !Array.isArray(route.labels)) continue
    if (route.direction !== "recording" && route.direction !== "playback") continue
    var labels = []
    for (var l = 0; l < route.labels.length && labels.length < 16; l++) {
      var routeLabel = sanitizeSceneString(route.labels[l], "", 160)
      if (routeLabel !== "" && labels[labels.length - 1] !== routeLabel)
        labels.push(routeLabel)
    }
    if (labels.length < 2) continue
    value.routes.push({
      direction: route.direction,
      labels: labels
    })
  }

  var capabilities = parsed.capabilities && typeof parsed.capabilities === "object"
    ? parsed.capabilities : {}
  value.capabilities = {
    speakerTest: capabilities.speakerTest === true,
    supportReport: capabilities.supportReport === true,
    clipboard: capabilities.clipboard === true,
    recovery: capabilities.recovery === true,
    topology: capabilities.topology === true
  }

  var rawWarnings = Array.isArray(parsed.warnings) ? parsed.warnings : []
  for (var m = 0; m < rawWarnings.length && m < 128 && value.warnings.length < 32; m++) {
    var warning = sanitizeSceneString(rawWarnings[m], "", 240)
    if (warning !== "" && value.warnings.indexOf(warning) === -1)
      value.warnings.push(warning)
  }

  return { valid: true, value: value }
}

function balanceValue(left, right) {
  var l = Number(left)
  var r = Number(right)
  if (!isFinite(l) || l < 0) l = 0
  if (!isFinite(r) || r < 0) r = 0
  var peak = Math.max(l, r)
  if (peak === 0) return 0
  return r >= l ? 1 - l / peak : -(1 - r / peak)
}

function applyBalance(volumes, leftIndex, rightIndex, balance) {
  var values = []
  var source = volumes && typeof volumes.length === "number" ? volumes : []
  var sourceLength = Math.floor(Number(source.length))
  // Audio channel collections are tiny in practice. Refuse an implausible
  // collection instead of copying an attacker-controlled array-like object or
  // returning a truncated channel map that could be assigned back to PipeWire.
  if (!isFinite(sourceLength) || sourceLength < 0 || sourceLength > 64) return source
  for (var i = 0; i < sourceLength; i++) {
    var channel = Number(source[i])
    values.push(isFinite(channel) && channel >= 0 ? channel : 0)
  }
  if (leftIndex < 0 || rightIndex < 0 || leftIndex >= values.length || rightIndex >= values.length)
    return values

  var value = Number(balance)
  if (!isFinite(value)) value = 0
  value = Math.max(-1, Math.min(1, value))
  var peak = Math.max(values[leftIndex], values[rightIndex])
  values[leftIndex] = peak * (value > 0 ? 1 - value : 1)
  values[rightIndex] = peak * (value < 0 ? 1 + value : 1)
  return values
}

function audioMeterLevel(peaks, volumes, peak, volume, muted) {
  if (muted) return 0

  var peakValues = peaks && typeof peaks.length === "number" ? peaks : []
  var volumeValues = volumes && typeof volumes.length === "number" ? volumes : []
  var level = 0

  // PwNodePeakMonitor deliberately removes each channel's node volume from
  // its peaks. Reapply those volumes so the meter represents the signal that
  // actually leaves the application, including channel balance.
  if (peakValues.length > 0 && peakValues.length <= 64
      && peakValues.length === volumeValues.length) {
    for (var i = 0; i < peakValues.length && i < 64; i++) {
      var channelPeak = Number(peakValues[i])
      var channelVolume = Number(volumeValues[i])
      if (!isFinite(channelPeak) || channelPeak < 0) channelPeak = 0
      if (!isFinite(channelVolume) || channelVolume < 0) channelVolume = 0
      level = Math.max(level, channelPeak * channelVolume)
    }
  } else {
    var maximumPeak = Number(peak)
    var averageVolume = Number(volume)
    if (!isFinite(maximumPeak) || maximumPeak < 0) maximumPeak = 0
    if (!isFinite(averageVolume) || averageVolume < 0) averageVolume = 0
    level = maximumPeak * averageVolume
  }

  return Math.max(0, Math.min(1, level))
}

function outputVolumeName(volume, muted) {
  if (muted) return "Muted"
  var numericVolume = Number(volume)
  if (!isFinite(numericVolume) || numericVolume < 0) numericVolume = 0
  var p = Math.round(numericVolume * 100)
  if (p === 0) return "Silenced"
  if (p > 125) return "Overdrive"
  if (p >= 100) return "Concert hall"
  if (p >= 85) return "Party mode"
  if (p >= 70) return "Cranked up"
  if (p >= 50) return "Steady groove"
  if (p >= 30) return "Easy listening"
  if (p >= 15) return "Murmur"
  return "Whisper"
}

function parseSinkAvailability(raw) {
  var next = {}
  var text = boundedSerializedInput(raw, 1048576)
  if (text === null) return next
  var lines = text.split("\n")
  for (var i = 0; i < lines.length && i < 1024 && Object.keys(next).length < 256; i++) {
    var line = lines[i]
    if (!line) continue
    var parts = line.split("\t")
    var name = sanitizeIdentifier(parts[0], 160)
    if (parts.length >= 2 && name !== "" && (parts[1] === "0" || parts[1] === "1")) {
      var available = parts[1] === "1"
      // Duplicate endpoint names are not safe routing identities. Preserve a
      // repeated agreement, but make contradictory records unavailable rather
      // than trusting whichever upstream line happened to arrive last.
      if (hasOwn(next, name) && next[name] !== available) next[name] = false
      else if (!hasOwn(next, name)) setMapValue(next, name, available)
    }
  }
  return next
}

function audioProfileLabel(profile, bluetooth) {
  if (!profile) return "Unknown"
  if (profile.value === "off") return "Off"
  if (!bluetooth) return String(profile.label || profile.value)

  var description = String(profile.label || profile.value)
  var codecMatch = description.match(/codec\s+([^\)]+)/i)
  var codec = codecMatch ? codecMatch[1].toUpperCase() : ""
  if (codec === "MSBC") codec = "mSBC"
  if (Number(profile.sources || 0) > 0)
    return "Headset" + (codec ? " (" + codec + ", microphone)" : " (microphone)")
  if (Number(profile.sinks || 0) > 0)
    return "High fidelity" + (codec ? " (" + codec + ", no microphone)" : " (no microphone)")
  return description
}

function audioProfileOptions(card) {
  // Repeater delegates expose nested QML sequence values as array-like
  // objects, so accept any indexed profile collection with a length.
  if (!card || !card.profiles || typeof card.profiles.length !== "number") return []
  var options = []
  for (var i = 0; i < card.profiles.length && i < 256 && options.length < 64; i++) {
    var profile = card.profiles[i]
    options.push({
      value: profile.value,
      label: audioProfileLabel(profile, card.bluetooth)
    })
  }
  return options
}

function audioCardsByBluetooth(cards, bluetooth) {
  var values = Array.isArray(cards) ? cards : []
  var filtered = []
  for (var i = 0; i < values.length && i < 256 && filtered.length < 64; i++)
    if (values[i] && values[i].bluetooth === bluetooth) filtered.push(values[i])
  return filtered
}

function hasBluetoothCards(cards) {
  var values = Array.isArray(cards) ? cards : []
  for (var i = 0; i < values.length && i < 256; i++)
    if (values[i] && values[i].bluetooth) return true
  return false
}

function friendlyDeviceLabel(text) {
  var label = sanitizeSceneString(text, "", 160)
  label = label.replace(/^sof-soundwire\s+/i, "")
  label = label.replace(/^built-?in audio\s+/i, "")
  label = label.replace(/\s+Output$/i, "")
  label = label.replace(/\s+Input$/i, "")
  label = label.replace(/\bMicrophones\b/g, "Microphone")
  return label
}

// QObject-backed PipeWire nodes can disappear between two QML binding
// evaluations. Keep graph identity reads in one exception-safe, strictly
// validated accessor so stale proxies never abort a refresh or become helper
// arguments after their native object has gone away.
function nodeName(node) {
  try {
    if (!node || typeof node.name !== "string") return ""
    return sanitizeIdentifier(node.name, 160)
  } catch (e) {
    return ""
  }
}

function nodeProps(node) {
  try {
    return node && node.ready && node.properties ? node.properties : {}
  } catch (e) {
    return {}
  }
}

function nodeSerial(node) {
  try {
    var serial = nodeProps(node)["object.serial"]
    var text = serial === undefined || serial === null ? "" : String(serial)
    return /^\d{1,20}$/.test(text) ? text : ""
  } catch (e) {
    return ""
  }
}

function nodeObjectId(node) {
  try {
    if (!node) return ""
    var direct = node.id === undefined || node.id === null ? "" : String(node.id)
    var propertyValue = nodeProps(node)["object.id"]
    var propertyId = propertyValue === undefined || propertyValue === null
      ? "" : String(propertyValue)
    if (direct !== "" && !/^\d{1,20}$/.test(direct)) return ""
    if (propertyId !== "" && !/^\d{1,20}$/.test(propertyId)) return ""
    if (direct !== "" && propertyId !== "" && direct !== propertyId) return ""
    return direct !== "" ? direct : propertyId
  } catch (e) {
    return ""
  }
}

function uniqueNodeSerial(nodes, node) {
  var serial = nodeSerial(node)
  if (serial === "") return ""
  var values = nodes && typeof nodes.length === "number" ? nodes : []
  if (values.length > 4096) return ""
  var matches = 0
  for (var i = 0; i < values.length && i < 4096; i++) {
    if (nodeSerial(values[i]) === serial) matches++
    if (matches > 1) return ""
  }
  return matches === 1 ? serial : ""
}

function deviceRouteOptions(devices, defaultDevice, followLabel, overridePrefix, labelFor) {
  labelFor = labelFor || nodeLabel
  var values = Array.isArray(devices) ? devices : []
  var options = []
  var defaultSerial = nodeSerial(defaultDevice)
  var serialCounts = {}
  for (var i = 0; i < values.length && i < 512; i++) {
    var countedSerial = nodeSerial(values[i])
    if (countedSerial === "") continue
    setMapValue(serialCounts, countedSerial,
      Number(mapValue(serialCounts, countedSerial, 0)) + 1)
  }
  var defaultOccurrences = Number(mapValue(serialCounts, defaultSerial, 0))
  // A hidden default is absent from this picker but still a valid follow
  // target. An observed duplicate serial is unsafe because the shell helper
  // cannot know which endpoint the user intended.
  if (defaultSerial !== "" && defaultOccurrences <= 1)
    options.push({ value: "default:" + defaultSerial, label: followLabel })

  var seen = []
  for (i = 0; i < values.length && i < 512; i++) {
    var defaultCandidate = values[i]
    if (nodeSerial(defaultCandidate) !== defaultSerial || defaultSerial === ""
        || defaultOccurrences !== 1) continue
    seen.push(defaultSerial)
    options.push({
      value: "override:" + defaultSerial,
      label: overridePrefix + labelFor(defaultCandidate)
    })
    break
  }
  for (i = 0; i < values.length && i < 512 && options.length < 513; i++) {
    var device = values[i]
    var serial = nodeSerial(device)
    if (serial === "" || Number(mapValue(serialCounts, serial, 0)) !== 1
        || seen.indexOf(serial) !== -1) continue
    seen.push(serial)
    options.push({ value: "override:" + serial, label: overridePrefix + labelFor(device) })
  }
  return options
}

function streamOutputOptions(outputs, defaultOutput, labelFor) {
  return deviceRouteOptions(outputs, defaultOutput,
    "Follow default output", "Always use ", labelFor)
}

function recordingInputOptions(inputs, defaultInput, labelFor) {
  return deviceRouteOptions(inputs, defaultInput,
    "Follow default input", "Always use ", labelFor)
}

// "Follow default" and "Always use the current default" are different
// policies, but they are not different destinations while only one endpoint
// exists. Count target serials instead of menu rows so playback/recording rows
// do not advertise a route picker that cannot move the stream anywhere.
function streamRouteDestinationCount(options) {
  var values = options && typeof options.length === "number" ? options : []
  var seen = []
  for (var i = 0; i < values.length && i < 513; i++) {
    var option = values[i]
    var raw = option && typeof option === "object" ? option.value : option
    var parsed = parseStreamOutputOption(raw)
    if (parsed.sink !== "" && seen.indexOf(parsed.sink) === -1)
      seen.push(parsed.sink)
  }
  return seen.length
}

function parseStreamOutputOption(value) {
  var text = String(value || "")
  var separator = text.indexOf(":")
  if (separator < 1) return { mode: "", sink: "" }
  var mode = text.substring(0, separator)
  var sink = text.substring(separator + 1)
  if ((mode !== "default" && mode !== "override") || !/^\d{1,20}$/.test(sink))
    return { mode: "", sink: "" }
  return { mode: mode, sink: sink }
}

function nodeLabel(node) {
  try {
    if (!node) return "Unknown"
    var p = nodeProps(node)
    var nickname = friendlyDeviceLabel(node.nickname || node.nick
      || p["node.nick"] || p["device.profile.description"] || "")
    if (nickname) return nickname
    return friendlyDeviceLabel(node.description || p["node.description"]
      || nodeName(node) || "Unknown")
  } catch (e) {
    return "Unknown"
  }
}

function isHeadphones(node) {
  try {
    if (!node) return false
    var p = nodeProps(node)
    var blob = String([
      node.name, node.description, node.nickname,
      p["device.icon-name"] || "",
      p["device.product.name"] || "",
      p["node.description"] || "",
      p["node.nick"] || ""
    ].join(" ")).toLowerCase()
    return blob.indexOf("headphone") !== -1
      || blob.indexOf("headset") !== -1
      || blob.indexOf("earbud") !== -1
      || blob.indexOf("earphone") !== -1
      || blob.indexOf("airpod") !== -1
  } catch (e) {
    return false
  }
}

function sinkGlyph(node) {
  try {
    if (!node) return "󰓃"
    if (isHeadphones(node)) return "󰋋"
    var p = nodeProps(node)
    var blob = String([
      node.name, node.description, node.nickname,
      p["device.icon-name"] || "",
      p["device.product.name"] || ""
    ].join(" ")).toLowerCase()
    if (blob.indexOf("bluetooth") !== -1) return "󰂯"
    if (blob.indexOf("hdmi") !== -1 || blob.indexOf("display") !== -1) return "󰍹"
    return "󰓃"
  } catch (e) {
    return "󰓃"
  }
}

function sourceGlyph(node) {
  try {
    if (!node) return "󰍬"
    var p = nodeProps(node)
    var blob = String([
      node.name, node.description, node.nickname,
      p["device.icon-name"] || ""
    ].join(" ")).toLowerCase()
    if (blob.indexOf("headset") !== -1) return "󰋋"
    if (blob.indexOf("bluetooth") !== -1) return "󰂯"
    if (blob.indexOf("webcam") !== -1 || blob.indexOf("camera") !== -1) return "󰄀"
    return "󰍬"
  } catch (e) {
    return "󰍬"
  }
}

function friendlyStreamLabel(label) {
  label = sanitizeSceneString(label, "", 160)
  if (!label) return ""

  var known = {
    "spotify": "Spotify"
  }
  var normalized = label.toLowerCase()
  return mapValue(known, normalized, label)
}

function streamLabelKey(label) {
  return normalizeAppKey(label)
}

function streamLabelIsGeneric(label) {
  return streamLabelKey(label) === "audio-src"
}

function rawStreamLabel(node) {
  try {
    if (!node) return ""
    var p = nodeProps(node)
    return p["application.name"]
      || node.description
      || p["media.name"]
      || p["node.name"]
      || node.name
  } catch (e) {
    return ""
  }
}

function mprisPlayerLabel(player) {
  try {
    if (!player) return ""
    return friendlyStreamLabel(player.identity || player.desktopEntry || "")
  } catch (e) {
    return ""
  }
}

function mprisPlayerIsProxy(player) {
  try {
    var dbusName = String(player && player.dbusName || "").toLowerCase()
    var desktopEntry = String(player && player.desktopEntry || "").toLowerCase()
    return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld"
  } catch (e) {
    return false
  }
}

function streamRepresentsMprisPlayer(streamLabel, playerLabel) {
  var streamKey = streamLabelKey(friendlyStreamLabel(streamLabel))
  var playerKey = streamLabelKey(playerLabel)
  if (!streamKey || !playerKey) return false
  return streamKey === playerKey
    || streamKey.indexOf(playerKey) !== -1
    || playerKey.indexOf(streamKey) !== -1
}

function mprisLabelsFor(players, predicate) {
  // Quickshell service `.values` collections are indexed QML sequences, not
  // guaranteed JavaScript Arrays.
  var values = players && typeof players.length === "number" ? players : []
  var playingCandidates = []
  var candidates = []
  var playingProxyCandidates = []
  var proxyCandidates = []

  for (var i = 0; i < values.length && i < 256; i++) {
    try {
      var player = values[i]
      if (!player) continue
      if (!player.isPlaying && !player.canPlay) continue

      var playerLabel = mprisPlayerLabel(player)
      if (!playerLabel || !predicate(playerLabel)) continue

      if (mprisPlayerIsProxy(player)) {
        if (player.isPlaying) playingProxyCandidates.push(playerLabel)
        proxyCandidates.push(playerLabel)
      } else {
        if (player.isPlaying) playingCandidates.push(playerLabel)
        candidates.push(playerLabel)
      }
    } catch (e) { }
  }

  if (playingCandidates.length === 1) return playingCandidates[0]
  if (playingCandidates.length === 0 && playingProxyCandidates.length === 1) return playingProxyCandidates[0]
  if (candidates.length === 1) return candidates[0]
  if (candidates.length === 0 && proxyCandidates.length === 1) return proxyCandidates[0]
  return ""
}

function matchingMprisStreamLabel(label, players) {
  if (streamLabelIsGeneric(label)) return ""
  return mprisLabelsFor(players, function(playerLabel) {
    return streamRepresentsMprisPlayer(label, playerLabel)
  })
}

function unmatchedMprisStreamLabel(label, players, streams) {
  if (!streamLabelIsGeneric(label)) return ""

  return mprisLabelsFor(players, function(playerLabel) {
    var values = streams && typeof streams.length === "number" ? streams : []
    for (var i = 0; i < values.length && i < 512; i++) {
      var stream = values[i]
      var streamLabel = rawStreamLabel(stream)
      if (!streamLabelIsGeneric(streamLabel) && streamRepresentsMprisPlayer(streamLabel, playerLabel))
        return false
    }
    return true
  })
}

function streamLabel(node, players, streams) {
  if (!node) return "Stream"
  var label = rawStreamLabel(node)
  return friendlyStreamLabel(matchingMprisStreamLabel(label, players)
    || unmatchedMprisStreamLabel(label, players, streams)
    || label) || "Stream"
}

function recordingStreamLabel(node) {
  return friendlyStreamLabel(rawStreamLabel(node)) || "Recording application"
}

function uniqueRecordingStreamLabels(streams) {
  var values = Array.isArray(streams) ? streams : []
  var labels = []
  var keys = []
  for (var i = 0; i < values.length && i < 512 && labels.length < 512; i++) {
    var label = recordingStreamLabel(values[i])
    var key = streamLabelKey(label)
    if (keys.indexOf(key) !== -1) continue
    keys.push(key)
    labels.push(label)
  }
  return labels
}

function addedRecordingStreamLabels(previous, current) {
  var before = Array.isArray(previous) ? previous : []
  var now = Array.isArray(current) ? current : []
  var previousKeys = []
  var additions = []
  var additionKeys = []
  var i
  for (i = 0; i < before.length && i < 512; i++) previousKeys.push(streamLabelKey(before[i]))
  for (i = 0; i < now.length && i < 512 && additions.length < 512; i++) {
    var label = sanitizeSceneString(now[i], "", 160)
    var key = streamLabelKey(label)
    if (label !== "" && previousKeys.indexOf(key) === -1
        && additionKeys.indexOf(key) === -1) {
      additionKeys.push(key)
      additions.push(label)
    }
  }
  return additions
}

function normalizeStreamIconName(name) {
  var value = sanitizeSceneString(name, "", 128).replace(/\.desktop$/i, "")
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(value)) return ""
  var aliases = {
    "chromium-browser": "chromium",
    "spotify-client": "spotify",
    "discord": "discord"
  }
  return mapValue(aliases, value.toLowerCase(), value)
}

function streamIconName(node, players, streams) {
  var p = nodeProps(node)
  var direct = p["application.icon_name"] || p["application.icon-name"] || ""
  if (direct) return normalizeStreamIconName(direct)

  var values = players && typeof players.length === "number" ? players : []
  for (var i = 0; i < values.length && i < 256; i++) {
    try {
      var player = values[i]
      if (!player || !streamRepresentsPlayer(node, player, values, streams)) continue
      if (player.desktopEntry)
        return normalizeStreamIconName(String(player.desktopEntry).replace(/\.desktop$/i, ""))
    } catch (e) { }
  }

  var applicationId = String(p["application.id"] || "")
  if (applicationId) return normalizeStreamIconName(applicationId.replace(/\.desktop$/i, ""))

  var binary = String(p["application.process.binary"] || "")
  if (binary) return normalizeStreamIconName(binary.split("/").pop())

  var labelIcons = {
    "spotify": "spotify",
    "chromium": "chromium"
  }
  var label = streamLabelKey(rawStreamLabel(node))
  if (hasOwn(labelIcons, label)) return labelIcons[label]
  return ""
}

// Return a declarative scene plan so ordering is independently testable and
// the controller can resolve live PipeWire objects only when each step runs.
// Profiles can recreate endpoints, so no port, device, or default target may
// be resolved before all profile helpers have completed.
function audioScenePlan(scene) {
  var normalized = sanitizeSceneEntry(scene)
  if (!normalized) return []

  var steps = []
  var i
  for (i = 0; i < normalized.profiles.length; i++) {
    steps.push({
      kind: "profile",
      card: normalized.profiles[i].card,
      profile: normalized.profiles[i].profile,
      label: "Profile " + normalized.profiles[i].card
    })
  }
  if (normalized.profiles.length > 0) steps.push({ kind: "settle", label: "Audio devices" })

  for (i = 0; i < normalized.ports.length; i++) {
    steps.push({
      kind: "port",
      direction: normalized.ports[i].direction,
      endpoint: normalized.ports[i].endpoint,
      value: normalized.ports[i].value,
      label: "Port " + normalized.ports[i].endpoint
    })
  }
  for (i = 0; i < normalized.devices.length; i++) {
    steps.push({
      kind: "device",
      direction: normalized.devices[i].direction,
      name: normalized.devices[i].name,
      volume: normalized.devices[i].volume,
      muted: normalized.devices[i].muted,
      balance: normalized.devices[i].balance,
      label: normalized.devices[i].name
    })
  }
  if (normalized.defaults.output !== "") {
    steps.push({
      kind: "default",
      direction: "output",
      name: normalized.defaults.output,
      label: "Default output"
    })
  }
  if (normalized.defaults.input !== "") {
    steps.push({
      kind: "default",
      direction: "input",
      name: normalized.defaults.input,
      label: "Default input"
    })
  }
  return steps
}

// Scoped hosts may hide the media service. Prefer playing players, then paused
// players with a matching stream, then controllable players. Within each tier,
// prefer real players over proxies and keep list order. The host's pinned source
// and playback-start history are unavailable, so this is a fallback heuristic.
function pickActiveMprisPlayer(players, streams) {
  var values = players && typeof players.length === "number" ? players : []
  var nodes = streams && typeof streams.length === "number" ? streams : []
  var matched = null, matchedProxy = null
  var playing = null, playingProxy = null
  var paused = null, pausedProxy = null
  var controllable = null, controllableProxy = null
  for (var i = 0; i < values.length && i < 256; i++) {
    var player = values[i]
    if (!player) continue
    var proxy = mprisPlayerIsProxy(player)
    var label = mprisPlayerLabel(player)
    var hasStream = false
    if (label) {
      for (var s = 0; s < nodes.length && s < 512; s++) {
        var streamLabel = rawStreamLabel(nodes[s])
        if (streamLabel && !streamLabelIsGeneric(streamLabel)
            && streamRepresentsMprisPlayer(streamLabel, label)) {
          hasStream = true
          break
        }
      }
    }
    var isPlaying = false
    var canControl = false
    try { isPlaying = player.isPlaying === true } catch (e) { }
    try { canControl = player.canControl === true } catch (e) { }
    if (isPlaying) {
      if (hasStream) {
        if (!proxy && !matched) matched = player
        else if (proxy && !matchedProxy) matchedProxy = player
      } else {
        if (!proxy && !playing) playing = player
        else if (proxy && !playingProxy) playingProxy = player
      }
    } else if (hasStream) {
      if (!proxy && !paused) paused = player
      else if (proxy && !pausedProxy) pausedProxy = player
    } else if (canControl) {
      if (!proxy && !controllable) controllable = player
      else if (proxy && !controllableProxy) controllableProxy = player
    }
  }
  return matched || matchedProxy || playing || playingProxy
    || paused || pausedProxy || controllable || controllableProxy || null
}

function streamRepresentsPlayer(node, player, players, streams) {
  if (!node || !player) return false
  var playerLabel = mprisPlayerLabel(player)
  if (!playerLabel) return false

  var label = rawStreamLabel(node)
  if (!streamLabelIsGeneric(label)) return streamRepresentsMprisPlayer(label, playerLabel)
  return streamRepresentsMprisPlayer(streamLabel(node, players, streams), playerLabel)
}

if (typeof module !== "undefined") {
  module.exports = {
    isPlaybackStream: isPlaybackStream,
    isRecordingStream: isRecordingStream,
    isAudioSource: isAudioSource,
    isInternalAudioNode: isInternalAudioNode,
    isMonitorSource: isMonitorSource,
    classifyAudioNodes: classifyAudioNodes,
    listSnapshot: listSnapshot,
    hasOwn: hasOwn,
    mapValue: mapValue,
    isAudioPreferencesDocument: isAudioPreferencesDocument,
    isAudioControlSettingsDocument: isAudioControlSettingsDocument,
    isAudioScenesDocument: isAudioScenesDocument,
    isAudioRulesDocument: isAudioRulesDocument,
    normalizedBluetoothAddress: normalizedBluetoothAddress,
    parseAudioPreferences: parseAudioPreferences,
    preferredAudioProfile: preferredAudioProfile,
    preferredAudioNodeName: preferredAudioNodeName,
    parseAudioControlSettings: parseAudioControlSettings,
    parseAudioOpenRequest: parseAudioOpenRequest,
    parseAudioScenes: parseAudioScenes,
    sanitizeSceneEntry: sanitizeSceneEntry,
    sanitizeIdentifier: sanitizeIdentifier,
    normalizeAppKey: normalizeAppKey,
    sceneSummary: sceneSummary,
    parseAudioRules: parseAudioRules,
    outputGroupForSink: outputGroupForSink,
    outputGroupFallbackMember: outputGroupFallbackMember,
    isOutputGroupSink: isOutputGroupSink,
    isManagedOutputGroupSink: isManagedOutputGroupSink,
    isOutputGroupMemberSink: isOutputGroupMemberSink,
    findAppRule: findAppRule,
    availableRuleApplicationLabels: availableRuleApplicationLabels,
    deviceSortComparator: deviceSortComparator,
    emptyAudioDiagnostics: emptyAudioDiagnostics,
    parseAudioDiagnostics: parseAudioDiagnostics,
    normalizeAudioDiagnostics: normalizeAudioDiagnostics,
    balanceValue: balanceValue,
    applyBalance: applyBalance,
    audioMeterLevel: audioMeterLevel,
    outputVolumeName: outputVolumeName,
    parseSinkAvailability: parseSinkAvailability,
    audioProfileLabel: audioProfileLabel,
    audioProfileOptions: audioProfileOptions,
    audioCardsByBluetooth: audioCardsByBluetooth,
    hasBluetoothCards: hasBluetoothCards,
    friendlyDeviceLabel: friendlyDeviceLabel,
    nodeName: nodeName,
    nodeProps: nodeProps,
    nodeSerial: nodeSerial,
    nodeObjectId: nodeObjectId,
    uniqueNodeSerial: uniqueNodeSerial,
    streamOutputOptions: streamOutputOptions,
    recordingInputOptions: recordingInputOptions,
    streamRouteDestinationCount: streamRouteDestinationCount,
    parseStreamOutputOption: parseStreamOutputOption,
    nodeLabel: nodeLabel,
    isHeadphones: isHeadphones,
    sinkGlyph: sinkGlyph,
    sourceGlyph: sourceGlyph,
    friendlyStreamLabel: friendlyStreamLabel,
    streamLabelKey: streamLabelKey,
    streamLabelIsGeneric: streamLabelIsGeneric,
    rawStreamLabel: rawStreamLabel,
    mprisPlayerLabel: mprisPlayerLabel,
    mprisPlayerIsProxy: mprisPlayerIsProxy,
    streamRepresentsMprisPlayer: streamRepresentsMprisPlayer,
    mprisLabelsFor: mprisLabelsFor,
    matchingMprisStreamLabel: matchingMprisStreamLabel,
    unmatchedMprisStreamLabel: unmatchedMprisStreamLabel,
    streamLabel: streamLabel,
    recordingStreamLabel: recordingStreamLabel,
    uniqueRecordingStreamLabels: uniqueRecordingStreamLabels,
    addedRecordingStreamLabels: addedRecordingStreamLabels,
    streamIconName: streamIconName,
    pickActiveMprisPlayer: pickActiveMprisPlayer,
    streamRepresentsPlayer: streamRepresentsPlayer,
    audioScenePlan: audioScenePlan
  }
}
