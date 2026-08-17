function isPlaybackStream(node) {
  if (!node || !node.isStream) return false
  if (node.isSink === true) return true

  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Stream/Output/Audio") !== -1
    || mediaClass.indexOf("AudioOutStream") !== -1
    || mediaClass.indexOf("Output") !== -1
}

function isRecordingStream(node) {
  if (!node || !node.isStream) return false
  if (node.isSink === false) return true

  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Stream/Input/Audio") !== -1
    || mediaClass.indexOf("AudioInStream") !== -1
    || mediaClass.indexOf("Input") !== -1
}

function isAudioSource(node) {
  if (!node) return false
  if (node.audio) return true

  var mediaClass = String(node.type || "")
  return mediaClass.indexOf("Audio/Source") !== -1
    || mediaClass.indexOf("AudioSource") !== -1
    || mediaClass.indexOf("Source") !== -1
}

function listSnapshot(list) {
  return list && list.slice ? list.slice() : []
}

function normalizedBluetoothAddress(value) {
  return String(value || "").trim().toLowerCase().replace(/[^0-9a-f]/g, "")
}

function parseAudioPreferences(raw) {
  var parsed
  try {
    parsed = JSON.parse(String(raw || "{}"))
  } catch (e) {
    parsed = {}
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}

  var defaults = parsed.defaults
  if (!defaults || typeof defaults !== "object" || Array.isArray(defaults)) defaults = {}
  var rawProfiles = parsed.bluetoothProfiles
  if (!rawProfiles || typeof rawProfiles !== "object" || Array.isArray(rawProfiles)) rawProfiles = {}

  var profiles = {}
  for (var address in rawProfiles) {
    var key = normalizedBluetoothAddress(address)
    var profile = rawProfiles[address]
    if (key !== "" && typeof profile === "string" && profile !== "") profiles[key] = profile
  }

  return {
    version: 1,
    defaults: {
      output: typeof defaults.output === "string" ? defaults.output : "",
      input: typeof defaults.input === "string" ? defaults.input : ""
    },
    bluetoothProfiles: profiles
  }
}

function preferredAudioProfile(preferences, address, options, activeProfile) {
  var profiles = preferences && preferences.bluetoothProfiles
  var saved = profiles ? String(profiles[normalizedBluetoothAddress(address)] || "") : ""
  var values = options && typeof options.length === "number" ? options : []
  for (var i = 0; i < values.length; i++) {
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
    for (var i = 0; i < values.length; i++)
      if (values[i] && String(values[i].name || "") === saved) return saved
  }
  return liveNode ? String(liveNode.name || "") : ""
}

function parseAudioControlSettings(raw) {
  var parsed
  try {
    parsed = JSON.parse(String(raw || "{}"))
  } catch (e) {
    parsed = {}
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) parsed = {}
  return {
    version: 1,
    outputOverdrive: parsed.outputOverdrive === true
  }
}

function balanceValue(left, right) {
  var l = Math.max(0, Number(left || 0))
  var r = Math.max(0, Number(right || 0))
  var peak = Math.max(l, r)
  if (peak === 0) return 0
  return r >= l ? 1 - l / peak : -(1 - r / peak)
}

function applyBalance(volumes, leftIndex, rightIndex, balance) {
  var values = []
  var source = volumes && typeof volumes.length === "number" ? volumes : []
  for (var i = 0; i < source.length; i++) values.push(Number(source[i] || 0))
  if (leftIndex < 0 || rightIndex < 0 || leftIndex >= values.length || rightIndex >= values.length)
    return values

  var value = Math.max(-1, Math.min(1, Number(balance || 0)))
  var peak = Math.max(values[leftIndex], values[rightIndex])
  values[leftIndex] = peak * (value > 0 ? 1 - value : 1)
  values[rightIndex] = peak * (value < 0 ? 1 + value : 1)
  return values
}

function outputVolumeName(volume, muted) {
  if (muted) return "Muted"
  var p = Math.round(volume * 100)
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
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    var parts = line.split("\t")
    if (parts.length >= 2) next[parts[0]] = parts[1] !== "0"
  }
  return next
}

