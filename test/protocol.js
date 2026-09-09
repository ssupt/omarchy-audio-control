const assert = require('node:assert/strict')
const { Client, utf8Length, MAX_FRAME } = require('../qml/core/AudioProtocol.js')

function fixture(expectedBuildId) {
  const sent = [], states = [], faults = [], callbacks = [], deadlines = []
  let time = 1000
  const client = new Client({
    expectedBuildId,
    now: () => time,
    write: frame => sent.push(JSON.parse(frame)),
    state: state => states.push(state),
    fault: message => faults.push(message),
    ready: () => {},
    deadline: value => deadlines.push(value),
    callbackError: () => callbacks.push('threw')
  })
  const reply = (request, result, version = 1) => client.feed(JSON.stringify({ version, id: request.id, result }) + '\n')
  const event = (name, data) => client.feed(JSON.stringify({ version: 1, event: name, data }) + '\n')
  function negotiate() {
    client.open()
    reply(sent.at(-1), { name: 'omarchy-audio-service', protocolVersion: 1,
      epoch: 'test-epoch', buildId: 'test-build', transport: 'jsonl-ascii', capabilities: ['state.subscribe'],
      maxFrameBytes: MAX_FRAME, maxSnapshotBytes: 8388608 })
    reply(sent.at(-1), { subscribed: true })
  }
  function connect() {
    negotiate()
    const state = JSON.stringify({ epoch: 'test-epoch', revision: '1', nodes: [], busy: false })
    event('snapshot.begin', { bytes: state.length, parts: 2 })
    event('snapshot.part', { index: 0, text: state.slice(0, 7) })
    assert.equal(states.length, 0, 'partial state must not reach the UI')
    event('snapshot.part', { index: 1, text: state.slice(7) })
    event('snapshot.end', {})
    assert.equal(client.ready, true)
  }
  return { client, sent, states, faults, callbacks, deadlines, reply, event, connect, negotiate, advance: milliseconds => { time += milliseconds; client.tick() } }
}

{
  const f = fixture(); f.connect()
  assert.equal(f.deadlines.at(-1), 0, 'idle connections must stop the deadline timer')
  f.client.request('health', {}, null, { timeout: 1000 })
  assert.equal(f.deadlines.at(-1), 2000)
  const first = f.sent.at(-1)
  f.client.request('health', {}, null, { timeout: 2000 })
  assert.equal(f.deadlines.at(-1), 2000, 'later requests must not defer the earliest deadline')
  f.reply(first, {})
  assert.equal(f.deadlines.at(-1), 3000)
  f.reply(f.sent.at(-1), {})
  assert.equal(f.deadlines.at(-1), 0)
  f.client.feed('{')
  assert.equal(f.deadlines.at(-1), 6000, 'partial frames need a deadline without pending requests')
  const count = f.deadlines.length
  f.client.feed('"version"')
  assert.equal(f.deadlines.length, count, 'partial input must not restart its timeout')
  f.advance(4999)
  assert.equal(f.deadlines.at(-1), 6000, 'an early timer firing must rearm its remaining time')
  f.advance(1)
  assert.equal(f.client.connected, false)
  assert.equal(f.deadlines.at(-1), 0)
}
{
  const f = fixture(); f.negotiate()
  assert.equal(f.deadlines.at(-1), 11000, 'the initial state deadline survives the subscription reply')
  f.advance(10000)
  assert.equal(f.client.connected, false)
  assert.equal(f.deadlines.at(-1), 0)
}
{
  const f = fixture(); f.connect()
  f.event('snapshot.begin', { bytes: 50, parts: 2 })
  assert.equal(f.deadlines.at(-1), 11000)
  f.advance(10000)
  assert.equal(f.client.connected, false, 'an incomplete snapshot must expire while otherwise idle')
}
{
  const f = fixture(); f.connect()
  f.client.request('health', {}, () => f.client.request('health', {}, null, { timeout: 2000 }), { timeout: 1000 })
  f.reply(f.sent.at(-1), {})
  assert.equal(f.deadlines.at(-1), 3000, 'callbacks may submit the next request')
  f.client.reset({ code: 'disconnected', message: 'gone' })
  assert.equal(f.deadlines.at(-1), 0)
}

