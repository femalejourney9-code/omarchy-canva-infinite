import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// One object on the canvas. Sizes itself from its content (sticky / text /
// title / heading), draws its own body, and reports pointer gestures to the
// canvas document. The document owns selection, camera, undo and saves.
//
// All coordinates the document deals in are canvas units; this item applies
// the camera (pan + zoom) itself, so dragging an object never moves the
// document under it.
Item {
  id: root

  required property var doc
  required property var obj
  required property real zoom
  required property bool selected
  required property bool editingText
  required property string fontFamily
  required property color canvasBg

  visible: obj.visible !== false
  opacity: obj.opacity === undefined ? 1 : obj.opacity
  x: (obj.x - doc.camera.x) * zoom
  y: (obj.y - doc.camera.y) * zoom
  z: obj.z

  readonly property bool interactive: !obj.locked && !doc.panning
  readonly property bool isText: obj.type === "text" || obj.type === "sticky"
    || obj.type === "title" || obj.type === "heading"
  readonly property bool isShape: obj.type === "shape"
  readonly property bool isImage: obj.type === "image"
  readonly property real pad: Style.space(10)

  readonly property real fontSize: {
    if (obj.type === "title") return Style.font.display
    if (obj.type === "heading") return Style.font.heading
    if (obj.type === "sticky") return Style.font.subtitle
    return Style.font.body
  }

  readonly property bool aspectLocked: isImage

  // ---- self-sizing --------------------------------------------------------
  // Text objects measure their own content so a sticky note hugs its words and
  // a title stays a single line until the user wraps it. Explicit resizes are
  // honored: once the user has dragged a handle, `userSized` stops the item
  // from re-measuring and shrink-wrapping back.
  property bool userSized: isImage || isShape

  TextMetrics {
    id: textMetrics
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
    font.bold: obj.type === "title" || obj.type === "heading"
    text: obj.text || ""
  }

  readonly property real measuredW: Math.ceil(textMetrics.advanceWidth) + root.pad * 2
  readonly property real measuredH: Math.ceil(textMetrics.height) + root.pad * 2

  width: userSized ? obj.w : Math.max(24, measuredW)
  height: userSized ? obj.h : Math.max(24, measuredH)

  onMeasuredWChanged: if (!userSized) doc.syncTextSize(obj.objId, width, height)
  onMeasuredHChanged: if (!userSized) doc.syncTextSize(obj.objId, width, height)

  // ---- signals ------------------------------------------------------------

  signal pressed(real vx, real vy, bool additive)
  signal dragGesture(real dx, real dy)
  signal released()
  signal editRequested()
  signal handlePressed(string corner, real vx, real vy)
  signal rotateRequested()

  // ---- body ---------------------------------------------------------------

  BorderSurface {
    id: body
    anchors.fill: parent
    radius: root.obj.type === "sticky" ? 4 : Style.cornerRadius
    visible: !root.isImage
    color: bodyColor()
    borderSpec: bodyBorder

    function bodyColor() {
      if (root.obj.type === "sticky") return root.obj.color || "#f2c94c"
      if (root.obj.type === "title" || root.obj.type === "heading")
        return Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.0)
      return Util.alpha(Qt.color(root.obj.color || "#888888"), 0.16)
    }
    readonly property var bodyBorder: {
      if (root.obj.type === "shape" && root.obj.stroke) {
        var c = Qt.color(root.obj.stroke)
        return Border.flat(Qt.rgba(c.r, c.g, c.b, 0.9), 1)
      }
      if (root.obj.type === "sticky" || root.obj.type === "title") return Border.none()
      return Border.flat(Util.alpha(Color.foreground, 0.20), 1)
    }

    Text {
      id: label
      visible: root.isText && !root.editingText
      anchors.fill: parent
      anchors.margins: root.pad
      text: root.obj.text
      color: root.obj.type === "sticky" ? Qt.rgba(0, 0, 0, 0.85) : Color.foreground
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
      font.bold: root.obj.type === "title" || root.obj.type === "heading"
      wrapMode: Text.Wrap
      verticalAlignment: Text.AlignVCenter
    }

    TextField {
      id: editor
      visible: root.editingText
      anchors.fill: parent
      anchors.margins: root.pad
      text: root.obj.text || ""
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
      font.bold: root.obj.type === "title" || root.obj.type === "heading"
      wrapMode: Text.Wrap
      color: root.obj.type === "sticky" ? Qt.rgba(0, 0, 0, 0.85) : Color.foreground
      background: BorderSurface {
        color: Util.alpha(Color.background, 0.5)
        borderSpec: Border.controlSpec("focus", Color.foreground, Color.accent)
        radius: Style.cornerRadius
      }
      onTextChanged: if (root.editingText) root.doc.setText(root.obj.objId, text)
      onAccepted: root.doc.endTextEdit()
      Keys.onEscapePressed: root.doc.endTextEdit()
      onVisibleChanged: if (visible) Qt.callLater(forceActiveFocus)
    }
  }

  Rectangle {
    id: rectShape
    anchors.fill: parent
    visible: root.isShape && (!root.obj.shape || root.obj.shape === "rect")
    radius: Math.min(root.obj.w, root.obj.h) * 0.12
    color: Util.alpha(Qt.color(root.obj.color || "#888888"), 0.16)
    border.width: 1
    border.color: root.obj.stroke
      ? Util.alpha(Qt.color(root.obj.stroke), 0.9)
      : Util.alpha(Color.foreground, 0.3)
  }

  Rectangle {
    id: ellipseShape
    anchors.fill: parent
    visible: root.isShape && root.obj.shape === "ellipse"
    radius: Math.min(root.obj.w, root.obj.h)
    color: Util.alpha(Qt.color(root.obj.color || "#888888"), 0.16)
    border.width: 1
    border.color: root.obj.stroke
      ? Util.alpha(Qt.color(root.obj.stroke), 0.9)
      : Util.alpha(Color.foreground, 0.3)
  }

  Rectangle {
    id: lineShape
    visible: root.isShape && (root.obj.shape === "line" || root.obj.shape === "arrow")
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    height: Math.max(2, 3 / root.zoom)
    color: root.obj.stroke ? Qt.color(root.obj.stroke) : Color.foreground
  }

  Canvas {
    id: arrowHead
    visible: root.isShape && root.obj.shape === "arrow"
    width: root.obj.w
    height: root.obj.h
    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      var s = Math.max(6, 10 / root.zoom)
      var cx = root.obj.w
      var cy = root.obj.h / 2
      ctx.beginPath()
      ctx.moveTo(cx, cy)
      ctx.lineTo(cx - s * 1.8, cy - s)
      ctx.lineTo(cx - s * 1.8, cy + s)
      ctx.closePath()
      ctx.fillStyle = root.obj.stroke ? root.obj.stroke : Color.foreground
      ctx.fill()
    }
  }

  // Image with rounded corners. The MultiEffect masks the Image directly —
  // the same approach the image picker uses, so it renders identically in this
  // shell's Qt build (OpacityMask is not available without Qt5Compat).
  Image {
    id: image
    anchors.fill: parent
    visible: root.isImage && !!root.obj.src
    source: root.obj.src ? Util.fileUrl(root.obj.src) : ""
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: true
    smooth: true
    layer.enabled: true

    Rectangle {
      id: imageMask
      anchors.fill: parent
      radius: Style.cornerRadius
      visible: false
      layer.enabled: true
      color: "white"
    }

    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: imageMask
      maskThresholdMin: 0.3
      maskSpreadAtMin: 0.3
    }
  }

  // ---- selection chrome ---------------------------------------------------

  Rectangle {
    id: selFrame
    anchors.fill: parent
    visible: root.selected
    color: "transparent"
    radius: root.obj.type === "sticky" ? 4 : Style.cornerRadius
    border.width: 1
    border.color: Util.alpha(Color.accent, 0.9)
  }

  Rectangle {
    id: lockBadge
    visible: root.obj.locked
    width: 14; height: 14
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.margins: -7
    radius: 7
    color: Color.background
    Text {
      anchors.centerIn: parent
      text: ""
      color: Color.foreground
      font.family: root.fontFamily
      font.pixelSize: 9
    }
  }

  // ---- resize handles -----------------------------------------------------

  Repeater {
    model: root.selected && root.interactive ? 4 : 0
    delegate: Item {
      required property int index
      readonly property string corner: ["tl", "tr", "br", "bl"][index]
      readonly property point hp: doc.handlePos(root.obj, corner)
      x: (hp.x - root.obj.x) * zoom
      y: (hp.y - root.obj.y) * zoom
      width: Math.max(9, 12 / zoom)
      height: width

      Rectangle {
        anchors.centerIn: parent
        width: Math.max(6, 10 / zoom)
        height: width
        radius: 2
        color: Color.background
        border.width: 1.5
        border.color: Color.accent
        rotation: root.obj.rot
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.SizeFDiagCursor
        enabled: root.interactive
        onPressed: function(mouse) { root.handlePressed(corner, mouse.x, mouse.y) }
      }
    }
  }

  Item {
    id: rotateHandle
    visible: root.selected && root.interactive
    readonly property point hp: doc.handlePos(root.obj, "tr")
    x: (hp.x - root.obj.x) * zoom
    y: (hp.y - root.obj.y) * zoom - (26 / zoom)
    width: Math.max(10, 14 / zoom)
    height: width

    Rectangle {
      anchors.centerIn: parent
      width: Math.max(8, 12 / zoom)
      height: width
      radius: width / 2
      color: Color.background
      border.width: 1.5
      border.color: Util.alpha(Color.accent, 0.95)
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.CrossCursor
      enabled: root.interactive
      onPressed: function(mouse) { root.rotateRequested() }
    }
  }

  // ---- pointer ------------------------------------------------------------
  // Gesture-driven: the first movement records the origin, each later
  // movement reports the delta from the previous event. The document commits
  // the delta, so there is no per-frame repaint loop and undo can capture one
  // drag as one entry.

  MouseArea {
    id: hit
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.interactive ? Qt.SizeAllCursor : Qt.ArrowCursor
    enabled: root.interactive

    property point last: Qt.point(0, 0)
    property point origin: Qt.point(0, 0)
    property bool dragging: false

    onPressed: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      last = Qt.point(mouse.x, mouse.y)
      origin = Qt.point(mouse.x, mouse.y)
      dragging = true
      root.pressed(mouse.x, mouse.y,
        (mouse.modifiers & Qt.ShiftModifier) || (mouse.modifiers & Qt.ControlModifier))
    }
    onPositionChanged: function(mouse) {
      if (!dragging) return
      root.dragGesture(mouse.x - last.x, mouse.y - last.y)
      last = Qt.point(mouse.x, mouse.y)
    }
    onReleased: function() {
      if (!dragging) return
      dragging = false
      root.released()
    }
    onDoubleClicked: function(mouse) {
      if (root.isText) root.editRequested()
    }
  }
}
