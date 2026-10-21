import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "lib" as Lib

// Canvas — infinite visual canvas for Omarchy.
//
// Host lifecycle: omarchy-shell loads this as a `panel` plugin, injects
// `shell`, `manifest` and `omarchyPath`, and drives it with
//   omarchy-shell shell summon io.github.hermes.canvas '{"doc":"<id>"}'
//   omarchy-shell shell hide   io.github.hermes.canvas
// The window is a FloatingWindow (a real Hyprland client), so it behaves like
// a normal app: movable, resizable, minimizable, and it takes focus on summon.

Item {
  id: root

  // ---- host injections ----------------------------------------------------
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false

  // ---- projects ----------------------------------------------------------
  // Multiple independent canvases, one per project id. Each gets its own
  // document and its own file on disk.
  property string activeDoc: "default"
  property var projects: (["default"])
  property string projectName: "Untitled canvas"

  // ---- tool state --------------------------------------------------------
  property string tool: "select"   // select | pan | text | sticky | rect | ellipse | line | arrow
  property bool editingText: false
  property string editingId: ""
  property bool spaceHeld: false

  readonly property string fontFamily: Style.font.family

  // ---- document ----------------------------------------------------------
  // Declared as a property (not just an id) so the Repeater delegate can reach
  // it as `doc` — a bare QML id is not a property of its parent, and the
  // delegate's scope does not reliably resolve sibling ids.
  property var doc: Lib.CanvasDoc {
    dataDir: Quickshell.env("HOME") + "/.local/state/omarchy/canvas"
    docPath: dataDir + "/" + activeDoc + ".json"

    storage: FileView {
      id: fileView
      path: doc.docPath
      watchChanges: false
      printErrors: false
      atomicWrites: true
    }

    onLoaded: root.onDocumentLoaded()
    onSaved: root.onDocumentSaved()
    onSelectionChanged: root.refreshStatusBar()
    onChanged: root.refreshStatusBar()
  }

  // ---- window ------------------------------------------------------------
  // The window is created once and kept mounted (keepLoaded), so the document
  // survives between summons.

  FloatingWindow {
    id: window
    title: "Canvas — " + root.projectName
    visible: root.opened
    color: doc.canvasBg

    implicitWidth: 1180
    implicitHeight: 760
    minimumSize: Qt.size(640, 420)

    onVisibleChanged: {
      if (!visible && root.opened && root.shell && typeof root.shell.hide === "function") {
        root.shell.hide("io.github.hermes.canvas")
      }
    }

    // ---- focus + keys ---------------------------------------------------
    Item {
      id: keyHost
      anchors.fill: parent
      focus: root.opened

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.modifiers & Qt.ControlModifier || event.modifiers & Qt.MetaModifier) {
          handleCtrlKey(event)
          return
        }
        if (event.modifiers & Qt.ShiftModifier) {
          if (event.key === Qt.Key_Greater) { root.zoomStep(1.25); event.accepted = true; return }
          if (event.key === Qt.Key_Less) { root.zoomStep(0.8); event.accepted = true; return }
        }
        switch (event.key) {
          case Qt.Key_Escape:
            if (root.editingText) { root.endTextEdit(); event.accepted = true; return }
            if (doc.selectedIds.length > 0) { doc.clearSelection(); event.accepted = true; return }
            root.requestClose()
            event.accepted = true
            return
          case Qt.Key_Space:
            if (!root.editingText) { root.spaceHeld = true; event.accepted = true; return }
            break
          case Qt.Key_Delete:
          case Qt.Key_Backspace:
            if (!root.editingText) { root.deleteSelection(); event.accepted = true; return }
            break
          case Qt.Key_A:
            if (!root.editingText) { doc.selectAll(); event.accepted = true; return }
            break
          case Qt.Key_Z:
            if (!root.editingText) { root.undo(); event.accepted = true; return }
            break
          case Qt.Key_Y:
            if (!root.editingText) { root.redo(); event.accepted = true; return }
            break
          case Qt.Key_Plus:
          case Qt.Key_Equal:
            root.zoomStep(1.25); event.accepted = true; return
          case Qt.Key_Minus:
            root.zoomStep(0.8); event.accepted = true; return
          case Qt.Key_0:
            doc.setZoom(1); event.accepted = true; return
          case Qt.Key_1:
            root.zoomToFit(); event.accepted = true; return
          case Qt.Key_F:
            root.zoomToFit(); event.accepted = true; return
          case Qt.Key_G:
            doc.showGrid = !doc.showGrid; event.accepted = true; return
          case Qt.Key_V:
            if (!root.editingText) { root.tool = "select"; event.accepted = true; return }
            break
          case Qt.Key_T:
            if (!root.editingText) { root.tool = "text"; event.accepted = true; return }
            break
          case Qt.Key_S:
            if (!root.editingText) { root.tool = "sticky"; event.accepted = true; return }
            break
          case Qt.Key_R:
            if (!root.editingText) { root.tool = "rect"; event.accepted = true; return }
            break
          case Qt.Key_E:
            if (!root.editingText) { root.tool = "ellipse"; event.accepted = true; return }
            break
          case Qt.Key_L:
            if (!root.editingText) { root.tool = "line"; event.accepted = true; return }
            break
          case Qt.Key_Up: root.nudge(0, -gridStep()); event.accepted = true; return
          case Qt.Key_Down: root.nudge(0, gridStep()); event.accepted = true; return
          case Qt.Key_Left: root.nudge(-gridStep(), 0); event.accepted = true; return
          case Qt.Key_Right: root.nudge(gridStep(), 0); event.accepted = true; return
        }
      }

      Keys.onReleased: function(event) {
        if (event.key === Qt.Key_Space) { root.spaceHeld = false; event.accepted = true }
      }
    }

    // ---- toolbar ---------------------------------------------------------
    BorderSurface {
      id: toolbar
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(44)
      color: Util.alpha(Color.background, 0.92)
      borderSpec: Border.flat(Util.alpha(Color.foreground, 0.10), 1)
      radius: 0
      z: 100

      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Button {
          iconText: "󰋺"
          tooltipText: "Select (V)"
          hasCursor: root.tool === "select"
          active: root.tool === "select"
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.tool = "select"
        }
        Button {
          iconText: "󰹻"
          tooltipText: "Pan (hold Space)"
          active: root.tool === "pan"
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.tool = root.tool === "pan" ? "select" : "pan"
        }
        Button {
          iconText: "󰚢"
          tooltipText: "Text (T)"
          active: root.tool === "text"
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.tool = "text"
        }
        Button {
          iconText: "󰉷"
          tooltipText: "Sticky note (S)"
          active: root.tool === "sticky"
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.tool = "sticky"
        }
        Button {
          iconText: "󰛉"
          tooltipText: "Rectangle (R)"
          active: root.tool === "rect"
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.tool = "rect"
        }
        Button {
          iconText: "󰕸"
          tooltipText: "Ellipse (E)"
          active: root.tool === "ellipse"
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.tool = "ellipse"
        }
        Button {
          iconText: "󰏫"
          tooltipText: "Line (L)"
          active: root.tool === "line"
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.tool = "line"
        }
        Button {
          iconText: "󰁛"
          tooltipText: "Arrow (Shift+L)"
          active: root.tool === "arrow"
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.tool = "arrow"
        }
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(4)

        Button {
          iconText: "󰀉"
          tooltipText: "Add image…"
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.pickImage()
        }
        Button {
          iconText: "󰃰"
          tooltipText: "Undo (Ctrl+Z)"
          enabled: root.canUndoState
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.undo()
        }
        Button {
          iconText: "󰃲"
          tooltipText: "Redo (Ctrl+Y)"
          enabled: root.canRedoState
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.redo()
        }
        Button {
          iconText: "󰛑"
          tooltipText: "Zoom to fit (F)"
          foreground: Color.foreground
          fontFamily: root.fontFamily
          onClicked: root.zoomToFit()
        }
      }
    }

    // ---- canvas surface --------------------------------------------------
    Item {
      id: canvasSurface
      anchors.top: toolbar.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: statusBar.top
      clip: true

      // Grid. Drawn as dots rather than lines so it reads as a drafting grid
      // and never competes with the objects on top of it.
      Canvas {
        id: gridCanvas
        anchors.fill: parent
        visible: doc.showGrid
        onPaint: canvasSurface.drawGrid()
      }

      // Defined on the surface so the Canvas above can call it; the surface
      // owns the camera, so the grid scrolls and scales with the canvas.
      function drawGrid() {
        var ctx = gridCanvas.getContext("2d")
        var w = gridCanvas.width
        var h = gridCanvas.height
        ctx.clearRect(0, 0, w, h)

        var step = doc.gridSize * doc.zoom
        if (step < 4) return

        // Align the dot lattice to canvas space so it stays put when panning.
        var offsetX = (-doc.camX * doc.zoom) % step
        var offsetY = (-doc.camY * doc.zoom) % step
        if (offsetX < 0) offsetX += step
        if (offsetY < 0) offsetY += step

        var dot = Math.max(1, Math.min(2, 1.2 * doc.zoom))
        ctx.fillStyle = Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.16)

        for (var x = offsetX; x < w; x += step) {
          for (var y = offsetY; y < h; y += step) {
            ctx.beginPath()
            ctx.arc(x, y, dot, 0, Math.PI * 2)
            ctx.fill()
          }
        }
      }

      // Repaint whenever the camera or grid settings change.
      function scheduleGridRepaint() {
        if (gridCanvas) gridCanvas.requestPaint()
      }

      // Objects. The model is the array itself (not its length): an integer
      // model only exposes `index` to the delegate, whereas an array model
      // also supplies `modelData`, which is what the delegate needs.
      Repeater {
        id: objectRepeater
        model: doc.objects

        delegate: Lib.CanvasObject {
          required property var modelData
          required property int index

          doc: doc
          obj: modelData
          zoom: doc.zoom
          selected: doc.selectedIds.indexOf(modelData.objId) !== -1
          editingText: root.editingId === modelData.objId
          fontFamily: root.fontFamily
          canvasBg: doc.canvasBg

          onPressed: function(vx, vy, additive) { root.beginObjectDrag(modelData, additive) }
          onDragGesture: function(dx, dy) { root.objectDragBy(dx, dy) }
          onReleased: root.endDrag()
          onEditRequested: root.beginTextEdit(modelData.objId)
          onHandlePressed: function(corner, vx, vy) { root.beginCornerDrag(modelData, corner, vx, vy) }
          onRotateRequested: root.beginRotateDrag(modelData)
        }
      }

      // Selection marquee
      Rectangle {
        id: marquee
        visible: root.dragState && root.dragState.kind === "marquee"
        color: Util.alpha(Color.accent, 0.12)
        border.width: 1
        border.color: Util.alpha(Color.accent, 0.7)
      }

      // ---- surface pointer ------------------------------------------------
      MouseArea {
        id: surfaceMouse
        anchors.fill: parent
        hoverEnabled: true
        preventStealing: false

        onPressed: function(mouse) {
          if (mouse.button !== Qt.LeftButton) return
          var world = doc.toWorld(mouse.x, mouse.y)
          root.surfacePressed(world.x, world.y, mouse.x, mouse.y,
            (mouse.modifiers & Qt.ShiftModifier) || (mouse.modifiers & Qt.ControlModifier))
        }
        onPositionChanged: function(mouse) {
          root.surfaceMoved(mouse.x, mouse.y)
        }
        onReleased: function() {
          root.surfaceReleased()
        }
        onWheel: function(wheel) {
          if (wheel.modifiers & Qt.ControlModifier || wheel.modifiers & Qt.MetaModifier) {
            root.zoomAt(wheel.x, wheel.y, wheel.angleDelta.y > 0 ? 1.1 : 1 / 1.1)
          } else {
            root.panBy(-wheel.angleDelta.x, -wheel.angleDelta.y)
          }
          wheel.accepted = true
        }
      }

      // Drop target for files dragged in from a file manager
      DropArea {
        id: dropArea
        anchors.fill: parent
        onDropped: function(drop) {
          var urls = drop.urls || []
          if (urls.length === 0) return
          root.importUrls(urls, drop.x, drop.y)
        }
      }
    }

    // ---- status bar ------------------------------------------------------
    BorderSurface {
      id: statusBar
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.space(30)
      color: Util.alpha(Color.background, 0.92)
      borderSpec: Border.flat(Util.alpha(Color.foreground, 0.10), 1)
      radius: 0
      z: 100

      Row {
        anchors.left: parent.left
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(14)

        Text {
          text: "Zoom " + Math.round(root.zoomPercent) + "%"
          color: Color.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          text: root.objectCount + " objects"
          color: Color.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          text: root.selectionCount > 0 ? root.selectionCount + " selected" : ""
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          text: root.dirty ? "● unsaved" : "saved"
          color: root.dirty ? Color.urgent : Color.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Row {
        anchors.right: parent.right
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.center
        spacing: Style.space(14)

        Text {
          text: "Space pan · wheel pan · Ctrl+wheel zoom · drag files in"
          color: Qt.darker(Color.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // Drag state for the current gesture. Kept outside `doc` so an in-progress
  // drag is not part of the undo snapshot or the saved document.
  property var dragState: null

  function gridStep() {
    return doc.gridSize
  }

  // ---- surface interaction ------------------------------------------------

  function surfacePressed(wx, wy, vx, vy, additive) {
    doc.viewW = canvasSurface.width
    doc.viewH = canvasSurface.height

    if (root.spaceHeld || root.tool === "pan") {
      dragState = { kind: "pan", lastX: vx, lastY: vy }
      doc.panning = true
      return
    }

    if (root.tool === "select") {
      var hit = doc.topMostAt({ x: wx, y: wy })
      if (hit) {
        if (additive) doc.toggleSelect(hit.id)
        else if (doc.selectedIds.indexOf(hit.id) === -1) doc.select([hit.id])
        dragState = {
          kind: "move",
          ids: doc.selectedIds.slice(),
          lastX: vx, lastY: vy,
          committed: false,
        }
      } else {
        if (!additive) doc.clearSelection()
        dragState = {
          kind: "marquee",
          startX: vx, startY: vy, lastX: vx, lastY: vy,
          additive: additive,
          baseIds: additive ? doc.selectedIds.slice() : [],
        }
      }
      return
    }

    // Creation tools
    //
    // A creation tool stays active (Miro-like, so you can drop several notes),
    // but a click that lands on an existing object of the same type does not
    // stack another one on top of it — that is what produced a pile of
    // identical shapes when the tool was left selected.
    var created = null
    var toolType = root.tool === "text" ? "text"
      : root.tool === "sticky" ? "sticky"
      : root.tool === "rect" || root.tool === "ellipse" ? "shape"
      : root.tool === "line" || root.tool === "arrow" ? "shape" : ""

    if (toolType) {
      for (var i = 0; i < doc.objects.length; i++) {
        var existing = doc.objects[i]
        if (existing.type !== toolType) continue
        if (existing.type === "shape" && existing.shape !== root.tool) continue
        if (doc.hitTest(existing, { x: wx, y: wy })) {
          // Clicked an object we would just duplicate: select it instead.
          doc.select([existing.objId])
          dragState = { kind: "move", ids: [existing.objId], lastX: vx, lastY: vy, committed: false }
          return
        }
      }
    }

    if (root.tool === "text") created = doc.addText("", "text")
    else if (root.tool === "sticky") created = doc.addSticky("", root.stickyColor())
    else if (root.tool === "rect") created = doc.addShape("rect")
    else if (root.tool === "ellipse") created = doc.addShape("ellipse")
    else if (root.tool === "line") created = doc.addShape("line")
    else if (root.tool === "arrow") created = doc.addShape("arrow")

    if (created) {
      var o = doc.byId(created)
      // Re-center the fresh object on the click point.
      if (o) {
        doc.commit("place")
        o.x = wx - o.w / 2
        o.y = wy - o.h / 2
        doc.markDirty()
      }
      if (root.tool === "text" || root.tool === "sticky") {
        root.beginTextEdit(created)
      } else {
        dragState = { kind: "move", ids: [created], lastX: vx, lastY: vy, committed: false }
      }
    }
  }

  function surfaceMoved(vx, vy) {
    if (!dragState) return
    if (dragState.kind === "pan") {
      doc.pan(vx - dragState.lastX, vy - dragState.lastY)
      dragState.lastX = vx
      dragState.lastY = vy
      return
    }
    if (dragState.kind === "marquee") {
      dragState.lastX = vx
      dragState.lastY = vy
      updateMarquee()
      return
    }
    if (dragState.kind === "move") {
      var dx = (vx - dragState.lastX) / doc.zoom
      var dy = (vy - dragState.lastY) / doc.zoom
      if (!dragState.committed && (Math.abs(vx - dragState.lastX) > 1 || Math.abs(vy - dragState.lastY) > 1)) {
        doc.commit("move")
        dragState.committed = true
      }
      doc.moveSelection(dx, dy)
      dragState.lastX = vx
      dragState.lastY = vy
    }
  }

  function surfaceReleased() {
    if (dragState && dragState.kind === "marquee") finishMarquee()
    dragState = null
    doc.panning = false
    scheduleSave()
  }

  function updateMarquee() {
    var x = Math.min(dragState.startX, dragState.lastX)
    var y = Math.min(dragState.startY, dragState.lastY)
    var w = Math.abs(dragState.lastX - dragState.startX)
    var h = Math.abs(dragState.lastY - dragState.startY)
    marquee.x = x
    marquee.y = y
    marquee.width = Math.max(1, w)
    marquee.height = Math.max(1, h)
  }

  function finishMarquee() {
    var x0 = Math.min(dragState.startX, dragState.lastX)
    var x1 = Math.max(dragState.startX, dragState.lastX)
    var y0 = Math.min(dragState.startY, dragState.lastY)
    var y1 = Math.max(dragState.startY, dragState.lastY)
    var w0 = doc.toWorld(x0, y0)
    var w1 = doc.toWorld(x1, y1)
    var ids = dragState.baseIds.slice()
    for (var i = 0; i < doc.objects.length; i++) {
      var o = doc.objects[i]
      if (o.visible === false) continue
      var b = doc.worldBounds(o)
      var overlaps = !(b.x + b.w < w0.x || b.x > w1.x || b.y + b.h < w0.y || b.y > w1.y)
      if (overlaps && ids.indexOf(o.id) === -1) ids.push(o.id)
    }
    doc.select(ids)
    marquee.visible = false
  }

  // ---- object dragging ----------------------------------------------------

  function beginObjectDrag(obj, additive) {
    if (!additive && doc.selectedIds.indexOf(obj.objId) === -1) doc.select([obj.objId])
    doc.viewW = canvasSurface.width
    doc.viewH = canvasSurface.height
    dragState = {
      kind: "move",
      ids: doc.selectedIds.slice(),
      lastX: obj.x,
      lastY: obj.y,
      committed: false,
      pointerId: obj.objId,
    }
  }

  function objectDragBy(dx, dy) {
    if (!dragState || dragState.kind !== "move") return
    var cdx = dx / doc.zoom
    var cdy = dy / doc.zoom
    if (!dragState.committed) {
      doc.commit("move")
      dragState.committed = true
    }
    doc.moveSelection(cdx, cdy)
  }

  function beginCornerDrag(obj, corner, vx, vy) {
    doc.beginResize(obj.objId, corner)
    dragState = {
      kind: "resize",
      id: obj.objId,
      corner: corner,
      lastX: vx,
      lastY: vy,
    }
  }

  function beginRotateDrag(obj) {
    doc.beginRotate(obj.objId)
    dragState = { kind: "rotate", id: obj.objId }
  }

  function endDrag() {
    dragState = null
    scheduleSave()
  }

  // ---- text editing -------------------------------------------------------

  function beginTextEdit(id) {
    root.editingId = id
    root.editingText = true
    scheduleSave()
  }

  function endTextEdit() {
    root.editingId = ""
    root.editingText = false
    scheduleSave()
  }

  // ---- commands -----------------------------------------------------------

  function deleteSelection() {
    if (doc.deleteSelection()) scheduleSave()
  }

  function undo() {
    doc.undo()
    scheduleSave()
  }

  function redo() {
    doc.redo()
    scheduleSave()
  }

  function nudge(dx, dy) {
    doc.nudgeSelection(dx, dy)
    scheduleSave()
  }

  function zoomStep(factor) {
    doc.zoomAt(canvasSurface.width / 2, canvasSurface.height / 2, factor)
  }

  function zoomAt(vx, vy, factor) {
    doc.zoomAt(vx, vy, factor)
  }

  function panBy(dx, dy) {
    doc.pan(dx, dy)
  }

  function zoomToFit() {
    doc.zoomToFit(120)
  }

  function handleCtrlKey(event) {
    if (event.key === Qt.Key_Z) {
      if (event.modifiers & Qt.ShiftModifier) root.redo()
      else root.undo()
      event.accepted = true
    } else if (event.key === Qt.Key_Y) {
      root.redo()
      event.accepted = true
    } else if (event.key === Qt.Key_A) {
      doc.selectAll()
      event.accepted = true
    } else if (event.key === Qt.Key_D) {
      doc.duplicateSelection()
      scheduleSave()
      event.accepted = true
    } else if (event.key === Qt.Key_C) {
      copySelection()
      event.accepted = true
    } else if (event.key === Qt.Key_X) {
      copySelection()
      root.deleteSelection()
      event.accepted = true
    } else if (event.key === Qt.Key_V) {
      pasteSelection()
      event.accepted = true
    } else if (event.key === Qt.Key_S) {
      root.saveNow()
      event.accepted = true
    } else if (event.key === Qt.Key_F) {
      root.zoomToFit()
      event.accepted = true
    } else if (event.key === Qt.Key_Equal || event.key === Qt.Key_Plus) {
      root.zoomStep(1.25)
      event.accepted = true
    } else if (event.key === Qt.Key_Minus) {
      root.zoomStep(0.8)
      event.accepted = true
    } else if (event.key === Qt.Key_0) {
      doc.setZoom(1)
      event.accepted = true
    } else if (event.key === Qt.Key_G) {
      doc.showGrid = !doc.showGrid
      event.accepted = true
    } else if (event.key === Qt.Key_I) {
      root.pickImage()
      event.accepted = true
    }
  }

  function copySelection() {
    if (doc.selectedIds.length === 0) return
    clipboardJson = JSON.stringify(doc.selectedIds.map(function (id) {
      var o = doc.byId(id)
      return o ? doc.cloneObject(o) : null
    }).filter(function (o) { return o !== null }))
    refreshStatusBar()
  }

  property string clipboardJson: ""

  function pasteSelection() {
    if (!clipboardJson) return
    var arr
    try { arr = JSON.parse(clipboardJson) } catch (e) { return }
    if (!Array.isArray(arr) || arr.length === 0) return
    doc.commit("paste")
    var ids = []
    var maxZ = doc.nextZ()
    for (var i = 0; i < arr.length; i++) {
      var c = doc.cloneObject(arr[i])
      c.id = "o" + (doc.nextId++)
      c.x += 40
      c.y += 40
      c.z = maxZ + i
      doc.objects.push(c)
      ids.push(c.id)
    }
    doc.selectedIds = ids
    doc.selectionChanged()
    doc.markDirty()
    scheduleSave()
  }

  // ---- images -------------------------------------------------------------

  function pickImage() {
    imageProc.running = true
  }

  function importUrls(urls, vx, vy) {
    var first = urls[0]
    if (!first) return
    var isImage = /\.(png|jpe?g|gif|webp|bmp|svg|avif|tiff?)$/i.test(first)
    var wx = vx === undefined ? doc.camX + 200 : doc.toWorld(vx, vy).x
    var wy = vy === undefined ? doc.camY + 150 : doc.toWorld(vx, vy).y
    if (isImage) {
      var id = doc.addImage(first)
      var o = doc.byId(id)
      if (o) { o.x = wx - o.w / 2; o.y = wy - o.h / 2 }
    } else {
      var id2 = doc.addSticky(first.split("/").pop(), "#e8e8e8")
      var o2 = doc.byId(id2)
      if (o2) { o2.x = wx - o2.w / 2; o2.y = wy - o2.h / 2 }
    }
    scheduleSave()
  }

  Process {
    id: imageProc
    command: ["omarchy-file-select", "--title", "Add image to canvas", "--multiple", "--extensions", "png jpg jpeg gif webp bmp svg avif tiff"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n").filter(function (l) { return l.trim() !== "" })
        if (lines.length === 0) return
        root.importUrls(lines, undefined, undefined)
      }
    }
    onExited: function(code) {
      // 1 == nothing picked, which is a decision, not an error.
    }
  }

  // ---- persistence --------------------------------------------------------

  property var saveTimer: Timer {
    interval: 800
    repeat: false
    onTriggered: root.saveNow()
  }

  function scheduleSave() {
    if (!saveTimer) return
    saveTimer.restart()
  }

  function saveNow() {
    doc.save()
  }

  function onDocumentSaved() {
    refreshStatusBar()
  }

  function onDocumentLoaded() {
    refreshStatusBar()
  }

  // Exposed so the status bar can bind to it; recomputed whenever the document
  // reports a change or a save lands.
  property bool dirty: doc.dirty
  property bool canUndoState: doc.canUndo
  property bool canRedoState: doc.canRedo
  property int objectCount: doc.objects.length
  property int selectionCount: doc.selectedIds.length
  property real zoomPercent: doc.zoom * 100

  function refreshStatusBar() {
    dirty = doc.dirty
    canUndoState = doc.canUndo
    canRedoState = doc.canRedo
    objectCount = doc.objects.length
    selectionCount = doc.selectedIds.length
    zoomPercent = doc.zoom * 100
  }

  // ---- project switching --------------------------------------------------

  function switchProject(id) {
    if (id === activeDoc) return
    root.saveNow()
    activeDoc = String(id)
    doc.docId = activeDoc
    doc.docPath = doc.dataDir + "/" + activeDoc + ".json"
    fileView.path = doc.docPath
    doc.load()
    root.projectName = projectNameFor(id)
    window.title = "Canvas — " + root.projectName
    refreshStatusBar()
  }

  function projectNameFor(id) {
    if (id === "default") return "Untitled canvas"
    return id.replace(/[-_]+/g, " ").replace(/\b\w/g, function (c) { return c.toUpperCase() })
  }

  function newProject() {
    var id = "project-" + Date.now()
    root.projects.push(id)
    root.switchProject(id)
  }

  // ---- lifecycle ----------------------------------------------------------

  function open(payloadJson) {
    var payload = {}
    try { payload = JSON.parse(payloadJson || "{}") || {} } catch (e) {}

    root.opened = true
    window.visible = true

    doc.viewW = canvasSurface.width || 1280
    doc.viewH = canvasSurface.height || 720

    if (payload.doc) {
      root.switchProject(String(payload.doc))
    } else if (!doc.ready) {
      doc.ready = true
      if (!doc.load()) {
        // Fresh canvas: seed a few orientation notes, then persist them so
        // the document exists on disk from the first run.
        doc.commit("seed")
        doc.addText("Double-click to edit", "title")
        doc.addSticky("Drag, drop, resize, rotate.\nEverything autosaves.", "#f2c94c")
        doc.addShape("rect")
        doc.undoStack = []
        doc.redoStack = []
        doc.markDirty()
        root.saveNow()
      }
    }

    Qt.callLater(function() {
      keyHost.forceActiveFocus()
      canvasSurface.width > 0 && (doc.viewW = canvasSurface.width)
      canvasSurface.height > 0 && (doc.viewH = canvasSurface.height)
    })
  }

  function close() {
    root.opened = false
    window.visible = false
  }

  function requestClose() {
    root.saveNow()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide("io.github.hermes.canvas")
    else
      window.visible = false
  }

  function stickyColor() {
    var palette = ["#f2c94c", "#f2994a", "#eb5757", "#2d9cdb", "#6fcf97", "#bb6bd9"]
    return palette[Math.floor(Math.random() * palette.length)]
  }

  Component.onCompleted: {
    doc.dataDir = Quickshell.env("HOME") + "/.local/state/omarchy/canvas"
  }
}
