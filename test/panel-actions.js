const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const Model = require('../qml/core/Model.js')
const Protocol = require('../qml/core/AudioProtocol.js')

const source = fs.readFileSync(require.resolve('../qml/panels/Panel.qml'), 'utf8')
const serviceSource = fs.readFileSync(require.resolve('../qml/core/Service.qml'), 'utf8')
const micControllerSource = fs.readFileSync(
  require.resolve('../qml/microphone/AudioMicrophoneTestController.qml'), 'utf8')
function node(id, mediaClass = 'Audio/Sink') {
  return { id, ready: true, audio: { volume: .5, muted: false },
    properties: { 'object.serial': String(id), 'node.name': 'node_' + id, 'media.class': mediaClass } }
}
function panel() {
  const output = node(1), input = node(2, 'Audio/Source'), stream = node(3, 'Stream/Output/Audio')
  const requests = [], levels = []
  const context = {
    Model, nodes: [output, input, stream], sink: output, volumeSink: output, source: input,
    audioStreams: [stream], recordingStreams: [], candidateSinks: [output], candidateSources: [input],
    displayAudioSinks: [output], displayAudioSources: [input],
    displayAudioStreams: [stream], displayRecordingStreams: [],
    preferredOutputName: '', preferredInputName: '',
    compactDevices: false,
    outputDevicesExpanded: false, inputDevicesExpanded: false, cursorActive: false,
    outputVolumeMaximum: 1, focusSection: 'output', selectedIndex: -1,
    nodeGeneration: 'g',
    hasOutput: true, hasInput: true, outputMuted: false, inputMuted: false,
    outputVolume: .5, inputClipping: false,
    activeRecordingLabels: [], recordingApplicationCount: 0,
    defaultOutputError: '', defaultInputError: '', streamRouteSetError: '', interactionError: '',
    defaultSetPending: false, masterMutePending: false, pendingStreamRoute: null, streamOutputMenuOpen: false,
    sceneController: { busy: false }, rulesStore: { busy: false }, outputGroups: { busy: false },
    interactionErrorTimer: { restart() {}, stop() {} },
    audioService: {
      ready: true, busy: false, transactionBusy: false,
      state: { generation: 'g', master: { hasOutput: true, hasInput: true, anyAudible: true, recordingActive: false, recordingMuted: false } },
      identityForNode(n) { return n && context.nodes.includes(n) ? { generation: 'g', id: n.id, serial: String(n.id) } : null },
      request(method, params, callback) { requests.push({ method, params, callback }) },
      changeNode(n, patch) { levels.push({ node: n, patch }); return context.nodes.includes(n) }
    }
  }
  context.root = context
  vm.createContext(context)
  // Execute the real panel handlers; only their external services are replaced.
  for (const match of source.matchAll(/^  function \w+\([^\n]*\) \{[\s\S]*?^  \}/gm))
    vm.runInContext(match[0], context)
  for (const [kind, name] of [
    ['bool', 'routeMutationBusy'],
    ['bool', 'directDeviceMutationBusy'],
    ['bool', 'sceneMutationBusy'],
    ['var', 'masterState'],
    ['bool', 'activeRecordingMuted'],
    ['bool', 'anyAudible'],
    ['bool', 'outputDevicesCollapsed'],
    ['bool', 'inputDevicesCollapsed'],
    ['var', 'activeOutputRowNode'],
    ['var', 'activeInputRowNode']
  ]) {
    const expression = source.match(new RegExp('readonly property ' + kind + ' ' + name + ': ([^\\n]*(?:\\n    [^\\n]*)*)'))[1]
    Object.defineProperty(context, name, { get: () => vm.runInContext(expression, context) })
  }
  const tooltipBlock = source.match(/readonly property string recordingTooltip: \{([\s\S]*?)^  \}/m)[1]
  Object.defineProperty(context, 'recordingTooltip', {
    get: () => vm.runInContext('(function(){' + tooltipBlock + '})()', context)
  })
  return { context, output, input, stream, requests, levels }
}

