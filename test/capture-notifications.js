const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const Model = require('../qml/core/Model.js')

const panel = fs.readFileSync(require.resolve('../qml/panels/Panel.qml'), 'utf8')
const service = fs.readFileSync(require.resolve('../qml/core/Service.qml'), 'utf8')
const notifications = []

// Execute the real QML observer for the shell's one service and three panels.
function observer(source) {
  const body = source.match(/  function observeRecordingApplications\(\) \{([\s\S]*?)\n  \}/)
  if (!body) return null
  const context = vm.createContext({
    Model, Quickshell: { execDetached: command => notifications.push(command) },
    activeRecordingLabels: [], observedRecordingLabels: [],
    captureNotifications: true, notificationsAvailable: true,
    listSnapshot: Model.listSnapshot
  })
  context.observe = vm.runInContext('(function() {' + body[1] + '\n})', context)
  return context
}

const observers = [observer(service), ...Array.from({ length: 3 }, () => observer(panel))].filter(Boolean)
function update(labels) {
  for (const owner of observers) {
    owner.activeRecordingLabels = labels
    owner.observe()
  }
}

// Startup captures form a silent baseline, as in the QML warmup timer.
for (const owner of observers) owner.observedRecordingLabels = ['Already running']
update(['Already running'])
assert.equal(notifications.length, 0, 'Startup captures must stay silent')
update([])

update(['Firefox'])
assert.equal(notifications.length, 1, 'One capture must send once across three monitors')
assert.equal(notifications[0].at(-1), 'Firefox is now using the microphone.')
update(['Firefox'])
assert.equal(notifications.length, 1, 'An unchanged capture must stay silent')
update(['Firefox', 'Discord'])
assert.equal(notifications.length, 2, 'A different app must notify without a cooldown')
update([])
update(['Firefox'])
assert.equal(notifications.length, 3, 'A stopped app may notify again immediately')

for (const owner of observers) owner.captureNotifications = false
update(['Firefox', 'Zoom'])
assert.equal(notifications.length, 3, 'The preference must disable notifications')
for (const owner of observers) owner.captureNotifications = true
update(['Firefox', 'Zoom'])
assert.equal(notifications.length, 3, 'Re-enabling must not replay existing captures')
for (const owner of observers) owner.notificationsAvailable = false
update(['Firefox', 'Zoom', 'Discord'])
assert.equal(notifications.length, 3, 'A missing notify-send must stay silent')

console.log('PASS: one shared capture sender, rapid changes, restart and notification preference')
