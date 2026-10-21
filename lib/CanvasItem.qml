import QtQuick

// A single canvas object.
//
// Declared as a QtObject (not a plain JS object) on purpose: QML bindings on
// its properties only re-evaluate when the property actually notifies, and a
// plain JS object never does. Making it a real object type is what lets an
// object's x/y/w/h update on screen while it is dragged, without rebuilding
// the whole canvas.
QtObject {
  id: root

  property string objId: ""
  property string type: "text"      // text | sticky | title | heading | shape | image
  property real x: 0
  property real y: 0
  property real w: 100
  property real h: 100
  property real rot: 0
  property real z: 1
  property string text: ""
  property string src: ""
  property string color: ""
  property string stroke: ""
  property string shape: "rect"      // rect | ellipse | line | arrow
  property bool visible: true
  property bool locked: false
  property real opacity: 1

  // Snapshot as a plain object for serialization.
  function toData() {
    return {
      id: root.objId,
      type: root.type,
      x: root.x, y: root.y, w: root.w, h: root.h,
      rot: root.rot, z: root.z,
      text: root.text,
      src: root.src,
      color: root.color,
      stroke: root.stroke,
      shape: root.shape,
      visible: root.visible,
      locked: root.locked,
      opacity: root.opacity,
    }
  }

  // Restore from a plain object.
  function fromData(data) {
    root.objId = String(data.id || "")
    root.type = String(data.type || "text")
    root.x = Number(data.x) || 0
    root.y = Number(data.y) || 0
    root.w = Number(data.w) || 100
    root.h = Number(data.h) || 100
    root.rot = Number(data.rot) || 0
    root.z = Number(data.z) || 1
    root.text = String(data.text || "")
    root.src = String(data.src || "")
    root.color = String(data.color || "")
    root.stroke = String(data.stroke || "")
    root.shape = String(data.shape || "rect")
    root.visible = data.visible !== false
    root.locked = !!data.locked
    root.opacity = data.opacity === undefined ? 1 : (Number(data.opacity) || 1)
  }
}
