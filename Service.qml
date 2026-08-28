import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Tunnel state and every command the widget runs. Protocol-agnostic by
// construction: it drives whatever backends it is given through their uniform
// interface, and there is no protocol name anywhere in this file.
//
// Control plane: stock systemd template units. No unit file, no polkit policy
// and no daemon is installed by this plugin — `systemctl start` is authorized
// by the stock org.freedesktop.systemd1.manage-units action, which resolves to
// auth_admin_keep for an active session and so prompts once through the
// running polkit agent.
//
// Panel.qml owns all presentation; this file owns processes and state.
Item {
  id: root

  property var settings: ({})
  property var backends: []
  property bool detailed: false          // true while the popup is open

  property var tunnels: []
  property string actionStatus: ""
  property string lastError: ""
  property var warnings: []

  // Optimistic switching. A unit takes a second or two to settle and a switch
  // that does not move until the next poll reads as a dropped click, so a
  // pending id steers the UI while the command is in flight. The poll is the
  // source of truth and clears it once it agrees; pendingTimeout unsticks the
  // switch if confirmation never lands.
  property string _pendingId: ""
  property bool _pendingUp: false

  // protocol -> true once we have confirmed its binary is missing. Populated
  // lazily, at the point of use, never on load: a user with only one
  // protocol's profiles must never be warned about the other's.
  property var missingDeps: ({})
  property string _depCheckProtocol: ""
  property string _depCheckIntent: ""
  property var _depCheckTunnel: null

  // omarchy-install-app execs a DETACHED terminal, so installProcess exits
  // almost immediately — long before pacman has finished. A single re-check at
  // that moment always reports the package still missing and strands the card.
  // So the hand-off starts a watch that re-probes on an interval until the
  // binary appears or the budget runs out, and the card clears itself.
  property string _depWatchProtocol: ""
  property int _depWatchTicks: 0
  // The protocol whose install we are waiting on, "" when idle. Public: the
  // panel renders a waiting state from it, and stateJson exposes it to Tier 4.
  readonly property string dependencyWatch: _depWatchProtocol

  property var _deviceFor: ({})
  // Every netdev name from the last poll, for the before/after comparison that
  // identifies a newly created tunnel device.
  property var _lastDevices: []
  // id -> ActiveEnterTimestampMonotonic, paired with uptime to make a duration.
  property var _sinceFor: ({})
  property double _uptimeSeconds: 0
  property var _devicesBefore: []
  property string _awaitingDeviceFor: ""

  // The unit the last command acted on, and a counter that increments with
  // every command. The journal is read asynchronously after a failure, so the
  // answer can arrive once the user has already tried something else — the
  // counter is what stops a stale reason from landing on a fresh attempt.
  property string _actionUnit: ""
  property int _actionSeq: 0
  property int _journalSeq: -1

  // Import state machine.
  property string _installProtocol: ""

  property string _importProtocol: ""
  property string _importPath: ""
  property string _importName: ""
  property var _importPlan: null
  property string _importStaging: ""

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/connor.vpn"
  readonly property string cacheRoot: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache"))
    + "/connor.vpn"

  readonly property var sortedTunnels: Model.sortTunnels(tunnels)
  readonly property var activeTunnels: Model.activeTunnels(sortedTunnels)
  readonly property bool connected: activeTunnels.length > 0
  readonly property var activeTunnel: activeTunnels.length > 0 ? activeTunnels[0] : null

  // What the bar icon shows while a command is in flight.
  readonly property bool active: _pendingId === "" ? connected : _pendingUp
  readonly property string statusText: Model.statusText(sortedTunnels, _pendingName())
  readonly property bool busy: stateProcess.running || linkProcess.running
    || actionProcess.running || importProcess.running || installProcess.running
    || chooserProcess.running || listProcess.running

  readonly property int refreshIntervalSec: _intSetting("refreshIntervalSec", 15, 5, 3600)
  readonly property bool hideWhenDisconnected: _setting("hideWhenDisconnected", false) === true
  readonly property bool exitIpEnabled: _setting("showExitIp", false) === true

  signal profilesChanged()

  // ------------------------------------------------------------- settings

  function _setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function _intSetting(name, fallback, min, max) {
    var n = parseInt(String(_setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function _pendingName() {
    if (_pendingId === "" || !_pendingUp) return ""
    var tunnel = Model.findTunnel(tunnels, _pendingId)
    return tunnel ? tunnel.name : ""
  }

  function backendFor(protocol) {
    for (var i = 0; i < backends.length; i++) {
      if (backends[i].protocol === protocol) return backends[i]
    }
    return null
  }

  // ------------------------------------------------------------- read state

  function isPending(tunnel) {
    return !!tunnel && _pendingId === tunnel.id
  }

  // The row's displayed state: optimistic while its own command is in flight.
  // Panel.qml reads this, never a raw `state` field.
  function isActive(tunnel) {
    if (!tunnel) return false
    return isPending(tunnel) ? _pendingUp : tunnel.state === "up"
  }

  function isBusy(tunnel) {
    return isPending(tunnel) || (!!tunnel && Model.isBusyState(tunnel.state))
  }

  // Seconds the tunnel has been up, or 0 when it is not.
  function activeSecondsFor(tunnel) {
    if (!tunnel || tunnel.state !== "up") return 0
    return Model.activeSeconds(_sinceFor[tunnel.id], _uptimeSeconds)
  }

  function telemetryFor(tunnel) {
    if (tunnel && activeTunnel && tunnel.id === activeTunnel.id) return telemetry.telemetry
    return Model.emptyTelemetry()
  }

  // ------------------------------------------------------------- refresh

  // Rebuilds the tunnel list from the profile index, preserving live state.
  function rebuild() {
    var next = []
    var skipped = []
    for (var i = 0; i < store.profiles.length; i++) {
      var entry = store.profiles[i]
      var backend = backendFor(entry.protocol)
      if (!backend) continue

      // A name that cannot become a unit instance would put an empty string
      // into the `systemctl show` argument list and break the poll for every
      // other profile. Nothing this widget installs can produce one, but a
      // hand-edited index can.
      var unit = backend.unitFor(entry.name)
      if (unit === "") {
        skipped.push(entry.name)
        continue
      }

      var existing = Model.findTunnel(tunnels, entry.protocol + ":" + entry.name)
      next.push(Model.makeTunnel({
        name: entry.name,
        protocol: entry.protocol,
        unit: unit,
        endpoint: entry.endpoint,
        state: existing ? existing.state : "down",
        device: existing ? existing.device : ""
      }))
    }
    tunnels = next
    if (skipped.length > 0) {
      lastError = "Ignoring " + skipped.length + " profile(s) with an unusable name: "
        + skipped.join(", ") + ". Use ⟳ to rescan."
    }
    root.profilesChanged()
    refresh()
  }

  function refresh() {
    if (tunnels.length === 0 || stateProcess.running) return
    var units = []
    for (var i = 0; i < tunnels.length; i++) units.push(tunnels[i].unit)
    // One call for every unit. `show` rather than `is-active` because it also
    // carries the timestamp the duration row needs, and because it labels each
    // block with the unit's own Id — so a unit systemd declines to describe
    // cannot shift every state onto the wrong row.
    stateProcess.command = ["systemctl", "show",
                            "-p", "Id", "-p", "ActiveState",
                            "-p", "ActiveEnterTimestampMonotonic"].concat(units)
    stateProcess.running = true
  }

  function _applyStates(output) {
    var blocks = Model.parseShowBlocks(output)
    var next = []
    var since = {}
    for (var i = 0; i < tunnels.length; i++) {
      var tunnel = tunnels[i]
      var block = blocks[tunnel.unit] || {}
      since[tunnel.id] = block.ActiveEnterTimestampMonotonic || "0"
      next.push(Model.makeTunnel({
        name: tunnel.name,
        protocol: tunnel.protocol,
        unit: tunnel.unit,
        endpoint: tunnel.endpoint,
        state: Model.stateFromIsActive(block.ActiveState || ""),
        device: tunnel.device
      }))
    }
    tunnels = next
    _sinceFor = since

    // Device resolution needs the netdev list, which is a second process.
    if (!linkProcess.running) {
      linkProcess.command = ["ip", "-j", "link"]
      linkProcess.running = true
    }
    // A monotonic stamp only means something next to the current uptime.
    uptimeFile.reload()
  }

  function _applyDevices(output) {
    var devices = Model.parseLinkDevices(output)
    _lastDevices = devices
    var claimed = {}
    var assignments = {}
    for (var key in _deviceFor) {
      if (devices.indexOf(_deviceFor[key]) !== -1) {
        assignments[key] = _deviceFor[key]
        claimed[_deviceFor[key]] = true
      }
    }

    // A unit we just started: whichever tunnel device appeared since the
    // snapshot taken before the command is unambiguously ours.
    if (_awaitingDeviceFor !== "") {
      var awaited = Model.findTunnel(tunnels, _awaitingDeviceFor)
      var backend = awaited ? backendFor(awaited.protocol) : null
      if (backend) {
        var appeared = Model.newDevice(_devicesBefore, devices, backend.devicePrefixes)
        if (appeared !== "") {
          assignments[_awaitingDeviceFor] = appeared
          claimed[appeared] = true
          _awaitingDeviceFor = ""
        }
      }
    }

    var next = []
    for (var i = 0; i < tunnels.length; i++) {
      var tunnel = tunnels[i]
      var device = assignments[tunnel.id] || ""

      // A tunnel that was already up when the shell started has no snapshot to
      // compare against, so it takes the first unclaimed device matching its
      // protocol. With one tunnel up that is exact; with several up at once it
      // can pair the wrong device with the wrong row, which is the known cost
      // of never asking for privilege to find out properly.
      if (device === "" && tunnel.state === "up") {
        var proto = backendFor(tunnel.protocol)
        if (proto) {
          for (var d = 0; d < devices.length; d++) {
            if (claimed[devices[d]]) continue
            for (var p = 0; p < proto.devicePrefixes.length; p++) {
              if (devices[d].indexOf(proto.devicePrefixes[p]) === 0) {
                device = devices[d]
                claimed[device] = true
                break
              }
            }
            if (device !== "") break
          }
        }
      }

      if (tunnel.state !== "up" && tunnel.state !== "activating") device = ""
      if (device !== "") assignments[tunnel.id] = device

      next.push(Model.makeTunnel({
        name: tunnel.name,
        protocol: tunnel.protocol,
        unit: tunnel.unit,
        endpoint: tunnel.endpoint,
        // A unit can report active while its device never appeared — the
        // half-up tunnel. Until the device exists this is still activating.
        state: Model.reconcileState(tunnel.state, device !== ""),
        device: device
      }))
    }

    _deviceFor = assignments
    tunnels = next
    _settlePending()
  }

  function _settlePending() {
    if (_pendingId === "") return
    var tunnel = Model.findTunnel(tunnels, _pendingId)
    if (!tunnel) { _clearPending(); return }
    if (Model.isBusyState(tunnel.state)) return
    if ((tunnel.state === "up") === _pendingUp) {
      _clearPending()
    } else if (tunnel.state === "failed") {
      _clearPending()
      lastError = "`" + tunnel.name + "` failed to start. Check `journalctl -u " + tunnel.unit + "`."
    }
  }

  function _clearPending() {
    _pendingId = ""
    actionStatus = ""
    pendingTimeout.stop()
  }

  // ------------------------------------------------------------- control

  function connectTunnel(tunnel) {
    if (!tunnel || actionProcess.running) return
    // Lazy dependency detection: the check happens here, at the point of use,
    // and nowhere near load.
    if (!_ensureDependency(tunnel.protocol, "connect", tunnel)) return

    _pendingId = tunnel.id
    _pendingUp = true
    lastError = ""
    warnings = []
    actionStatus = "Connecting to " + tunnel.name + "…"
    _awaitingDeviceFor = tunnel.id
    _devicesBefore = _currentDevices()
    _actionUnit = tunnel.unit
    _actionSeq += 1
    actionProcess.command = ["systemctl", "start", tunnel.unit]
    actionProcess.running = true
    pendingTimeout.restart()
  }

  function disconnectTunnel(tunnel) {
    if (!tunnel || actionProcess.running) return
    _pendingId = tunnel.id
    _pendingUp = false
    lastError = ""
    actionStatus = "Disconnecting " + tunnel.name + "…"
    _awaitingDeviceFor = ""
    _actionUnit = tunnel.unit
    _actionSeq += 1
    actionProcess.command = ["systemctl", "stop", tunnel.unit]
    actionProcess.running = true
    pendingTimeout.restart()
  }

  function toggleTunnel(tunnel) {
    if (!tunnel) return
    if (isActive(tunnel)) disconnectTunnel(tunnel)
    else connectTunnel(tunnel)
  }

  // Right-click on the bar icon: drop the active tunnel, or bring the most
  // recently used one back up.
  function toggleActive() {
    if (activeTunnels.length > 0) {
      disconnectTunnel(activeTunnels[0])
      return
    }
    var preferred = lastUsedTunnel()
    if (preferred) connectTunnel(preferred)
  }

  function lastUsedTunnel() {
    var id = String(_setting("lastTunnelId", ""))
    var found = Model.findTunnel(sortedTunnels, id)
    if (found) return found
    return sortedTunnels.length > 0 ? sortedTunnels[0] : null
  }

  // Every netdev seen by the last poll — NOT just the ones we have claimed.
  // Snapshotting only our own would make an unrelated tun device that already
  // existed (another VPN client, a container) look like the one our unit just
  // created, and hand its counters to the wrong row.
  function _currentDevices() {
    return _lastDevices
  }

  // ------------------------------------------------------------- dependencies

  // Returns true when the protocol's binaries are present. When they are not,
  // records it and lets the panel render an install card — and never touches
  // pacman itself.
  // `force` re-probes even when the answer is already known, WITHOUT first
  // clearing the recorded answer — clearing it would make the card vanish and
  // reappear on every poll tick of the post-install watch.
  function _ensureDependency(protocol, intent, tunnel, force) {
    if (!force) {
      if (missingDeps[protocol] === false) return true
      if (missingDeps[protocol] === true) return false
    }
    if (depProcess.running) return false

    var backend = backendFor(protocol)
    if (!backend) return true

    _depCheckProtocol = protocol
    _depCheckIntent = intent
    _depCheckTunnel = tunnel || null
    depProcess.command = ["omarchy-cmd-missing"].concat(backend.commands)
    depProcess.running = true
    return false
  }

  // Hands off to Omarchy's themed floating terminal rather than running pacman
  // ourselves. It is a terminal window, but it is user-initiated from our
  // button and fully auditable, which is the trade PLAN.md settles on.
  function installDependency(protocol) {
    var backend = backendFor(protocol)
    if (!backend) return
    if (installProcess.running) return
    actionStatus = "Installing " + backend.label + "…"
    lastError = ""
    _installProtocol = protocol
    installProcess.command = ["omarchy-install-app", backend.label, backend.packageName]
    installProcess.running = true
  }

  // The manual escape hatch behind the Re-check button. Forces a fresh probe.
  // It deliberately does NOT cancel a running watch — an impatient press
  // should not disable the thing that would have cleared the card anyway.
  function recheckDependency(protocol) {
    _ensureDependency(protocol, "recheck", null, true)
  }

  function _startDependencyWatch(protocol) {
    if (!protocol) return
    var backend = backendFor(protocol)
    if (!backend) return
    _depWatchProtocol = protocol
    _depWatchTicks = 100          // 100 x 3s — five minutes, then give up
    depWatchTimer.restart()
    // Probe once straight away: an install that was already satisfied, or
    // declined instantly, should not wait out the first interval.
    _ensureDependency(protocol, "watch", null, true)
  }

  // One poll of the post-install watch. A named function rather than an inline
  // timer body so the call-site audit in test/dependency.test.sh can see it.
  function _watchTick() {
    var protocol = _depWatchProtocol
    if (protocol === "") {
      _stopDependencyWatch()
      return
    }
    if (_depWatchTicks <= 0) {
      _dependencyWatchExpired(protocol)
      return
    }
    _depWatchTicks -= 1
    _ensureDependency(protocol, "watch", null, true)
  }

  // The budget ran out. Clearing the watch on its own flips the button from
  // "Waiting…" back to "Install" with no explanation, which makes a declined
  // install, a failed one and a slow mirror all look identical. Say what
  // happened and name the two ways forward.
  function _dependencyWatchExpired(protocol) {
    var backend = backendFor(protocol)
    _stopDependencyWatch()
    if (!backend) return
    lastError = backend.label + " still isn't installed. Finish the install in"
      + " the terminal and press Re-check, or install the " + backend.packageName
      + " package by hand."
  }

  function _stopDependencyWatch() {
    _depWatchProtocol = ""
    _depWatchTicks = 0
    depWatchTimer.stop()
  }

  // ------------------------------------------------------------- import

  function beginImport(protocol) {
    if (chooserProcess.running) return
    var backend = backendFor(protocol)
    if (!backend) return
    if (!_ensureDependency(protocol, "import", null)) return

    lastError = ""
    warnings = []
    _importProtocol = protocol
    chooserProcess.command = ["omarchy-file-select",
                              "--title", backend.importTitle,
                              "--extensions", backend.fileExtensions]
    chooserProcess.running = true
  }

  function _chosen(path) {
    var backend = backendFor(_importProtocol)
    if (!backend) return
    var name = Model.profileNameFromPath(path)
    if (name === "") {
      lastError = "That filename does not make a usable profile name."
      return
    }
    _importPath = path
    _importName = name
    actionStatus = "Reading " + name + "…"
    // Assigning the path triggers the read; onLoaded continues the flow.
    importFile.path = path
  }

  function _planImport(text) {
    var backend = backendFor(_importProtocol)
    if (!backend) return

    var plan = backend.planImport(text, _importPath, _importName)
    if (plan.errors.length > 0) {
      actionStatus = ""
      lastError = plan.errors.join(" ")
      _resetImport()
      return
    }

    _importPlan = plan
    warnings = plan.warnings
    _importStaging = cacheRoot + "/staging/" + _importName

    var command = ["bash", pluginDir + "/bin/stage-profile", _importStaging, plan.configName]
    for (var i = 0; i < plan.assets.length; i++) {
      command.push("--asset", plan.assets[i].source, plan.assets[i].target)
    }
    // Hooks are not staged, only looked for. The helper runs as the user and
    // can see the filesystem the pure config parser cannot.
    var hooks = plan.hookTargets || []
    for (var h = 0; h < hooks.length; h++) command.push("--hook", hooks[h])

    actionStatus = "Preparing " + _importName + "…"
    importProcess.command = command
    importProcess.running = true
  }

  // The staging helper reports a hook it could not find as `missing-hook: <p>`
  // on stdout. Saying so here is the whole point: the profile is valid, so
  // nothing else would object until the tunnel failed to come up.
  function _warnAboutMissingHooks(output) {
    var lines = String(output).split(/\r?\n/)
    var next = warnings.slice()
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line.indexOf("missing-hook: ") !== 0) continue
      var path = line.substring("missing-hook: ".length)
      next.push("This profile runs `" + path + "`, which is not on this system. "
        + "The tunnel will fail to start until whatever provides it is installed.")
    }
    // Reassign: mutating in place fires no change notification.
    if (next.length !== warnings.length) warnings = next
  }

  function _installStaged() {
    actionStatus = "Installing " + _importName + " — authorize to continue…"
    installProfileProcess.command = [
      "pkexec", pluginDir + "/bin/install-profile",
      "install", _importProtocol, _importName, _importStaging
    ]
    installProfileProcess.running = true
  }

  function _resetImport() {
    _importProtocol = ""
    _importPath = ""
    _importName = ""
    _importPlan = null
    _importStaging = ""
  }

  function deleteTunnel(tunnel) {
    if (!tunnel || removeProcess.running) return
    actionStatus = "Deleting " + tunnel.name + " — authorize to continue…"
    lastError = ""
    _importProtocol = tunnel.protocol
    _importName = tunnel.name
    removeProcess.command = [
      "pkexec", pluginDir + "/bin/install-profile",
      "remove", tunnel.protocol, tunnel.name
    ]
    removeProcess.running = true
  }

  // Repairs the index against what is actually installed. One privileged
  // listing, only ever because the user asked — never on the poll.
  function rescan(protocol) {
    if (listProcess.running) return
    _importProtocol = protocol
    actionStatus = "Rescanning — authorize to continue…"
    lastError = ""
    listProcess.command = ["pkexec", pluginDir + "/bin/install-profile", "list", protocol]
    listProcess.running = true
  }

  // ------------------------------------------------------------- IPC surface

  // The structured test surface: `omarchy-shell connor.vpn state` returns this,
  // which is how the panel's logic is asserted on without screenshots.
  function stateJson() {
    var out = {
      connected: connected,
      status: statusText,
      error: lastError,
      warnings: warnings,
      pending: _pendingId,
      profiles: [],
      missingDeps: {},
      dependencyWatch: dependencyWatch,
      backends: []
    }
    for (var i = 0; i < sortedTunnels.length; i++) {
      var tunnel = sortedTunnels[i]
      var telem = telemetryFor(tunnel)
      out.profiles.push({
        id: tunnel.id,
        name: tunnel.name,
        protocol: tunnel.protocol,
        unit: tunnel.unit,
        endpoint: tunnel.endpoint,
        state: tunnel.state,
        device: tunnel.device,
        rxBytes: telem.rxBytes,
        txBytes: telem.txBytes,
        defaultRoute: telem.defaultRoute,
        dns: telem.dns,
        addresses: telem.addresses
      })
    }
    for (var key in missingDeps) out.missingDeps[key] = missingDeps[key]
    for (var b = 0; b < backends.length; b++) {
      out.backends.push({ protocol: backends[b].protocol, label: backends[b].label })
    }
    return JSON.stringify(out)
  }

  // ------------------------------------------------------------- wiring

  ProfileStore {
    id: store
    onChanged: root.rebuild()
  }

  Telemetry {
    id: telemetry
    device: root.activeTunnel ? root.activeTunnel.device : ""
    detailed: root.detailed
    exitIpEnabled: root.exitIpEnabled
  }

  readonly property alias profileStore: store
  readonly property alias telemetryPlane: telemetry

  Component.onCompleted: refresh()

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    onTriggered: {
      root.refresh()
      telemetry.sample()
      if (root.detailed) telemetry.sampleDetailed()
    }
  }

  // Byte counters are two sysfs reads, so they can move at a readable rate
  // while the popup is open without costing anything.
  Timer {
    interval: 1000
    repeat: true
    running: root.detailed && root.activeTunnel !== null
    onTriggered: telemetry.sample()
  }

  // Post-install polling. Cheap (a fork every 3s), bounded, and it stops the
  // instant the probe comes back clean.
  Timer {
    id: depWatchTimer
    interval: 3000
    repeat: true
    onTriggered: root._watchTick()
  }

  // A tunnel takes a moment to settle after systemctl returns, so poll again
  // shortly rather than waiting out the full interval.
  Timer {
    id: settleTimer
    interval: 1200
    repeat: false
    onTriggered: root.refresh()
  }

  Timer {
    id: pendingTimeout
    interval: 30000
    repeat: false
    onTriggered: {
      root._pendingId = ""
      root.actionStatus = ""
      root._awaitingDeviceFor = ""
    }
  }

  onDetailedChanged: {
    if (detailed) {
      telemetry.sample()
      telemetry.sampleDetailed()
    }
  }

  // ------------------------------------------------------------- processes

  Process {
    id: stateProcess
    running: false
    command: []
    stdout: StdioCollector { id: stateOut; waitForEnd: true }
    onExited: root._applyStates(String(stateOut.text || ""))
  }

  Process {
    id: linkProcess
    running: false
    command: []
    stdout: StdioCollector { id: linkOut; waitForEnd: true }
    onExited: function(exitCode) {
      root._applyDevices(exitCode === 0 ? String(linkOut.text || "") : "")
    }
  }

  Process {
    id: actionProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.lastError = ""
      } else {
        root._clearPending()
        // Exit 1 with nothing on stderr is what a dismissed polkit prompt
        // looks like from here, and "Command failed" would be a lie.
        var text = Model.cleanError(String(actionErr.text || ""))
        root.lastError = text !== "" ? text : "Authorization was declined."
        // systemctl reports only that the job failed. The daemon's own reason
        // is in the journal, so go and read it — but show the message above
        // straight away, because that read is not instant and an empty panel
        // during it would look like nothing happened.
        root._readJournal()
      }
      settleTimer.restart()
      root.refresh()
    }
  }

  // Reading a system unit's journal needs no privilege, so this costs no
  // second polkit prompt. Deliberately not run on success: it is the only
  // process here that exists purely to improve an error message.
  function _readJournal() {
    if (_actionUnit === "" || journalProcess.running) return
    _journalSeq = _actionSeq
    journalProcess.command = ["journalctl", "-u", _actionUnit, "-n", "40",
                              "--no-pager", "-o", "cat"]
    journalProcess.running = true
  }

  Process {
    id: journalProcess
    running: false
    command: []
    stdout: StdioCollector { id: journalOut; waitForEnd: true }
    onExited: function(exitCode) {
      // A newer command has already been issued: whatever this says is about
      // the previous one, and replacing the current message with it would be
      // actively misleading.
      if (root._journalSeq !== root._actionSeq) return
      if (exitCode !== 0 || root.lastError === "") return
      var reason = Model.journalError(String(journalOut.text || ""))
      if (reason !== "") root.lastError = reason
    }
  }

  Process {
    id: depProcess
    running: false
    command: []
    onExited: function(exitCode) {
      // omarchy-cmd-missing exits 0 when ANY named command is absent.
      var missing = exitCode === 0
      var next = {}
      for (var key in root.missingDeps) next[key] = root.missingDeps[key]
      next[root._depCheckProtocol] = missing
      root.missingDeps = next

      if (!missing && root._depWatchProtocol === root._depCheckProtocol) {
        // The install landed. Clear the card without waiting for another tick.
        root._stopDependencyWatch()
      }

      if (!missing) {
        // Resume whatever the check interrupted.
        if (root._depCheckIntent === "connect" && root._depCheckTunnel) {
          root.connectTunnel(root._depCheckTunnel)
        } else if (root._depCheckIntent === "import") {
          root.beginImport(root._depCheckProtocol)
        }
      }
      root._depCheckIntent = ""
      root._depCheckTunnel = null
    }
  }

  Process {
    id: installProcess
    running: false
    command: []
    onExited: {
      root.actionStatus = ""
      // The terminal is detached, so this fires on LAUNCH, not on completion —
      // a single re-check here would always say "still missing". Watch instead.
      root._startDependencyWatch(root._installProtocol)
    }
  }

  Process {
    id: chooserProcess
    running: false
    command: []
    stdout: StdioCollector { id: chooserOut; waitForEnd: true }
    onExited: function(exitCode) {
      var picked = String(chooserOut.text || "").split("\n")[0].trim()
      if (exitCode === 0 && picked !== "") {
        root._chosen(picked)
      } else if (exitCode === 2) {
        root.lastError = "The file chooser could not be opened."
      }
      // Exit 1 is "nothing picked", which is a decision, not an error.
    }
  }

  FileView {
    id: uptimeFile
    path: "/proc/uptime"
    watchChanges: false
    printErrors: false
    onLoaded: root._uptimeSeconds = Model.parseUptimeSeconds(text())
  }

  FileView {
    id: importFile
    path: ""
    watchChanges: false
    printErrors: false
    onLoaded: root._planImport(text())
    onLoadFailed: {
      root.actionStatus = ""
      root.lastError = "Could not read that file."
      root._resetImport()
    }
  }

  Process {
    id: importProcess
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector { id: importOut; waitForEnd: true }
    stderr: StdioCollector { id: importErr; waitForEnd: true }
    onStarted: {
      // The rewritten config goes in on stdin so it never touches a file the
      // caller named.
      write(root._importPlan ? root._importPlan.content : "")
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root._warnAboutMissingHooks(String(importOut.text || ""))
        root._installStaged()
      } else {
        root.actionStatus = ""
        root.lastError = Model.cleanError(String(importErr.text || "")) || "Could not prepare the profile."
        root._resetImport()
      }
    }
  }

  Process {
    id: installProfileProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: installErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode === 0) {
        store.add({
          name: root._importName,
          protocol: root._importProtocol,
          endpoint: root._importPlan ? root._importPlan.endpoint : ""
        })
      } else {
        var text = Model.cleanError(String(installErr.text || ""))
        root.lastError = text !== "" ? text : "Authorization was declined."
      }
      cleanupProcess.command = ["rm", "-rf", root._importStaging]
      cleanupProcess.running = true
      root._resetImport()
    }
  }

  Process {
    id: cleanupProcess
    running: false
    command: []
  }

  Process {
    id: removeProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: removeErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode === 0) {
        store.remove(root._importProtocol, root._importName)
      } else {
        var text = Model.cleanError(String(removeErr.text || ""))
        root.lastError = text !== "" ? text : "Authorization was declined."
      }
      root._resetImport()
    }
  }

  Process {
    id: listProcess
    running: false
    command: []
    stdout: StdioCollector { id: listOut; waitForEnd: true }
    stderr: StdioCollector { id: listErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode !== 0) {
        var text = Model.cleanError(String(listErr.text || ""))
        root.lastError = text !== "" ? text : "Authorization was declined."
        return
      }
      var names = []
      var lines = String(listOut.text || "").split("\n")
      for (var i = 0; i < lines.length; i++) {
        var name = lines[i].trim()
        if (name !== "") names.push(name)
      }
      store.replaceProtocol(root._importProtocol, names)
      root._resetImport()
    }
  }
}
