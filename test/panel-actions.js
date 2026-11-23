const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const Model = require('../qml/core/Model.js')
const Protocol = require('../qml/core/AudioProtocol.js')

const source = fs.readFileSync(require.resolve('../qml/panels/Panel.qml'), 'utf8')
const serviceSource = fs.readFileSync(require.resolve('../qml/core/Service.qml'), 'utf8')
function node(id, mediaClass = 'Audio/Sink') {
  return { id, ready: true, audio: { volume: .5, muted: false },
    properties: { 'object.serial': String(id), 'node.name': 'node_' + id, 'media.class': mediaClass } }
}
function panel() {
  const output = node(1), input = node(2, 'Audio/Source'), stream = node(3, 'Stream/Output/Audio')
  const requests = [], levels = []
  const context = {
    Model, nodes: [output, input, stream], volumeSink: output, source: input,
    audioStreams: [stream], recordingStreams: [], candidateSinks: [output], candidateSources: [input],
    displayAudioStreams: [stream], displayRecordingStreams: [],
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
    ['bool', 'anyAudible']
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
  p.audioService.state.master = {
    hasOutput: true, hasInput: true, anyAudible: false,
    recordingActive: true, recordingMuted: true
  }
  assert.equal(p.anyAudible, false)
  assert.equal(p.activeRecordingMuted, true)
  assert.match(p.recordingTooltip, /Microphone muted/)
}

// Fast slider drag through the real Panel, Service, and AudioProtocol handlers
// must coalesce in-flight updates and deliver the final released level even
// when replies are delayed or the transport queue is saturated.
{
  const output = node(1)
  const sent = [], acknowledged = []
  const serviceContext = {
    Model, Protocol, ready: false, error: '', state: {},
    inFlightNodeChanges: {}, pendingNodeChanges: {}, client: null
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