function parseAudioProfiles(raw) {
  var cards
  try {
    cards = JSON.parse(String(raw || "[]"))
  } catch (e) {
    return []
  }
  if (!Array.isArray(cards)) return []

  var normalized = []
  for (var i = 0; i < cards.length; i++) {
    var card = cards[i]
    if (!card || !card.name || !Array.isArray(card.profiles) || card.profiles.length === 0) continue

    var profiles = []
    for (var j = 0; j < card.profiles.length; j++) {
      var profile = card.profiles[j]
      if (!profile || !profile.value) continue
      profiles.push({
        value: String(profile.value),
        label: String(profile.label || profile.value),
        sinks: Number(profile.sinks || 0),
        sources: Number(profile.sources || 0)
      })
    }
    if (profiles.length === 0) continue

    normalized.push({
      name: String(card.name),
      label: String(card.label || card.name),
      bluetooth: card.bluetooth === true,
      address: String(card.address || ""),
      activeProfile: String(card.activeProfile || "off"),
      profiles: profiles
    })
  }

  normalized.sort(function(a, b) {
    var aActive = a.activeProfile !== "off" ? 0 : 1
    var bActive = b.activeProfile !== "off" ? 0 : 1
    if (aActive !== bActive) return aActive - bActive
    return a.label.localeCompare(b.label)
  })
  return normalized
}

