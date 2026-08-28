import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup. Both live in one entry point, which is the
// first-party convention for rich bar widgets — the manifest points
// `barWidget` at this file and the bar mounts it directly into its slot.
//
// Service.qml owns every process and all state; this file owns the button, the
// keyboard state machine, and the layout. Nothing here names a protocol —
// Backends.qml is the registry that does, and everything below reads
// `tunnel.protocol` and the backend's own `label`.
Panel {
  id: root
  moduleName: "connor.vpn"
  ipcTarget: "connor.vpn"
  manageIpc: false

  // Cursor state. One flat list of rows so j/k walks one protocol's profiles
  // straight into the next without the sections knowing about each other.
  property bool cursorActive: false
  property int cursorIndex: 0
  property var pendingDelete: null

  readonly property var rows: vpn.sortedTunnels
  readonly property bool headerHasCursor: cursorActive && cursorIndex === -1

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property color barIconColor: vpn.active ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string toggleHint: vpn.connected
    ? "Disconnect " + vpn.activeTunnels[0].name
    : "Connect the last used VPN"

  function selectedTunnel() {
    if (rows.length === 0 || cursorIndex < 0) return null
    return rows[Math.max(0, Math.min(cursorIndex, rows.length - 1))]
  }

  function setCursor(index) {
    cursorActive = true
    cursorIndex = Math.max(-1, Math.min(index, rows.length - 1))
  }

  function moveCursor(dx, dy) {
    var step = dy !== 0 ? dy : dx
    if (step === 0) return
    // -1 is the header switch, 0..n-1 are the profile rows.
    var next = cursorIndex + step
    if (next < -1) next = rows.length - 1
    if (next > rows.length - 1) next = -1
    cursorIndex = next
  }

  function activateCursor() {
    if (cursorIndex === -1) {
      vpn.toggleActive()
      return
    }
    activate(selectedTunnel())
  }

  function activate(tunnel) {
    if (!tunnel) return
    vpn.toggleTunnel(tunnel)
    // Remember the profile so the bar's right-click has something to bring
    // back up after a disconnect.
    if (!vpn.isActive(tunnel)) persistSettings({ lastTunnelId: tunnel.id })
  }

  function requestDelete(tunnel) {
    if (!tunnel) return
    // Set rather than bound: a binding would break on the first left/right and
    // never re-arm, leaving the next dialog pre-aimed at Delete. Cancel is the
    // default so a stray enter cannot destroy a profile.
    deleteConfirm.selectedIndex = 0
    pendingDelete = tunnel
  }

  // Applied locally so the panel redraws on the click, then written back
  // through the bar to shell.json. With no writable entry it degrades to a
  // session-only preference, which is intended.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function ensureCursor() {
    if (cursorIndex > rows.length - 1) cursorIndex = rows.length - 1
    if (cursorIndex < -1) cursorIndex = -1
  }

  function open() {
    vpn.refresh()
    cursorActive = false
    cursorIndex = rows.length > 0 ? 0 : -1
    root.controller.show()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: !vpn.hideWhenDisconnected || vpn.connected

  // Backends.qml is the one file that names a protocol; everything here reads
  // `tunnel.protocol` and each backend's own `label`.
  Backends { id: backends }

  Service {
    id: vpn
    settings: root.settings
    backends: backends.all
    // Expensive probes — routes, resolvers, exit IP — only run while the
    // popup is actually open.
    detailed: root.opened
  }

  Connections {
    target: vpn
    function onProfilesChanged() { root.ensureCursor() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { vpn.refresh(); return "ok" }
    function up(): string { vpn.toggleActive(); return "ok" }
    function down(): string { if (vpn.connected) vpn.disconnectTunnel(vpn.activeTunnels[0]); return "ok" }
    function status(): string { return vpn.statusText }
    // The structured test surface: everything Tier 3 asserts on comes from
    // here, so panel logic is testable without screenshots.
    function state(): string { return vpn.stateJson() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        VpnIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
          badgeColor: root.urgent
          connected: vpn.active
          crossed: !vpn.active
          busy: vpn.busy
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) vpn.toggleActive()
      else if (buttonCode === Qt.MiddleButton) vpn.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the confirmation is up it owns every key. ConfirmDialog's own
      // handleKey() wants raw events, which this catcher has already turned
      // into intent — so the dialog is driven through the same signals as
      // everything else rather than plumbing a second key path to it.
      onMoveRequested: function(dx, dy) {
        if (root.pendingDelete) {
          deleteConfirm.selectedIndex = deleteConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: {
        if (root.pendingDelete) {
          if (deleteConfirm.selectedIndex === 0) deleteConfirm.canceled()
          else deleteConfirm.confirmed()
          return
        }
        if (root.cursorActive) root.activateCursor()
      }
      onCloseRequested: {
        if (root.pendingDelete) root.pendingDelete = null
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.pendingDelete) {
          deleteConfirm.selectedIndex = deleteConfirm.selectedIndex === 0 ? 1 : 0
          return
        }
        root.switchPanel(direction)
      }
      onDeleteRequested: if (!root.pendingDelete) root.requestDelete(root.selectedTunnel())
      onTextKey: function(t) {
        if (root.pendingDelete) return
        if (t === "r" || t === "R") vpn.refresh()
        else if (t === "d" || t === "D") { if (vpn.connected) vpn.disconnectTunnel(vpn.activeTunnels[0]) }
        else if (t === "i" || t === "I") { if (backends.primary) vpn.beginImport(backends.primary.protocol) }
        else if (t === "x" || t === "X") root.requestDelete(root.selectedTunnel())
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero rather than this Panel.
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.setCursor(-1) }

            PanelHero {
              id: hero
              width: parent.width
              title: vpn.connected ? vpn.activeTunnels[0].name : "VPN"
              meta: vpn.statusText
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: vpn.active ? 1.0 : 0.5
              iconComponent: Component {
                VpnIcon {
                  iconSize: Style.font.display
                  color: vpn.active ? root.foreground : root.dim
                  badgeColor: root.urgent
                  connected: vpn.active
                  crossed: !vpn.active
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: root.rows.length > 0
                  checked: vpn.active
                  busy: vpn.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: vpn.toggleActive()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.toggleHint
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // Status line, then errors, then warnings — each only when it has
          // something to say.
          Text {
            visible: vpn.actionStatus !== ""
            width: parent.width
            text: vpn.actionStatus
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: vpn.lastError !== "" && vpn.actionStatus === ""
            width: parent.width
            text: vpn.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: vpn.warnings
            Text {
              required property var modelData
              width: column.width
              text: "⚠ " + modelData
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // Live stats for the active tunnel. Tier 1 answers "am I actually
          // protected?", Tier 2 is session facts. The physical-interface
          // numbers belong to the built-in network widget; everything here is
          // scoped to the tunnel device and labelled as such.
          Column {
            id: stats
            visible: vpn.activeTunnel !== null && vpn.activeTunnel.device !== ""
            width: parent.width
            spacing: Style.space(6)

            readonly property var telemetry: vpn.activeTunnel ? vpn.telemetryFor(vpn.activeTunnel) : Model.emptyTelemetry()

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "THIS TUNNEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            StatRow {
              label: "Default route"
              value: stats.telemetry.defaultRoute
                ? "via " + vpn.activeTunnel.device
                : "not via " + vpn.activeTunnel.device
              // The silent failure mode: the link is up but traffic is not
              // using it. Worth shouting about.
              alert: !stats.telemetry.defaultRoute
            }

            StatRow {
              label: "DNS"
              value: stats.telemetry.dns.length > 0
                ? stats.telemetry.dns.join(", ")
                : "none scoped to the tunnel"
              alert: stats.telemetry.dns.length === 0
            }

            StatRow {
              visible: stats.telemetry.addresses.length > 0
              label: "Address"
              value: stats.telemetry.addresses.join(", ")
            }

            StatRow {
              visible: vpn.exitIpEnabled
              label: "Exit IP"
              value: vpn.telemetryPlane.exitIp !== "" ? vpn.telemetryPlane.exitIp : "checking…"
            }

            StatRow {
              label: "Connected"
              value: Model.formatDuration(vpn.activeSecondsFor(vpn.activeTunnel))
            }

            StatRow {
              label: "Transferred"
              value: "↓ " + Model.formatBytes(stats.telemetry.rxBytes)
                + "   ↑ " + Model.formatBytes(stats.telemetry.txBytes)
            }

            StatRow {
              label: "Throughput"
              value: "↓ " + Model.formatRate(stats.telemetry.rxRate)
                + "   ↑ " + Model.formatRate(stats.telemetry.txRate)
            }

            StatRow {
              visible: vpn.activeTunnel && vpn.activeTunnel.endpoint !== ""
              label: "Endpoint"
              value: vpn.activeTunnel ? vpn.activeTunnel.endpoint : ""
            }
          }

          // One section per backend. The dependency card lives inside the
          // section so a missing binary is scoped to the protocol that needs
          // it and never to the widget.
          Repeater {
            model: vpn.backends

            Column {
              id: section
              required property var modelData
              readonly property var backend: modelData
              readonly property var sectionTunnels: Model.groupByProtocol(root.rows, backend.protocol)
              readonly property bool depMissing: vpn.missingDeps[backend.protocol] === true

              width: column.width
              spacing: Style.space(10)

              PanelSeparator { foreground: root.foreground }

              Item {
                width: parent.width
                implicitHeight: Math.max(sectionLabel.implicitHeight, importButton.height)

                PanelSectionHeader {
                  id: sectionLabel
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: section.backend.label.toUpperCase()
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Row {
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(4)

                  PanelActionButton {
                    id: rescanButton
                    iconText: "⟳"
                    tooltipText: "Rescan installed profiles (asks for authorization)"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: vpn.rescan(section.backend.protocol)
                  }

                  PanelActionButton {
                    id: importButton
                    iconText: "＋"
                    tooltipText: "Import a " + section.backend.label + " profile"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: vpn.beginImport(section.backend.protocol)
                  }
                }
              }

              // Point-of-use dependency card. Never rendered on load, and
              // never for a protocol the user is not reaching for.
              DependencyCard {
                visible: section.depMissing
                width: parent.width
                backend: section.backend
              }

              EmptyNote {
                visible: !section.depMissing && section.sectionTunnels.length === 0
                width: parent.width
                text: "No " + section.backend.label + " profiles yet. Use ＋ to import one."
              }

              Repeater {
                model: section.sectionTunnels
                Column {
                  id: tunnelItem
                  required property var modelData
                  width: section.width
                  spacing: Style.space(6)

                  TunnelRow {
                    width: tunnelItem.width
                    tunnel: tunnelItem.modelData
                  }

                  // Anything the profile needs beyond its backend, shown under
                  // the row it belongs to and for as long as it is missing —
                  // not once at import, when the profile is about to be
                  // installed and stay broken.
                  Repeater {
                    model: tunnelItem.modelData.requires || []
                    RequirementNote {
                      required property var modelData
                      width: tunnelItem.width
                      requirement: modelData
                    }
                  }
                }
              }
            }
          }
        }
      }

      // Deleting a profile removes files from a system directory and cannot be
      // undone, so it is confirmed rather than done on a keystroke.
      ConfirmDialog {
        id: deleteConfirm
        anchors.fill: parent
        opened: root.pendingDelete !== null
        message: root.pendingDelete
          ? "Delete the profile “" + root.pendingDelete.name + "”? This removes its "
            + "configuration and keys from the system and cannot be undone."
          : ""
        confirmText: "Delete"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.pendingDelete = null
        onConfirmed: {
          vpn.deleteTunnel(root.pendingDelete)
          root.pendingDelete = null
        }
      }
    }
  }

  component StatRow: Item {
    id: statRow
    property string label: ""
    property string value: ""
    property bool alert: false

    width: stats.width
    implicitHeight: Math.max(statLabel.implicitHeight, statValue.implicitHeight)

    Text {
      id: statLabel
      anchors.left: parent.left
      anchors.top: parent.top
      width: Math.round(parent.width * 0.34)
      text: statRow.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      id: statValue
      anchors.left: statLabel.right
      anchors.right: parent.right
      anchors.top: parent.top
      text: statRow.value
      color: statRow.alert ? root.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }
  }

  component DependencyCard: Column {
    id: card
    property var backend: null

    // True between the hand-off to omarchy-install-app and the moment the
    // binary shows up. The terminal is detached, so this is the only signal
    // the card has that anything is happening.
    readonly property bool waiting: card.backend
      && vpn.dependencyWatch === card.backend.protocol

    spacing: Style.space(8)

    Text {
      width: card.width
      text: card.backend
        ? card.backend.label + " is not installed, so its profiles cannot be imported or started."
        : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    Text {
      width: card.width
      text: card.backend
        ? (card.waiting
            ? "Finish the install in the terminal window. This card clears itself once `"
              + card.backend.packageName + "` is on the system."
            : "Installs the `" + card.backend.packageName + "` package.")
        : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Row {
      spacing: Style.space(8)

      Button {
        text: card.waiting ? "Waiting…" : "Install"
        enabled: !card.waiting
        opacity: enabled ? 1.0 : 0.5
        onClicked: vpn.installDependency(card.backend.protocol)
      }

      Button {
        text: "Re-check"
        onClicked: vpn.recheckDependency(card.backend.protocol)
      }
    }
  }

  // The per-profile twin of DependencyCard. Same hand-off, same self-clearing
  // watch, but keyed on a command rather than a backend — so it can never make
  // a working backend look uninstalled.
  component RequirementNote: Column {
    id: note
    property var requirement: null

    readonly property bool missing: note.requirement
      && vpn.isCommandMissing(note.requirement.command)
    readonly property bool waiting: note.requirement
      && vpn.requirementWatch === note.requirement.command

    visible: note.missing
    spacing: Style.space(6)

    Text {
      width: note.width
      text: note.requirement ? "⚠ " + note.requirement.warning : ""
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Row {
      spacing: Style.space(8)

      Button {
        text: note.waiting
          ? "Waiting…"
          : "Install " + (note.requirement ? note.requirement.label : "")
        enabled: !note.waiting
        opacity: enabled ? 1.0 : 0.5
        onClicked: vpn.installRequirement(note.requirement.command,
                                          note.requirement.packageName,
                                          note.requirement.label)
      }

      Button {
        text: "Re-check"
        onClicked: vpn.recheckRequirement(note.requirement.command)
      }
    }
  }

  component EmptyNote: CursorSurface {
    id: note
    property string text: ""
    foreground: root.foreground
    implicitHeight: noteText.implicitHeight + Style.spacing.rowPaddingX

    Text {
      id: noteText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(12)
      text: note.text
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.WordWrap
    }
  }

  component TunnelRow: CursorSurface {
    id: row
    property var tunnel: null
    // The cursor indexes the flat sorted list, not the section, so a row finds
    // its own position rather than being handed one by the Repeater.
    readonly property int rowIndex: tunnel ? root.rows.indexOf(tunnel) : -1
    readonly property bool rowActive: rowIndex >= 0 && vpn.isActive(tunnel)
    readonly property bool rowBusy: vpn.isBusy(tunnel)
    readonly property bool rowFailed: !!tunnel && tunnel.state === "failed"

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex && rowIndex >= 0
    current: rowActive
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill

    implicitHeight: rowInner.implicitHeight + Style.spacing.xl

    Row {
      id: rowInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      VpnIcon {
        anchors.verticalCenter: parent.verticalCenter
        iconSize: Style.space(13)
        width: Style.space(22)
        color: row.rowFailed ? root.urgent : (row.rowActive ? root.foreground : root.dim)
        badgeColor: root.urgent
        connected: row.rowActive
        crossed: false
        opacity: row.rowBusy ? 0.45 : 1.0

        SequentialAnimation on opacity {
          running: row.rowBusy
          loops: Animation.Infinite
          NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
        }
      }

      Column {
        width: parent.width - Style.space(22) - Style.space(8) - deleteButton.width - Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(2)

        Text {
          text: row.tunnel ? row.tunnel.name : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: row.rowActive
          elide: Text.ElideRight
          width: parent.width
        }

        Text {
          visible: text !== ""
          text: {
            if (!row.tunnel) return ""
            if (row.rowFailed) return "failed to start"
            if (row.rowActive && row.tunnel.device !== "") return row.tunnel.device
            if (row.rowBusy) return "working…"
            return row.tunnel.endpoint
          }
          color: row.rowFailed ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }

      PanelActionButton {
        id: deleteButton
        anchors.verticalCenter: parent.verticalCenter
        iconText: "🗑"
        tooltipText: "Delete this profile"
        foreground: root.foreground
        hoverColor: root.urgent
        fontFamily: root.fontFamily
        onClicked: root.requestDelete(row.tunnel)
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      // Sits under the delete button so the button keeps its own clicks.
      z: -1
      onEntered: root.setCursor(row.rowIndex)
      onClicked: root.activate(row.tunnel)
    }
  }
}
