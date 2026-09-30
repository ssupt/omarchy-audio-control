// Transport state only. Audio policy and graph ownership live in Rust.
var VERSION = 1
var MAX_FRAME = 262144
var MAX_SNAPSHOT = 8388608
var MAX_PENDING = 32

function own(object, key) { return Object.prototype.hasOwnProperty.call(object, key) }
function object(value) { return value !== null && typeof value === "object" && !Array.isArray(value) }
function integer(value) { return typeof value === "number" && isFinite(value) && Math.floor(value) === value }
function failure(code, message, unknown) {
  return { code: code, message: message, outcome: unknown ? "unknown" : "rejected" }
}
function utf8Length(value) {
  var count = 0
  for (var i = 0; i < value.length; i++) {
    var c = value.charCodeAt(i)
    if (c < 128) count++
    else if (c < 2048) count += 2
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < value.length
      && value.charCodeAt(i + 1) >= 0xdc00 && value.charCodeAt(i + 1) <= 0xdfff) {
      count += 4
      i++
    } else count += 3
  }
  return count
}

function Client(options) {
  this.options = options
  this.pending = Object.create(null)
  this.sequence = 0
  this.buffer = ""
  this.frameDeadline = 0
  this.snapshot = null
  this.initialSnapshotDeadline = 0
  this.deadline = 0
  this.connected = false
  this.negotiated = false
  this.ready = false
  this.info = null
}
Client.prototype.now = function() { return this.options.now ? this.options.now() : Date.now() }
Client.prototype.scheduleDeadline = function(force) {
  var next = 0
  function include(value) { if (value && (!next || value < next)) next = value }
  include(this.frameDeadline)
  include(this.initialSnapshotDeadline)
  if (this.snapshot) include(this.snapshot.deadline)
  for (var id in this.pending) include(this.pending[id].deadline)
  if (next !== this.deadline || force) {
    this.deadline = next
    if (this.options.deadline) this.options.deadline(next)
  }
}
Client.prototype.callback = function(callback, result, error) {
  if (!callback) return
  try { callback(result, error) } catch (_error) {
    if (this.options.callbackError) this.options.callbackError()
  }
}
Client.prototype.reset = function(error) {
  var pending = this.pending
  this.pending = Object.create(null)
  this.buffer = ""
  this.frameDeadline = 0
  this.snapshot = null
  this.initialSnapshotDeadline = 0
  this.connected = false
  this.negotiated = false
  this.ready = false
  this.info = null
  if (this.options.ready) this.options.ready(false, null)
  for (var id in pending) {
    var entry = pending[id]
    this.callback(entry.callback, null, failure(error.code, error.message, entry.mutating))
  }
  this.scheduleDeadline()
}
Client.prototype.fault = function(message) {
  this.reset(failure("protocol_error", message, false))
  if (this.options.fault) this.options.fault(message)
}
Client.prototype.open = function() {
  this.reset(failure("disconnected", "Audio service connection replaced", false))
  this.connected = true
  var client = this
  this.request("hello", {}, function(result, error) {
    if (error) { client.fault(error.message); return }
    if (!object(result) || result.name !== "omarchy-audio-service"
        || result.protocolVersion !== VERSION || result.transport !== "jsonl-ascii"
        || result.maxFrameBytes !== MAX_FRAME || result.maxSnapshotBytes !== MAX_SNAPSHOT
        || typeof result.epoch !== "string" || result.epoch.length === 0
        || !Array.isArray(result.capabilities)
        || result.capabilities.indexOf("state.subscribe") === -1) {
      client.fault("Audio service protocol mismatch")
      return
    }
    if (client.options.expectedBuildId && result.buildId !== client.options.expectedBuildId) {
      client.fault("Audio UI and backend releases do not match; finish updating the plugin")
      return
    }
    client.initialSnapshotDeadline = client.now() + 10000
    client.negotiated = true
    client.info = result
    client.request("state.subscribe", {}, function(_result, subscribeError) {
      if (subscribeError) client.fault(subscribeError.message)
    }, { mutating: false, timeout: 5000 })
  }, { mutating: false, timeout: 5000 })
}
Client.prototype.request = function(method, params, callback, settings) {
  settings = settings || {}
  if (!this.connected || (!this.ready && ["hello", "health", "state.subscribe"].indexOf(method) === -1)) {
    this.callback(callback, null, failure("not_ready", "Audio service is unavailable", false))
    return ""
  }
  if (Object.keys(this.pending).length >= MAX_PENDING) {
    this.callback(callback, null, failure("busy", "Audio service request queue is full", false))
    return ""
  }
  if (typeof method !== "string" || !/^[a-z._]{1,128}$/.test(method) || !object(params)) {
    this.callback(callback, null, failure("invalid_params", "Invalid audio command", false))
    return ""
  }
  var id = "qml-" + (++this.sequence)
  var frame = ""
  try { frame = JSON.stringify({ version: VERSION, id: id, method: method, params: params }) + "\n" }
  catch (_error) {
    this.callback(callback, null, failure("invalid_params", "Could not encode audio command", false))
    return ""
  }
  if (utf8Length(frame) > MAX_FRAME) {
    this.callback(callback, null, failure("too_large", "Audio command is too large", false))
    return ""
  }
  var mutating = settings.mutating !== false && ["hello", "health", "state.subscribe"].indexOf(method) === -1
  this.pending[id] = { callback: callback, mutating: mutating, method: method,
    deadline: this.now() + Math.max(100, Math.min(120000, settings.timeout || 120000)) }
  this.scheduleDeadline()
  try { this.options.write(frame) } catch (_writeError) {
    this.fault("Could not send audio command")
    return ""
  }
  return id
}
Client.prototype.feed = function(chunk) {
  try {
    if (!this.connected) return
    chunk = String(chunk)
    // The service promises ASCII JSON. Reject before any concatenation or parsing.
    if (/[^\x00-\x7f]/.test(chunk)) { this.fault("Invalid audio service encoding"); return }
    var start = 0
    while (start < chunk.length) {
      var end = chunk.indexOf("\n", start)
      var stop = end === -1 ? chunk.length : end
      if (this.buffer.length + stop - start + 1 > MAX_FRAME) {
        this.fault("Audio service frame is too large")
        return
      }
      if (this.buffer === "") this.frameDeadline = this.now() + 5000
      this.buffer += chunk.substring(start, stop)
      if (end === -1) return
      var line = this.buffer
      this.buffer = ""
      this.frameDeadline = 0
      this.line(line)
      if (!this.connected) return
      start = end + 1
    }
  } finally { this.scheduleDeadline() }
}
Client.prototype.line = function(line) {
  var message
  try { message = JSON.parse(line) } catch (_error) { this.fault("Malformed audio service response"); return }
  if (!object(message) || message.version !== VERSION) { this.fault("Audio service protocol mismatch"); return }
  if (own(message, "event")) {
    if (!this.negotiated || own(message, "id") || own(message, "result") || own(message, "error")
        || typeof message.event !== "string" || !object(message.data)) {
      this.fault("Invalid audio service event")
      return
    }
    this.event(message.event, message.data)
    return
  }
  if (typeof message.id !== "string" || own(message, "result") === own(message, "error")
      || (own(message, "error") && (!object(message.error)
        || typeof message.error.code !== "string" || typeof message.error.message !== "string"
        || typeof message.error.outcome !== "string"))) {
    this.fault("Invalid audio service reply")
    return
  }
  if (!own(this.pending, message.id)) return // A late/duplicate reply never resolves another request.
  var entry = this.pending[message.id]
  delete this.pending[message.id]
  this.callback(entry.callback, own(message, "result") ? message.result : null, message.error || null)
}
Client.prototype.event = function(name, data) {
  if (name === "snapshot.begin") {
    if (this.snapshot || !integer(data.bytes) || data.bytes < 2 || data.bytes > MAX_SNAPSHOT
        || !integer(data.parts) || data.parts < 1 || data.parts > 256) {
      this.fault("Invalid audio state snapshot")
      return
    }
    this.snapshot = { bytes: data.bytes, parts: data.parts, next: 0, chunks: [], size: 0,
      deadline: this.now() + 10000 }
  } else if (name === "snapshot.part") {
    var snapshot = this.snapshot
    if (!snapshot || data.index !== snapshot.next || snapshot.next >= snapshot.parts
        || typeof data.text !== "string" || /[^\x00-\x7f]/.test(data.text)
        || snapshot.size + data.text.length > snapshot.bytes) {
      this.fault("Incomplete audio state snapshot")
      return
    }
    snapshot.chunks.push(data.text)
    snapshot.size += data.text.length
    snapshot.next++
  } else if (name === "snapshot.end") {
    var complete = this.snapshot
    this.snapshot = null
    if (!complete || complete.next !== complete.parts || complete.size !== complete.bytes) {
      this.fault("Incomplete audio state snapshot")
      return
    }
    var state
    try { state = JSON.parse(complete.chunks.join("")) } catch (_error) {
      this.fault("Malformed audio state snapshot")
      return
    }
    if (!object(state) || state.epoch !== this.info.epoch || typeof state.revision !== "string") {
      this.fault("Stale audio service snapshot")
      return
    }
    if (this.options.state) this.options.state(state)
    this.initialSnapshotDeadline = 0
    var wasReady = this.ready
    this.ready = true
    if (!wasReady && this.options.ready) this.options.ready(true, this.info)
  } else { this.fault("Unsupported audio service event") }
}
Client.prototype.tick = function() {
  var now = this.now()
  if ((this.initialSnapshotDeadline && now >= this.initialSnapshotDeadline)
      || (this.frameDeadline && now >= this.frameDeadline)
      || (this.snapshot && now >= this.snapshot.deadline)) {
    this.fault("Audio service snapshot timed out")
    return
  }
  var expired = []
  for (var id in this.pending) {
    if (now >= this.pending[id].deadline) { expired.push(this.pending[id]); delete this.pending[id] }
  }
  for (var i = 0; i < expired.length; i++) {
    var entry = expired[i]
    this.callback(entry.callback, null, failure("timeout", "Audio command timed out; refreshing state", entry.mutating))
  }
  if (expired.length) this.fault("Audio service stopped responding")
  // QML can fire slightly early; rearm even when the nearest deadline is unchanged.
  this.scheduleDeadline(true)
}
if (typeof module !== "undefined") module.exports = { Client: Client, utf8Length: utf8Length, MAX_FRAME: MAX_FRAME }