{
  const { context: p, output, requests } = panel()
  assert.equal(p.setDefaultDevice(output, node(99), 'output'), true,
    'A departed previous default must not block selection')
  assert.equal(requests[0].params.previous, null)
  assert.equal(p.setDefaultDevice(output, null, 'output'), false, 'Duplicate requests must stay guarded')
  assert.equal(requests.length, 1)
  requests[0].callback({ outcome: 'applied' }, null)
  assert.equal(p.defaultSetPending, false)
  assert.equal(p.setDefaultDevice(output, output, 'output'), true)
  assert.equal(requests[1].params.previous.id, output.id, 'A live previous default must retain conflict protection')
  requests[1].callback({ outcome: 'persistence_failed', message: 'Preference was not saved' }, null)
  assert.equal(p.defaultOutputError, 'Preference was not saved')
}

{
  const { context: p, output, requests } = panel()
  p.audioService.busy = true
  assert.equal(p.setDefaultDevice(output, null, 'output'), true,
    'A level operation must not block selection; the backend serializes it')
  requests[0].callback({ outcome: 'applied' }, null)
  p.audioService.transactionBusy = true
  assert.equal(p.setDefaultDevice(output, null, 'output'), false)
  assert.equal(requests.length, 1, 'A conflicting transaction must stay guarded')
  assert(p.interactionError)
}

for (const action of ['toggleOutputMute', 'toggleInputMute', 'adjustVolume']) {
  const { context: p, levels } = panel()
  p.defaultOutputError = 'Preference was not saved'
  p.audioService.transactionBusy = true
  p[action](.1)
  assert(p.interactionError, action + ' must explain a busy rejection')
  assert.equal(levels.length, 0)
  p.audioService.transactionBusy = false
  p[action](.1)
  assert(levels.length > 0, action + ' must accept a retry')
  assert.equal(p.interactionError, '', action + ' must clear temporary rejection feedback')
  assert.equal(p.defaultOutputError, 'Preference was not saved', 'A mute/level retry must preserve unsaved-default errors')
}

{
  const { context: p, requests } = panel()
  p.defaultOutputError = 'Preference was not saved'
  p.audioService.transactionBusy = true
  p.toggleAllMuted()
  assert(p.interactionError, 'toggleAllMuted must explain a busy rejection')
  assert.equal(requests.length, 0)
  p.audioService.transactionBusy = false
  assert.equal(p.toggleAllMuted(), true)
  assert.equal(requests.length, 1)
  assert.equal(requests[0].method, 'audio.mute_all')
  assert.equal(requests[0].params.generation, 'g')
  assert.equal(requests[0].params.muted, true)
  assert.equal(p.masterMutePending, true)
  assert.equal(p.interactionError, '')
  assert.equal(p.defaultOutputError, 'Preference was not saved')
  assert.equal(p.toggleAllMuted(), false, 'Duplicate master mute must stay guarded')
  requests[0].callback({ outcome: 'applied' }, null)
  assert.equal(p.masterMutePending, false)
  // Default mic muted while a pinned recording mic is still live must report in-use and audible.
  p.inputMuted = true
  p.outputMuted = true
  p.recordingApplicationCount = 1
  p.activeRecordingLabels = ['Recorder']
  p.audioService.state.master = {
    hasOutput: true, hasInput: true, anyAudible: true,
    recordingActive: true, recordingMuted: false
  }
  assert.equal(p.anyAudible, true)
  assert.equal(p.activeRecordingMuted, false)
  assert.match(p.recordingTooltip, /Microphone in use/)
  assert.match(p.recordingTooltip, /Middle-click to mute microphone/)
  assert.equal(p.toggleBarInputMute(), true)
  assert.equal(requests.length, 2)
  assert.equal(requests[1].method, 'audio.mute_all')
  assert.equal(requests[1].params.generation, 'g')
  assert.equal(requests[1].params.muted, true)
  assert.equal(requests[1].params.scope, 'inputs')
  requests[1].callback({ outcome: 'applied' }, null)
  assert.equal(p.masterMutePending, false)
  p.audioService.state.master = {
    hasOutput: true, hasInput: true, anyAudible: false,
    recordingActive: true, recordingMuted: true
  }
  assert.equal(p.anyAudible, false)
  assert.equal(p.activeRecordingMuted, true)
  assert.match(p.recordingTooltip, /Microphone muted/)
  assert.match(p.recordingTooltip, /Middle-click to unmute microphone/)
  assert.equal(p.toggleBarInputMute(), true)
  assert.equal(requests.length, 3)
  assert.equal(requests[2].params.generation, 'g')
  assert.equal(requests[2].params.muted, false)
  assert.equal(requests[2].params.scope, 'inputs')
  requests[2].callback({ outcome: 'applied' }, null)
}

