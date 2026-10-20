const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const Model = require('../qml/core/Model.js')

const source = fs.readFileSync(require.resolve('../qml/panels/Panel.qml'), 'utf8')
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
    hasOutput: true, hasInput: true, anyAudible: true,
    defaultOutputError: '', defaultInputError: '', streamRouteSetError: '', interactionError: '',
    defaultSetPending: false, pendingStreamRoute: null, streamOutputMenuOpen: false,
    sceneController: { busy: false }, rulesStore: { busy: false }, outputGroups: { busy: false },
    interactionErrorTimer: { restart() {}, stop() {} },
    audioService: {
      ready: true, busy: false, transactionBusy: false,
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
  for (const name of ['routeMutationBusy', 'directDeviceMutationBusy', 'sceneMutationBusy']) {
    const expression = source.match(new RegExp('readonly property bool ' + name + ': ([^\\n]*(?:\\n    [^\\n]*)*)'))[1]
    Object.defineProperty(context, name, { get: () => vm.runInContext(expression, context) })
  }
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

for (const action of ['toggleOutputMute', 'toggleInputMute', 'toggleAllMuted', 'adjustVolume']) {
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