{
  const f = fixture(); f.connect()
  assert.equal(f.states.length, 1)
  let calls = 0
  const id = f.client.request('node.audio', {}, () => calls++)
  const frame = JSON.stringify({ version: 1, id, result: { label: '\uD83C\uDFA7' } })
    .replace(/[^\x00-\x7f]/g, unit => '\\u' + unit.charCodeAt(0).toString(16).padStart(4, '0')) + '\n'
  for (const ch of frame) f.client.feed(ch)
  assert.equal(calls, 1)
  f.client.feed(frame)
  assert.equal(calls, 1, 'duplicate replies must not call twice')
  f.client.feed('{"version":1,"id":"__proto__","result":{}}\n')
  assert.equal(calls, 1, 'inherited map keys must not become callbacks')
}
{
  const f = fixture(); f.client.open()
  f.reply(f.sent[0], {}, 999)
  assert.equal(f.client.connected, false)
  assert.ok(f.faults.length)
}
{
  const f = fixture('test-build'); f.connect()
  assert.equal(f.client.info.buildId, 'test-build')
}
{
  const f = fixture('different-build'); f.negotiate()
  assert.equal(f.client.ready, false)
  assert.equal(f.client.connected, false)
  assert.equal(f.sent.length, 1, 'a mismatched build must not acquire an automation subscription')
  let rejection
  f.client.request('node.audio', {}, (_result, error) => rejection = error)
  assert.equal(rejection.code, 'not_ready')
  assert.equal(f.sent.length, 1, 'a mismatched build must not accept mutations')
  assert.match(f.faults[0], /releases do not match/)
}
{
  const f = fixture(); f.client.open(); f.advance(5001)
  assert.equal(Object.keys(f.client.pending).length, 0)
  assert.equal(f.client.connected, false)
}
{
  const f = fixture(); f.negotiate()
  assert.equal(Object.keys(f.client.pending).length, 0)
  f.advance(10001)
  assert.equal(f.client.connected, false, 'a subscription with no initial snapshot must time out')
  assert.equal(f.states.length, 0)
}
{
  const f = fixture(); f.connect()
  const results = []
  f.client.request('node.audio', {}, (result, error) => results.push(error), { timeout: 1000 })
  f.advance(1001)
  assert.equal(results.length, 1)
  assert.equal(results[0].outcome, 'unknown', 'timed out mutation must not be called rejected')
  assert.equal(f.client.connected, false)
  assert.equal(f.sent.filter(request => request.method === 'node.audio').length, 1, 'never replay a mutation')
}
{
  const f = fixture(); f.connect()
  const requests = []
  f.client.request('node.audio', {}, () => { throw new Error('consumer error') })
  f.client.request('node.audio', {}, (_result, error) => {
    requests.push(error)
    f.client.request('node.audio', {}, (_result, nextError) => requests.push(nextError))
  })
  f.client.reset({ code: 'disconnected', message: 'gone' })
  assert.equal(f.callbacks.length, 1)
  assert.equal(requests.length, 2)
  assert.equal(Object.keys(f.client.pending).length, 0)
  assert.equal(requests[0].outcome, 'unknown')
  assert.equal(requests[1].outcome, 'rejected')
}
{
  const f = fixture(); f.connect()
  f.client.feed('x'.repeat(MAX_FRAME))
  assert.equal(f.client.buffer.length, 0)
  assert.equal(f.client.connected, false)
}
{
  const f = fixture(); f.connect()
  f.client.feed('{')
  f.advance(5001)
  assert.equal(f.client.connected, false)
}
{
  const f = fixture(); f.connect()
  f.event('snapshot.begin', { bytes: 8388609, parts: 1 })
  assert.equal(f.client.connected, false)
  assert.equal(f.states.length, 1)
}
{
  const f = fixture(); f.connect()
  f.event('snapshot.begin', { bytes: 50, parts: 2 })
  f.event('snapshot.part', { index: 1, text: 'out-of-order' })
  assert.equal(f.client.connected, false)
}
{
  const f = fixture(); f.connect()
  for (let i = 0; i < 32; i++) assert.notEqual(f.client.request('node.audio', {}, null), '')
  let rejected
  assert.equal(f.client.request('node.audio', {}, (_result, error) => rejected = error), '')
  assert.equal(rejected.code, 'busy')
}
for (const value of ['ascii', 'Cuffie 🎧', '日本語', '\u0000', '\n', '\\uD83C']) {
  assert.equal(utf8Length(value), Buffer.byteLength(value))
}
console.log('PASS: bounded service protocol, deadlines, snapshots, and failure outcomes')