// Fast slider drag through the real Panel, Service, and AudioProtocol handlers
// must coalesce in-flight updates and deliver the final released level even
// when replies are delayed or the transport queue is saturated.
{
  const output = node(1)
  const sent = [], acknowledged = []
  const serviceContext = {
    Model, Protocol, ready: false, error: '', lastLevelError: '', state: {}, transactionBusy: false,
    inFlightNodeChanges: {}, pendingNodeChanges: {}, activeTransactions: 0, nodeChangeEpoch: 0, client: null
  }
  serviceContext.root = serviceContext
  vm.createContext(serviceContext)
  for (const match of serviceSource.matchAll(/^  function \w+\([^\n]*\) \{[\s\S]*?^  \}/gm))
    vm.runInContext(match[0], serviceContext)

  const client = new Protocol.Client({
    write: frame => sent.push(JSON.parse(frame)),
    ready: value => {
      serviceContext.ready = value
      if (!value) serviceContext.clearNodeChanges()
    },
    state: value => { serviceContext.state = value },
    capacity: () => serviceContext.flushNodeChanges(),
    fault: message => { throw new Error('Unexpected protocol fault: ' + message) }
  })
  serviceContext.client = client
  const reply = (req, result) => {
    if (req.method === 'node.level') acknowledged.push(req.params.volume)
    client.feed(JSON.stringify({ version: 1, id: req.id, result }) + '\n')
  }
  const event = (name, data) => client.feed(JSON.stringify({ version: 1, event: name, data }) + '\n')
  client.open()
  reply(sent.at(-1), {
    name: 'omarchy-audio-service', protocolVersion: 1, epoch: 'e1', buildId: 'b1',
    transport: 'jsonl-ascii', capabilities: ['state.subscribe', 'node.level'],
    maxFrameBytes: Protocol.MAX_FRAME, maxSnapshotBytes: 8388608
  })
  reply(sent.at(-1), { subscribed: true })
  const snap = JSON.stringify({
    epoch: 'e1', revision: '1', graphReady: true, generation: 'g1', busy: false,
    nodes: [{ id: 1, serial: '1' }]
  })
  event('snapshot.begin', { bytes: snap.length, parts: 1 })
  event('snapshot.part', { index: 0, text: snap })
  event('snapshot.end', {})
  assert.equal(serviceContext.ready, true)

  const { context: p } = panel()
  p.nodes = [output]
  p.volumeSink = output
  p.audioService = serviceContext
  p.audioService.transactionBusy = false

  // Hold replies across 40 pointer moves ending at 100%.
  for (let i = 1; i <= 40; i++) p.setOutputVolume(i / 40)
  p.setOutputVolume(1.0) // release
  assert.equal(sent.filter(r => r.method === 'node.level').length, 1,
    'In-flight slider moves must coalesce instead of flooding the protocol queue')
  while (sent.some(r => r.method === 'node.level' && !r._done)) {
    const next = sent.find(r => r.method === 'node.level' && !r._done)
    next._done = true
    reply(next, { outcome: 'applied' })
  }
  assert.equal(acknowledged.at(-1), 1.0, 'Final acknowledged level must match released 100% position')
  assert.equal(serviceContext.error, '')

  // Now saturate all 32 pending slots with other requests before dragging down to 25%.
  const fillers = []
  for (let i = 0; i < 32; i++) {
    assert.notEqual(serviceContext.request('health', {}, null), '')
    fillers.push(sent.at(-1))
  }
  for (let i = 39; i >= 10; i--) p.setOutputVolume(i / 40)
  assert.equal(sent.filter(r => r.method === 'node.level' && !r._done).length, 0)
  reply(fillers.shift(), { status: 'ok' })
  const pendingLevel = sent.find(r => r.method === 'node.level' && !r._done)
  assert(pendingLevel, 'Queued level must transmit as soon as protocol capacity returns')
  pendingLevel._done = true
  reply(pendingLevel, { outcome: 'applied' })
  assert.equal(acknowledged.at(-1), 0.25)
  for (const filler of fillers) reply(filler, { status: 'ok' })

  // A transactional command started while a node.level reply is still in flight
  // must discard stale queued slider/mute tails so they cannot flush afterward.
  p.setOutputVolume(0.4)
  p.setOutputVolume(0.95)
  const inFlightLevel = sent.find(r => r.method === 'node.level' && !r._done)
  assert(inFlightLevel)
  assert.equal(Object.keys(serviceContext.pendingNodeChanges).length, 1)
  let muteApplied = false
  assert.notEqual(serviceContext.request('audio.mute_all', { generation: 'g1', muted: true }, () => { muteApplied = true }), '')
  const muteReq = sent.at(-1)
  assert.equal(Object.keys(serviceContext.pendingNodeChanges).length, 0)
  inFlightLevel._done = true
  reply(inFlightLevel, { outcome: 'applied' })
  assert.equal(sent.filter(r => r.method === 'node.level' && !r._done).length, 0,
    'Stale queued node.level must not flush behind audio.mute_all')
  reply(muteReq, { outcome: 'applied' })
  assert.equal(muteApplied, true)
  assert.equal(serviceContext.activeTransactions, 0)
  assert.equal(sent.filter(r => r.method === 'node.level' && !r._done).length, 0)

  // Synchronously rejected transactional request must not wipe pendingNodeChanges.
  p.setOutputVolume(0.3)
  p.setOutputVolume(0.75)
  const busyFirst = sent.find(r => r.method === 'node.level' && !r._done)
  assert(busyFirst)
  assert.equal(Object.keys(serviceContext.pendingNodeChanges).length, 1)
  assert.equal(serviceContext.request('BAD METHOD!', {}, null), '')
  assert.equal(Object.keys(serviceContext.pendingNodeChanges).length, 1,
    'Synchronous request rejection must preserve queued slider updates')
  busyFirst._done = true
  reply(busyFirst, { outcome: 'applied' })
  const flushedAfterReject = sent.find(r => r.method === 'node.level' && !r._done)
  assert(flushedAfterReject)
  assert.equal(flushedAfterReject.params.volume, 0.75)
  flushedAfterReject._done = true
  reply(flushedAfterReject, { outcome: 'applied' })

  // A suppressed matching release must retry if the in-flight level fails with busy,
  // and successful level replies must not clobber unrelated root.error values.
  serviceContext.error = 'Unrelated status error'
  p.setOutputVolume(0.6)
  p.setOutputVolume(0.6) // matching release while 0.6 is in flight
  const retryable = sent.find(r => r.method === 'node.level' && !r._done)
  assert(retryable)
  retryable._done = true
  client.feed(JSON.stringify({
    version: 1, id: retryable.id,
    error: { code: 'busy', message: 'Audio route is updating', outcome: 'rejected' }
  }) + '\n')
  const retried = sent.find(r => r.method === 'node.level' && !r._done)
  assert(retried, 'Suppressed matching release must re-queue after busy rejection')
  assert.equal(retried.params.volume, 0.6)
  retried._done = true
  reply(retried, { outcome: 'applied' })
  assert.equal(serviceContext.error, 'Unrelated status error',
    'Successful node.level must not clear an unrelated service error')
  serviceContext.error = ''

  // A late busy reply from a pre-scene slider request must not re-queue 60%
  // after scene.apply has already been dispatched.
  p.setOutputVolume(0.6)
  p.setOutputVolume(0.6) // matching release marks retryOnBusy on the in-flight 60% request
  const staleSlider = sent.find(r => r.method === 'node.level' && !r._done)
  assert(staleSlider)
  assert.equal(staleSlider.params.volume, 0.6)
  let sceneApplied = false
  assert.notEqual(serviceContext.request('scene.apply', {
    scene: { name: 'Quiet', steps: [{ kind: 'device', direction: 'output', name: 'node_1', volume: 0.2, balance: 0 }] }
  }, () => { sceneApplied = true }), '')
  const sceneReq = sent.at(-1)
  staleSlider._done = true
  client.feed(JSON.stringify({
    version: 1, id: staleSlider.id,
    error: { code: 'busy', message: 'Audio route is updating', outcome: 'rejected' }
  }) + '\n')
  reply(sceneReq, { outcome: 'applied', applied: 1, errors: [] })
  assert.equal(sceneApplied, true)
  assert.equal(Object.keys(serviceContext.pendingNodeChanges).length, 0,
    'Late busy reply from pre-scene slider must not re-queue after scene.apply')
  assert.equal(sent.filter(r => r.method === 'node.level' && !r._done).length, 0,
    'Stale 60% slider retry must not overwrite newly applied scene')
}

