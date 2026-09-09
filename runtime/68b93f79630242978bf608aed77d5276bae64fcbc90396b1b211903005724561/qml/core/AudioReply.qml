import QtQuick

// Buffered compatibility output for an AudioCommand response. It never reads a
// process pipe; the service enforces the byte and execution limits.
QtObject {
  property bool waitForEnd: true
  property string text: ""
  signal streamFinished()
}