function parseAudioPorts(raw) {
  var values
  try {
    values = JSON.parse(String(raw || "[]"))
  } catch (e) {
    return []
  }
  if (!Array.isArray(values)) return []

  var ports = []
  for (var i = 0; i < values.length; i++) {
    var item = values[i]
    if (!item || (item.direction !== "output" && item.direction !== "input")
        || !item.endpoint || !Array.isArray(item.ports) || item.ports.length < 2) continue
    var options = []
    for (var j = 0; j < item.ports.length; j++) {
      var port = item.ports[j]
      if (!port || !port.value) continue
      options.push({ value: String(port.value), label: String(port.label || port.value) })
    }
    if (options.length < 2) continue
    ports.push({
      direction: item.direction,
      endpoint: String(item.endpoint),
      label: String(item.label || item.endpoint),
      activePort: String(item.activePort || ""),
      ports: options
    })
  }
  return ports
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
  for (var i = 0; i < card.profiles.length; i++) {
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
  for (var i = 0; i < values.length; i++)
    if (values[i] && values[i].bluetooth === bluetooth) filtered.push(values[i])
  return filtered
}

function hasBluetoothCards(cards) {
  var values = Array.isArray(cards) ? cards : []
  for (var i = 0; i < values.length; i++)
    if (values[i] && values[i].bluetooth) return true
  return false
}

function friendlyDeviceLabel(text) {
  var label = String(text || "").trim()
  label = label.replace(/^sof-soundwire\s+/i, "")
  label = label.replace(/^built-?in audio\s+/i, "")
  label = label.replace(/\s+Output$/i, "")
  label = label.replace(/\s+Input$/i, "")
  label = label.replace(/\bMicrophones\b/g, "Microphone")
  return label
}

function nodeProps(node) {
  return node && node.ready && node.properties ? node.properties : {}
}

function nodeSerial(node) {
  var serial = nodeProps(node)["object.serial"]
  return serial === undefined || serial === null ? "" : String(serial)
}

function streamOutputOptions(outputs, defaultOutput) {
  var values = Array.isArray(outputs) ? outputs : []
  var options = []
  var defaultSerial = nodeSerial(defaultOutput)

  for (var i = 0; i < values.length; i++) {
    var candidate = values[i]
    var serial = nodeSerial(candidate)
    if (serial !== "" && serial === defaultSerial) {
      options.push({ value: "default:" + serial, label: "Follow default output" })
      options.push({ value: "override:" + serial, label: "Always use " + nodeLabel(candidate) })
      break
    }
  }

  for (var j = 0; j < values.length; j++) {
    var output = values[j]
    var outputSerial = nodeSerial(output)
    if (outputSerial === "" || outputSerial === defaultSerial) continue
    options.push({ value: "override:" + outputSerial, label: "Always use " + nodeLabel(output) })
  }
  return options
}

function recordingInputOptions(inputs, defaultInput) {
  var values = Array.isArray(inputs) ? inputs : []
  var options = []
  var defaultSerial = nodeSerial(defaultInput)

  for (var i = 0; i < values.length; i++) {
    var candidate = values[i]
    var serial = nodeSerial(candidate)
    if (serial !== "" && serial === defaultSerial) {
      options.push({ value: "default:" + serial, label: "Follow default input" })
      options.push({ value: "override:" + serial, label: "Always use " + nodeLabel(candidate) })
      break
    }
  }

  for (var j = 0; j < values.length; j++) {
    var input = values[j]
    var inputSerial = nodeSerial(input)
    if (inputSerial === "" || inputSerial === defaultSerial) continue
    options.push({ value: "override:" + inputSerial, label: "Always use " + nodeLabel(input) })
  }
  return options
}

function parseStreamOutputOption(value) {
  var text = String(value || "")
  var separator = text.indexOf(":")
  if (separator < 1) return { mode: "", sink: "" }
  var mode = text.substring(0, separator)
  var sink = text.substring(separator + 1)
  if ((mode !== "default" && mode !== "override") || !/^\d+$/.test(sink))
    return { mode: "", sink: "" }
  return { mode: mode, sink: sink }
}

function nodeLabel(node) {
  if (!node) return "Unknown"
  var p = nodeProps(node)
  var nickname = friendlyDeviceLabel(node.nickname || node.nick || p["node.nick"] || p["device.profile.description"] || "")
  if (nickname) return nickname
  return friendlyDeviceLabel(node.description || p["node.description"] || node.name || "Unknown")
}

function isHeadphones(node) {
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
}

function sinkGlyph(node) {
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
}

function sourceGlyph(node) {
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
}

function friendlyStreamLabel(label) {
  label = String(label || "").trim()
  if (!label) return ""

  var known = {
    "spotify": "Spotify"
  }
  var normalized = label.toLowerCase()
  return known[normalized] || label
}

function streamLabelKey(label) {
  return String(label || "").trim().toLowerCase()
}

function streamLabelIsGeneric(label) {
  return streamLabelKey(label) === "audio-src"
}

function rawStreamLabel(node) {
  if (!node) return ""
  var p = nodeProps(node)
  return p["application.name"]
    || node.description
    || p["media.name"]
    || p["node.name"]
    || node.name
}

function mprisPlayerLabel(player) {
  if (!player) return ""
  return friendlyStreamLabel(player.identity || player.desktopEntry || "")
}

function mprisPlayerIsProxy(player) {
  var dbusName = String(player && player.dbusName || "").toLowerCase()
  var desktopEntry = String(player && player.desktopEntry || "").toLowerCase()
  return dbusName.indexOf("playerctld") !== -1 || desktopEntry === "playerctld"
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
  var values = Array.isArray(players) ? players : []
  var playingCandidates = []
  var candidates = []
  var playingProxyCandidates = []
  var proxyCandidates = []

  for (var i = 0; i < values.length; i++) {
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
    var values = Array.isArray(streams) ? streams : []
    for (var i = 0; i < values.length; i++) {
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

function normalizeStreamIconName(name) {
  var value = String(name || "").trim()
  var aliases = {
    "chromium-browser": "chromium",
    "spotify-client": "spotify",
    "discord": "discord"
  }
  return aliases[value.toLowerCase()] || value
}

function streamIconName(node, players, streams) {
  var p = nodeProps(node)
  var direct = p["application.icon_name"] || p["application.icon-name"] || ""
  if (direct) return normalizeStreamIconName(direct)

  var values = Array.isArray(players) ? players : []
  for (var i = 0; i < values.length; i++) {
    var player = values[i]
    if (!player || !streamRepresentsPlayer(node, player, values, streams)) continue
    if (player.desktopEntry)
      return normalizeStreamIconName(String(player.desktopEntry).replace(/\.desktop$/i, ""))
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
  if (labelIcons[label]) return labelIcons[label]
  return ""
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
    listSnapshot: listSnapshot,
    normalizedBluetoothAddress: normalizedBluetoothAddress,
    parseAudioPreferences: parseAudioPreferences,
    preferredAudioProfile: preferredAudioProfile,
    preferredAudioNodeName: preferredAudioNodeName,
    parseAudioControlSettings: parseAudioControlSettings,
    balanceValue: balanceValue,
    applyBalance: applyBalance,
    outputVolumeName: outputVolumeName,
    parseSinkAvailability: parseSinkAvailability,
    parseAudioProfiles: parseAudioProfiles,
    parseAudioPorts: parseAudioPorts,
    audioProfileLabel: audioProfileLabel,
    audioProfileOptions: audioProfileOptions,
    audioCardsByBluetooth: audioCardsByBluetooth,
    hasBluetoothCards: hasBluetoothCards,
    friendlyDeviceLabel: friendlyDeviceLabel,
    nodeProps: nodeProps,
    nodeSerial: nodeSerial,
    streamOutputOptions: streamOutputOptions,
    recordingInputOptions: recordingInputOptions,
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
    streamIconName: streamIconName,
    streamRepresentsPlayer: streamRepresentsPlayer
  }
}
