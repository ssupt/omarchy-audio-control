import QtQuick

// The service owns the complete scene and its verification/rollback lifetime.
Item {
  id: root
  property var service: null
  property bool busy: false
  signal applyFinished(var result)
  signal captureFinished(var scene)
  signal captureFailed(string error)

  function apply(scene) {
    if (busy || !service || !service.ready) return
    busy = true
    service.request("scene.apply", { scene: scene }, function(result, error) {
      root.busy = false
      root.applyFinished(error ? {
        name: scene.name, applied: 0, skipped: [], errors: [error.message], outcome: error.outcome
      } : result)
    })
  }
  function capture(name) {
    if (busy || !service || !service.ready) return
    busy = true
    service.request("scene.capture", { name: String(name || "") }, function(scene, error) {
      root.busy = false
      if (error) root.captureFailed(error.message)
      else {
        scene.savedAt = new Date().toISOString()
        root.captureFinished(scene)
      }
    })
  }
}
