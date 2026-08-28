import QtQuick

// Shield mark, drawn rather than shipped as an SVG: the bar renders this at
// ~11px, where a scaled-down SVG goes soft, and a Canvas path stays crisp and
// takes the theme color directly.
//
// States: filled when a tunnel is up, outline when it is down, plus a slash
// for down and a dot for a command in flight.
Item {
  id: root

  property real iconSize: 16
  property color color: "#cacccc"
  property color badgeColor: "#a55555"
  property bool connected: false
  property bool crossed: false
  property bool busy: false

  implicitWidth: iconSize
  implicitHeight: iconSize

  onColorChanged: canvas.requestPaint()
  onConnectedChanged: canvas.requestPaint()
  onCrossedChanged: canvas.requestPaint()
  onIconSizeChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()

      var w = width
      var h = height
      var inset = w * 0.12
      var top = h * 0.08
      var bottom = h * 0.94
      var left = inset
      var right = w - inset
      var shoulder = h * 0.42

      // Shield outline: straight shoulders down to a rounded point.
      ctx.beginPath()
      ctx.moveTo(w / 2, top)
      ctx.lineTo(right, top + h * 0.14)
      ctx.lineTo(right, shoulder)
      ctx.quadraticCurveTo(right, bottom - h * 0.18, w / 2, bottom)
      ctx.quadraticCurveTo(left, bottom - h * 0.18, left, shoulder)
      ctx.lineTo(left, top + h * 0.14)
      ctx.closePath()

      ctx.strokeStyle = root.color
      ctx.fillStyle = root.color
      ctx.lineWidth = Math.max(1, w * 0.1)
      ctx.lineJoin = "round"

      if (root.connected) ctx.fill()
      else ctx.stroke()

      if (root.crossed) {
        // Punch the slash out of the mark so it reads at bar size instead of
        // blending into the fill.
        ctx.globalCompositeOperation = "destination-out"
        ctx.beginPath()
        ctx.lineWidth = Math.max(1.5, w * 0.16)
        ctx.moveTo(w * 0.16, h * 0.9)
        ctx.lineTo(w * 0.84, h * 0.12)
        ctx.stroke()
        ctx.globalCompositeOperation = "source-over"

        ctx.beginPath()
        ctx.lineWidth = Math.max(1, w * 0.09)
        ctx.strokeStyle = root.color
        ctx.moveTo(w * 0.16, h * 0.9)
        ctx.lineTo(w * 0.84, h * 0.12)
        ctx.stroke()
      }
    }
  }

  // Activity dot, top-trailing, same idea as the Tailscale widget's badge.
  Rectangle {
    visible: root.busy
    width: Math.max(3, root.iconSize * 0.28)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.rightMargin: -width * 0.2
    anchors.topMargin: -height * 0.2

    SequentialAnimation on opacity {
      running: root.busy
      loops: Animation.Infinite
      NumberAnimation { from: 0.35; to: 1.0; duration: 600 }
      NumberAnimation { from: 1.0; to: 0.35; duration: 600 }
    }
  }
}