// Cancelling a microphone test while start is waiting for the mutation lock
// must immediately dispatch microphone.stop instead of exiting because pending is true.
{
  const input = node(2, 'Audio/Source')
  const requests = []
  const mic = {
    Model,
    inputDevice: input,
    inputDeviceLive: true,
    sessionActive: true,
    owner: 'mic-test-owner',
    pending: false,
    cancelPending: false,
    pendingRecord: false,
    localError: '',
    secondsRemaining: 0,
    peakMonitor: { peak: 0 },
    service: {
      ready: true,
      state: { microphone: { owner: 'mic-test-owner', state: 'idle', error: '' } },
      identityForNode(n) { return n === input ? { generation: 'g1', id: 2, serial: '2' } : null },
      request(method, params, callback) { requests.push({ method, params, callback }); return 'r' + requests.length }
    }
  }
  mic.root = mic
  vm.createContext(mic)
  for (const match of micControllerSource.matchAll(/^  function \w+\([^\n]*\) \{[\s\S]*?^  \}/gm))
    vm.runInContext(match[0], mic)
  for (const [kind, name] of [
    ['var', 'job'],
    ['string', 'rawTestState'],
    ['string', 'testState'],
    ['string', 'error'],
    ['bool', 'microphoneMuted'],
    ['bool', 'busy']
  ]) {
    const expression = micControllerSource.match(new RegExp('readonly property ' + kind + ' ' + name + ': ([^\\n]*(?:\\n    [^\\n]*)*)'))[1]
    Object.defineProperty(mic, name, { get: () => vm.runInContext(expression, mic) })
  }

  mic.activate()
  assert.equal(mic.pending, true)
  assert.equal(requests.length, 1)
  assert.equal(requests[0].method, 'microphone.start')
  mic.service.state.microphone = { owner: 'mic-test-owner', state: 'starting', error: '' }
  assert.equal(mic.testState, 'starting')

  // Clicking Cancel while pending is still true must dispatch microphone.stop.
  mic.activate()
  assert.equal(requests.length, 2, 'Cancel while starting must send microphone.stop even when pending is true')
  assert.equal(requests[1].method, 'microphone.stop')
  assert.equal(requests[1].params.discard, true)
  assert.equal(mic.testState, 'cancelling')

  // Repeated clicks while cancelling must not spam duplicate stop requests.
  mic.activate()
  assert.equal(requests.length, 2)

  // Start request returning cancelled must clear pending and leave no user-facing error.
  requests[1].callback({ stopping: true }, null)
  requests[0].callback(null, { code: 'cancelled', message: 'Microphone test was cancelled before starting' })
  mic.service.state.microphone = { owner: 'mic-test-owner', state: 'idle', error: '' }
  assert.equal(mic.pending, false)
  assert.equal(mic.testState, 'idle')
  assert.equal(mic.error, '')
}

