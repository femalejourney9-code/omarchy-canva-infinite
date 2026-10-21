import QtQuick
import Quickshell.Io
import qs.Commons

// Canvas document model: geometry, camera, selection, undo/redo, autosave.
//
// Coordinates are canvas units, not screen pixels. Panning moves `camera.x/y`
// and zooming scales `camera.zoom`, so the document itself never moves when the
// camera does — which is what keeps an infinite canvas infinite.
//
// Objects are CanvasItem QtObjects (see lib/CanvasItem.qml), not plain JS
// objects: their property changes notify QML, which is what makes a drag update
// the screen without rebuilding the canvas.
//
// Every mutation snapshots the document first. That snapshot is the whole undo
// system — no command objects, no per-field diffing.
QtObject {
  id: root

  // ---- document state -----------------------------------------------------

  // Reassigning this array is what tells the view to rebuild. Never mutate it
  // in place.
  property var objects: []
  property string docId: ""
  property string title: ""
  property int nextId: 1
  property real gridSize: 20
  property bool showGrid: true
  property color canvasBg: Color.background

  // Camera: top-left of the viewport in canvas space, plus a uniform zoom.
  property real camX: 0
  property real camY: 0
  property real zoom: 1

  readonly property var camera: QtObject {
    readonly property real x: root.camX
    readonly property real y: root.camY
    readonly property real zoom: root.zoom
  }

  // ---- interaction state (not persisted) -----------------------------------

  property var selectedIds: []
  property bool panning: false
  property string editingId: ""
  property bool dirty: false
  property bool ready: false

  // ---- undo / redo ---------------------------------------------------------

  property var undoStack: []
  property var redoStack: []
  readonly property bool canUndo: undoStack.length > 0
  readonly property bool canRedo: redoStack.length > 0

  // ---- persistence ---------------------------------------------------------

  property string dataDir: ""
  property string docPath: ""
  property var storage: null

  signal changed()
  signal saved()
  signal loaded()
  signal selectionChanged()

  // Factory for canvas objects. Created lazily so it only exists once the
  // component tree is ready.
  //
  // Referenced relatively (not via `Lib.`) because this file *is* the `lib`
  // module — a module cannot import itself, and `Lib.CanvasItem` from inside
  // lib/ resolves to nothing.
  property Component itemFactory: Component {
    CanvasItem { }
  }

  // ---- geometry helpers ----------------------------------------------------

  function deg(rad) { return rad * 180 / Math.PI }
  function rad(deg) { return deg * Math.PI / 180 }

  function toWorld(vx, vy) {
    return { x: vx / zoom + camX, y: vy / zoom + camY }
  }

  function rotatePoint(px, py, cx, cy, angleDeg) {
    var a = rad(angleDeg)
    var s = Math.sin(a)
    var c = Math.cos(a)
    var dx = px - cx
    var dy = py - cy
    return { x: cx + dx * c - dy * s, y: cy + dx * s + dy * c }
  }

  function worldBounds(o) {
    var r = ((o.rot % 360) + 360) % 360
    if (r < 0.001 || r > 179.999 && r < 180.001) return { x: o.x, y: o.y, w: o.w, h: o.h }
    if (r > 359.999) return { x: o.x, y: o.y, w: o.w, h: o.h }
    var cx = o.x + o.w / 2
    var cy = o.y + o.h / 2
    var corners = [
      rotatePoint(o.x, o.y, cx, cy, o.rot),
      rotatePoint(o.x + o.w, o.y, cx, cy, o.rot),
      rotatePoint(o.x + o.w, o.y + o.h, cx, cy, o.rot),
      rotatePoint(o.x, o.y + o.h, cx, cy, o.rot),
    ]
    var xs = corners.map(function (p) { return p.x })
    var ys = corners.map(function (p) { return p.y })
    var minX = Math.min.apply(null, xs)
    var maxX = Math.max.apply(null, xs)
    var minY = Math.min.apply(null, ys)
    var maxY = Math.max.apply(null, ys)
    return { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
  }

  function hitTest(o, p) {
    var b = worldBounds(o)
    var cx = b.x + b.w / 2
    var cy = b.y + b.h / 2
    var local = o.rot ? rotatePoint(p.x, p.y, cx, cy, -o.rot) : p
    return local.x >= b.x - 1 && local.x <= b.x + b.w + 1
      && local.y >= b.y - 1 && local.y <= b.y + b.h + 1
  }

  function handlePos(o, corner) {
    var b = worldBounds(o)
    var p
    if (corner === "tl") p = { x: b.x, y: b.y }
    else if (corner === "tr") p = { x: b.x + b.w, y: b.y }
    else if (corner === "bl") p = { x: b.x, y: b.y + b.h }
    else p = { x: b.x + b.w, y: b.y + b.h }
    if (o.rot) {
      var cx = b.x + b.w / 2
      var cy = b.y + b.h / 2
      p = rotatePoint(p.x, p.y, cx, cy, o.rot)
    }
    return p
  }

  function byId(id) {
    for (var i = 0; i < objects.length; i++) if (objects[i].objId === id) return objects[i]
    return null
  }

  function indexOf(id) {
    for (var i = 0; i < objects.length; i++) if (objects[i].objId === id) return i
    return -1
  }

  function topMostAt(p) {
    var best = null
    var bestZ = -Infinity
    for (var i = 0; i < objects.length; i++) {
      var o = objects[i]
      if (o.visible === false || o.locked) continue
      if (!hitTest(o, p)) continue
      if (o.z > bestZ) { bestZ = o.z; best = o }
    }
    return best
  }

  function nextZ() {
    var z = 0
    for (var i = 0; i < objects.length; i++) if (objects[i].z > z) z = objects[i].z
    return z + 1
  }

  function boundsOf(ids) {
    var sel = []
    for (var i = 0; i < objects.length; i++)
      if (ids.indexOf(objects[i].objId) !== -1) sel.push(objects[i])
    if (sel.length === 0) return null
    var bs = sel.map(worldBounds)
    var minX = Math.min.apply(null, bs.map(function (b) { return b.x }))
    var minY = Math.min.apply(null, bs.map(function (b) { return b.y }))
    var maxX = Math.max.apply(null, bs.map(function (b) { return b.x + b.w }))
    var maxY = Math.max.apply(null, bs.map(function (b) { return b.y + b.h }))
    return { x: minX, y: minY, w: maxX - minX, h: maxY - minY }
  }

  // ---- undo plumbing -------------------------------------------------------

  function snapshot() {
    var out = []
    for (var i = 0; i < objects.length; i++) out.push(objects[i].toData())
    return { objects: out, nextId: nextId }
  }

  function commit(label) {
    undoStack.push({ label: label, state: snapshot() })
    if (undoStack.length > 100) undoStack.shift()
    redoStack = []
    markDirty()
  }

  function markDirty() {
    dirty = true
    changed()
  }

  function undo() {
    if (undoStack.length === 0) return false
    var entry = undoStack.pop()
    redoStack.push({ label: entry.label, state: snapshot() })
    restore(entry.state)
    return true
  }

  function redo() {
    if (redoStack.length === 0) return false
    var entry = redoStack.pop()
    undoStack.push({ label: entry.label, state: snapshot() })
    restore(entry.state)
    return true
  }

  function restore(state) {
    applyDataObjects(state.objects)
    nextId = state.nextId
    selectedIds = selectedIds.filter(function (id) { return indexOf(id) >= 0 })
    if (editingId && indexOf(editingId) < 0) editingId = ""
    dirty = true
    changed()
  }

  // Replace the object array with fresh CanvasItems built from plain data.
  function applyDataObjects(list) {
    var out = []
    for (var i = 0; i < list.length; i++) {
      var item = itemFactory.createObject(null)
      if (!item) continue
      item.fromData(list[i])
      out.push(item)
    }
    objects = out
  }

  // ---- selection -----------------------------------------------------------

  function select(ids) {
    selectedIds = ids
    selectionChanged()
    changed()
  }

  function toggleSelect(id) {
    var idx = selectedIds.indexOf(id)
    var next = selectedIds.slice()
    if (idx === -1) next.push(id)
    else next.splice(idx, 1)
    selectedIds = next
    selectionChanged()
    changed()
  }

  function selectAll() {
    var ids = []
    for (var i = 0; i < objects.length; i++)
      if (objects[i].visible !== false) ids.push(objects[i].objId)
    selectedIds = ids
    selectionChanged()
    changed()
  }

  function clearSelection() {
    if (selectedIds.length === 0) return
    selectedIds = []
    selectionChanged()
    changed()
  }

  // ---- object lifecycle ----------------------------------------------------

  function createObject(props) {
    var o = itemFactory.createObject(null)
    if (!o) return ""
    o.objId = "o" + (nextId++)
    o.type = props.type || "text"
    o.x = props.x || 0
    o.y = props.y || 0
    o.w = props.w || 100
    o.h = props.h || 100
    o.rot = props.rot || 0
    o.z = props.z === undefined ? nextZ() : props.z
    o.text = props.text || ""
    o.src = props.src || ""
    o.color = props.color || ""
    o.stroke = props.stroke || ""
    o.shape = props.shape || "rect"
    o.visible = props.visible === undefined ? true : props.visible
    o.locked = !!props.locked
    o.opacity = props.opacity === undefined ? 1 : props.opacity
    if (o.type === "shape" && !o.shape) o.shape = "rect"

    // Structural change: reassign the array so the view rebuilds.
    commit("add")
    objects = objects.concat([o])
    selectedIds = [o.objId]
    selectionChanged()
    markDirty()
    return o.objId
  }

  function addText(text, type) {
    return createObject({
      type: type || "text",
      x: camX + 120, y: camY + 100,
      w: 220, h: 64,
      text: text || "",
    })
  }

  function addSticky(text, color) {
    return createObject({
      type: "sticky",
      x: camX + 260, y: camY + 220,
      w: 200, h: 200,
      text: text || "",
      color: color || "#f2c94c",
    })
  }

  function addImage(src, w, h) {
    return createObject({
      type: "image",
      x: camX + 400, y: camY + 160,
      w: w || 320, h: h || 240,
      src: src || "",
    })
  }

  function addShape(shape) {
    return createObject({
      type: "shape",
      shape: shape || "rect",
      x: camX + 620, y: camY + 300,
      w: (shape === "line" || shape === "arrow") ? 220 : 180,
      h: (shape === "line" || shape === "arrow") ? 40 : 120,
      color: "#888888",
    })
  }

  function deleteSelection() {
    if (selectedIds.length === 0) return false
    commit("delete")
    var set = {}
    for (var i = 0; i < selectedIds.length; i++) set[selectedIds[i]] = true
    var kept = []
    for (var j = 0; j < objects.length; j++)
      if (!set[objects[j].objId]) kept.push(objects[j])
    objects = kept
    editingId = ""
    selectedIds = []
    selectionChanged()
    markDirty()
    return true
  }

  function duplicateSelection() {
    if (selectedIds.length === 0) return []
    commit("duplicate")
    var set = {}
    for (var i = 0; i < selectedIds.length; i++) set[selectedIds[i]] = true
    var copies = []
    var baseZ = nextZ()
    for (var j = 0; j < objects.length; j++) {
      if (!set[objects[j].objId]) continue
      var c = itemFactory.createObject(null)
      if (!c) continue
      c.fromData(objects[j].toData())
      c.objId = "o" + (nextId++)
      c.x += 24
      c.y += 24
      c.z = baseZ + copies.length
      copies.push(c)
    }
    objects = objects.concat(copies)
    selectedIds = copies.map(function (c) { return c.objId })
    selectionChanged()
    markDirty()
    return selectedIds
  }

  // ---- mutations -----------------------------------------------------------
  // Geometry mutations change CanvasItem properties directly, which notify the
  // view. Structural mutations (add/remove) reassign `objects`.

  function moveSelection(dx, dy) {
    var moved = false
    for (var i = 0; i < objects.length; i++) {
      var o = objects[i]
      if (selectedIds.indexOf(o.objId) === -1 || o.locked) continue
      o.x += dx
      o.y += dy
      moved = true
    }
    return moved
  }

  function nudgeSelection(dx, dy) {
    commit("move")
    moveSelection(dx, dy)
    markDirty()
  }

  function setText(id, text) {
    var o = byId(id)
    if (!o) return false
    o.text = String(text == null ? "" : text)
    markDirty()
    return true
  }

  // Text objects size themselves from their content; the document keeps the
  // stored w/h in sync so alignment and persistence see the real box.
  function syncTextSize(id, w, h) {
    var o = byId(id)
    if (!o) return
    o.w = w
    o.h = h
  }

  function setColor(id, color) {
    var o = byId(id)
    if (!o) return false
    o.color = color
    markDirty()
    return true
  }

  function setStroke(id, color) {
    var o = byId(id)
    if (!o) return false
    o.stroke = color
    markDirty()
    return true
  }

  function setOpacity(id, opacity) {
    var o = byId(id)
    if (!o) return false
    o.opacity = Math.max(0, Math.min(1, Number(opacity)))
    markDirty()
    return true
  }

  function toggleVisibleSelection() {
    if (selectedIds.length === 0) return false
    var anyHidden = false
    for (var i = 0; i < selectedIds.length; i++) {
      var o = byId(selectedIds[i])
      if (o && o.visible === false) anyHidden = true
    }
    commit("visibility")
    for (var j = 0; j < objects.length; j++) {
      if (selectedIds.indexOf(objects[j].objId) !== -1) objects[j].visible = anyHidden
    }
    markDirty()
    return true
  }

  function toggleLockedSelection() {
    if (selectedIds.length === 0) return false
    var anyUnlocked = false
    for (var i = 0; i < selectedIds.length; i++) {
      var o = byId(selectedIds[i])
      if (o && !o.locked) anyUnlocked = true
    }
    commit("lock")
    for (var j = 0; j < objects.length; j++) {
      if (selectedIds.indexOf(objects[j].objId) !== -1) objects[j].locked = anyUnlocked
    }
    markDirty()
    return true
  }

  function reorderSelection(mode) {
    if (selectedIds.length === 0) return false
    commit("reorder")
    var set = {}
    for (var i = 0; i < selectedIds.length; i++) set[selectedIds[i]] = true
    var z = nextZ()
    if (mode === "front") {
      for (var j = 0; j < objects.length; j++) if (set[objects[j].objId]) objects[j].z = z++
    } else if (mode === "up") {
      var maxUnselected = 0
      for (var m = 0; m < objects.length; m++)
        if (!set[objects[m].objId] && objects[m].z > maxUnselected) maxUnselected = objects[m].z
      var n = 0
      for (var p = 0; p < objects.length; p++)
        if (set[objects[p].objId]) objects[p].z = maxUnselected + 1 + (n++)
    } else if (mode === "back") {
      var minZ = Infinity
      for (var q = 0; q < objects.length; q++) if (objects[q].z < minZ) minZ = objects[q].z
      var idx = 0
      for (var r = 0; r < objects.length; r++)
        if (set[objects[r].objId]) objects[r].z = minZ - selectedIds.length + (idx++)
    } else if (mode === "down") {
      var minUnselected = Infinity
      for (var s = 0; s < objects.length; s++)
        if (!set[objects[s].objId] && objects[s].z < minUnselected) minUnselected = objects[s].z
      var n2 = 0
      for (var t = 0; t < objects.length; t++)
        if (set[objects[t].objId]) objects[t].z = minUnselected - selectedIds.length + (n2++)
    }
    markDirty()
    return true
  }

  function alignSelection(mode) {
    if (selectedIds.length < 2) return false
    commit("align")
    var sel = []
    for (var i = 0; i < objects.length; i++)
      if (selectedIds.indexOf(objects[i].objId) !== -1) sel.push(objects[i])
    var bs = sel.map(worldBounds)
    var minX = Math.min.apply(null, bs.map(function (b) { return b.x }))
    var maxX = Math.max.apply(null, bs.map(function (b) { return b.x + b.w }))
    var minY = Math.min.apply(null, bs.map(function (b) { return b.y }))
    var maxY = Math.max.apply(null, bs.map(function (b) { return b.y + b.h }))
    var midX = (minX + maxX) / 2
    var midY = (minY + maxY) / 2
    for (var j = 0; j < sel.length; j++) {
      var o = sel[j]
      var b = worldBounds(o)
      var ox = o.x
      var oy = o.y
      if (mode === "left") ox += minX - b.x
      else if (mode === "centerH") ox += midX - (b.x + b.w / 2)
      else if (mode === "right") ox += maxX - (b.x + b.w)
      else if (mode === "top") oy += minY - b.y
      else if (mode === "centerV") oy += midY - (b.y + b.h / 2)
      else if (mode === "bottom") oy += maxY - (b.y + b.h)
      o.x = ox
      o.y = oy
    }
    markDirty()
    return true
  }

  function snapSelection() {
    if (selectedIds.length === 0) return false
    commit("snap")
    for (var i = 0; i < objects.length; i++) {
      var o = objects[i]
      if (selectedIds.indexOf(o.objId) === -1 || o.locked) continue
      var b = worldBounds(o)
      o.x = Math.round(b.x / gridSize) * gridSize + (o.x - b.x)
      o.y = Math.round(b.y / gridSize) * gridSize + (o.y - b.y)
    }
    markDirty()
    return true
  }

  function resizeCornerTo(id, corner, dx, dy) {
    var o = byId(id)
    if (!o || o.locked) return false
    var b = worldBounds(o)
    var anchorCorner = corner === "tl" ? "br" : corner === "tr" ? "bl"
      : corner === "bl" ? "tr" : "tl"
    var anchor = handlePos(o, anchorCorner)
    var target = {
      x: (corner === "tl" || corner === "bl") ? b.x + b.w : b.x,
      y: (corner === "tl" || corner === "tr") ? b.y + b.h : b.y,
    }
    var nx = target.x + dx
    var ny = target.y + dy
    var cx = b.x + b.w / 2
    var cy = b.y + b.h / 2
    var a = o.rot ? rotatePoint(anchor.x, anchor.y, cx, cy, -o.rot) : anchor
    var t = o.rot ? rotatePoint(nx, ny, cx, cy, -o.rot) : { x: nx, y: ny }
    var w = Math.abs(a.x - t.x)
    var h = Math.abs(a.y - t.y)
    if (w < 1 || h < 1) return false
    var lcx = (a.x + t.x) / 2
    var lcy = (a.y + t.y) / 2
    var wc = o.rot ? rotatePoint(lcx, lcy, cx, cy, o.rot) : { x: lcx, y: lcy }
    o.x = wc.x - w / 2
    o.y = wc.y - h / 2
    o.w = Math.max(8, w)
    o.h = Math.max(8, h)
    return true
  }

  function rotateBy(id, deltaDeg) {
    var o = byId(id)
    if (!o || o.locked) return false
    o.rot = (o.rot + deltaDeg)
    return true
  }

  // ---- camera --------------------------------------------------------------

  function pan(dx, dy) {
    camX -= dx / zoom
    camY -= dy / zoom
    changed()
  }

  function zoomAt(vx, vy, factor) {
    var before = toWorld(vx, vy)
    zoom = Math.max(0.1, Math.min(4, zoom * factor))
    var after = toWorld(vx, vy)
    camX += before.x - after.x
    camY += before.y - after.y
    changed()
  }

  function setZoom(value) {
    zoom = Math.max(0.1, Math.min(4, Number(value) || 1))
    changed()
  }

  // Viewport size, set by the panel once the canvas surface is laid out.
  property real viewW: 1280
  property real viewH: 720

  function zoomToFit(pad) {
    if (objects.length === 0) return
    var b = boundsOf(objects.map(function (o) { return o.objId }))
    var w = b.w + pad * 2
    var h = b.h + pad * 2
    zoom = Math.max(0.1, Math.min(4, Math.min(viewW / w, viewH / h)))
    camX = b.x - (viewW / zoom - b.w) / 2
    camY = b.y - (viewH / zoom - b.h) / 2
    changed()
  }

  function centerOn(id) {
    var o = byId(id)
    if (!o) return
    var b = worldBounds(o)
    camX = b.x + b.w / 2 - viewW / zoom / 2
    camY = b.y + b.h / 2 - viewH / zoom / 2
    changed()
  }

  // ---- serialization -------------------------------------------------------

  function serialize() {
    var objs = []
    for (var i = 0; i < objects.length; i++) objs.push(objects[i].toData())
    return JSON.stringify({
      version: 1,
      docId: docId,
      title: title,
      nextId: nextId,
      gridSize: gridSize,
      showGrid: showGrid,
      camX: camX, camY: camY, zoom: zoom,
      objects: objs,
    })
  }

  function loadJson(text) {
    var data
    try { data = JSON.parse(text) } catch (e) { return false }
    if (!data || !Array.isArray(data.objects)) return false

    applyDataObjects(data.objects)
    nextId = Number(data.nextId) || (objects.length + 1)
    docId = String(data.docId || docId)
    title = String(data.title || title)
    gridSize = Number(data.gridSize) || 20
    showGrid = data.showGrid !== false
    camX = Number(data.camX) || 0
    camY = Number(data.camY) || 0
    zoom = Number(data.zoom) || 1
    selectedIds = []
    editingId = ""
    undoStack = []
    redoStack = []
    dirty = false
    selectionChanged()
    changed()
    loaded()
    return true
  }

  function clearDocument() {
    commit("clear")
    objects = []
    selectedIds = []
    editingId = ""
    markDirty()
  }

  // ---- persistence ---------------------------------------------------------

  function save() {
    if (!storage || !docPath) return false
    storage.path = docPath
    storage.setText(serialize())
    dirty = false
    saved()
    return true
  }

  function load() {
    if (!storage || !docPath) return false
    var text = storage.text() || ""
    if (!text.trim()) return false
    return loadJson(text)
  }

  function markSaved() {
    dirty = false
  }
}