// Compact picker must display and preselect the live PipeWire default even
// when an older device preference is saved and the default changed externally.
{
  const headphones = node(10, 'Audio/Sink')
  headphones.name = 'alsa_output.headphones'
  headphones.properties['node.name'] = headphones.name
  const speakers = node(11, 'Audio/Sink')
  speakers.name = 'alsa_output.speakers'
  speakers.properties['node.name'] = speakers.name
  const usbMic = node(20, 'Audio/Source')
  usbMic.name = 'alsa_input.usb'
  usbMic.properties['node.name'] = usbMic.name
  const internalMic = node(21, 'Audio/Source')
  internalMic.name = 'alsa_input.internal'
  internalMic.properties['node.name'] = internalMic.name

  const { context: p } = panel()
  p.displayAudioSinks = [headphones, speakers]
  p.preferredOutputName = 'alsa_output.headphones'
  p.sink = speakers
  assert.equal(p.activeOutputRowNode, speakers,
    'Collapsed output picker must name the live PipeWire default, not the saved preference')
  p.toggleDeviceList('output')
  assert.equal(p.outputDevicesExpanded, true)
  assert.equal(p.selectedIndex, 1,
    'Opening the output picker must preselect the live PipeWire default')

  p.displayAudioSources = [usbMic, internalMic]
  p.preferredInputName = 'alsa_input.usb'
  p.source = internalMic
  assert.equal(p.activeInputRowNode, internalMic,
    'Collapsed input picker must name the live PipeWire default, not the saved preference')
  p.toggleDeviceList('input')
  assert.equal(p.inputDevicesExpanded, true)
  assert.equal(p.selectedIndex, 1,
    'Opening the input picker must preselect the live PipeWire default')

  // When no live default is reported, fall back to the saved preference.
  p.sink = null
  assert.equal(p.activeOutputRowNode, headphones)

  // Compact pickers must not expand when only a single device is selectable.
  p.compactDevices = true
  p.outputDevicesExpanded = false
  p.inputDevicesExpanded = false
  p.displayAudioSinks = [speakers]
  p.displayAudioSources = [internalMic]
  assert.equal(p.outputDevicesCollapsed, true)
  assert.equal(p.inputDevicesCollapsed, true)
  assert.equal(p.sectionCount('output'), 0)
  assert.equal(p.sectionCount('input'), 0)
  assert.equal(p.toggleDeviceList('output'), false)
  assert.equal(p.outputDevicesExpanded, false)
  assert.equal(p.toggleDeviceList('input'), false)
  assert.equal(p.inputDevicesExpanded, false)
  // Even if expanded before a second device unplugged, collapsing stays enforced at 1 device.
  p.outputDevicesExpanded = true
  p.inputDevicesExpanded = true
  assert.equal(p.outputDevicesCollapsed, true)
  assert.equal(p.inputDevicesCollapsed, true)
}

{
  const { context: p, stream, requests } = panel()
  p.setStreamRoute(stream, 'override:99', 'playback')
  assert(p.interactionError, 'A vanished route target must produce feedback')
  assert.equal(requests.length, 0)
  p.setStreamRoute(stream, 'override:1', 'playback')
  assert.equal(p.interactionError, '')
  assert.equal(requests.length, 1)
  requests[0].callback(null, { message: 'Route was rejected' })
  assert.equal(p.pendingStreamRoute, null)
  assert.equal(p.streamRouteSetError, 'Route was rejected')
}

{
  const { context: p, output, requests } = panel()
  p.nodes = p.nodes.filter(n => n !== output)
  assert.equal(p.setDefaultDevice(output, null, 'output'), false)
  assert(p.interactionError, 'A stale selected device must produce feedback')
  assert.equal(requests.length, 0)
}

console.log('PASS: stale defaults, guarded transactions, retry feedback and persistent failures')
