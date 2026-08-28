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
  // Commands required by installed profiles: name -> true when absent.
  // Deliberately NOT folded into missingDeps, which is keyed by protocol: a
  // package one profile happens to need does not make its whole backend
  // uninstalled, and must never put up the backend's "not installed" card.
  property var missingCommands: ({})
  property var _commandQueue: []
  property string _commandChecking: ""

  // The same detached-terminal problem as the backend install, so the same
  // shape of answer: a bounded watch that clears the note by itself.
  property string _reqWatchCommand: ""
  property int _reqWatchTicks: 0
  // Held separately from the watch key: the watch has no budget until the
  // hand-off returns, and setting its key early starts the timer against a
  // budget of zero, which expires it on the first tick.
  property string _reqInstallCommand: ""
  readonly property string requirementWatch: _reqWatchCommand

  property string _actionUnit: ""
  property int _actionSeq: 0
  property int _journalSeq: -1

  // Import state machine.
  property string _installProtocol: ""

  // Cleared in credentialProcess.onStarted, as soon as it has been written.
  property string _credentialPayload: ""
  property string _credentialProtocol: ""
  property string _credentialName: ""
  property bool _credentialPresent: false

  // ---- kill switch ----
  // The rules live in the kernel and `nft list` needs CAP_NET_ADMIN, so this
  // is read from the marker the privileged helper writes. Never assumed:
  // absent means disarmed, which is also what a reboot leaves behind.
  property var killswitch: Model.parseKillswitch("")
  // True only while a stop the user actually asked for is in flight. An
  // unexpected drop must leave the rules standing — that is the whole point
  // of a kill switch — so the two cases can never be told apart after the
  // fact and have to be distinguished here, as it happens.
  property bool _disarmAfterStop: false

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
    || chooserProcess.running || listProcess.running || killswitchProcess.running

  readonly property int refreshIntervalSec: _intSetting("refreshIntervalSec", 15, 5, 3600)
  readonly property bool hideWhenDisconnected: _setting("hideWhenDisconnected", false) === true
  readonly property bool exitIpEnabled: _setting("showExitIp", false) === true
  readonly property bool killSwitchEnabled: _setting("killSwitch", false) === true

  readonly property bool killswitchArmed: killswitch && killswitch.armed === true
  readonly property string killswitchText: Model.killswitchText(killswitch, connected)

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
        endpointProto: entry.endpointProto,
        requires: entry.requires,
        needsCredentials: entry.needsCredentials,
        hasCredentials: entry.hasCredentials,
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
    // Two sysfs-cheap reads a tick: the marker is on a tmpfs and is four
    // lines long.
    killswitchFile.reload()
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
      // updateTunnel, not makeTunnel: the poll changes one field and must
      // carry the rest forward untouched.
      next.push(Model.updateTunnel(tunnel, {
        state: Model.stateFromIsActive(block.ActiveState || "")
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
        // Some protocols name the interface after the profile, so the device
        // is known in advance and there is nothing to discover. Diffing is
        // the fallback for the ones that do not.
        var appeared = _knownDevice(backend, awaited, devices)
        if (appeared === "") {
          appeared = Model.newDevice(_devicesBefore, devices, backend.devicePrefixes)
        }
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
        if (proto) device = _knownDevice(proto, tunnel, devices)
        if (device !== "") claimed[device] = true
        if (device === "" && proto) {
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

      next.push(Model.updateTunnel(tunnel, {
        // A unit can report active while its device never appeared — the
        // half-up tunnel. Until the device exists this is still activating.
        state: Model.reconcileState(tunnel.state, device !== ""),
        device: device
      }))
    }

    _deviceFor = assignments
    tunnels = next
    _settlePending()
    // Last, and only here: the device names are what the rules are built
    // from, so anything earlier would arm against a device that is not up.
    _maintainKillswitch()
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

  // "" when the backend cannot say, or when the device it names is not
  // actually present — a stale answer would be worse than none, because every
  // telemetry read downstream would then be pointed at the wrong interface.
  function _knownDevice(backend, tunnel, devices) {
    if (!backend || !tunnel || !backend.deviceFor) return ""
    var named = backend.deviceFor(tunnel.name)
    if (!named) return ""
    return devices.indexOf(named) !== -1 ? named : ""
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
    // A stop the user asked for takes the rules down with it. An unexpected
    // drop does not — see _maintainKillswitch().
    _disarmAfterStop = killswitchArmed
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

  // ------------------------------------------------- profile requirements

  function isCommandMissing(command) {
    return missingCommands[command] === true
  }

  // The catalogue lives in the backend, so the panel can render a correction
  // to a package name or its wording against a profile imported before it.
  function requirementFor(protocol, command) {
    var backend = backendFor(protocol)
    if (!backend || !backend.requirementFor) return null
    return backend.requirementFor(command)
  }

  // Every distinct command the installed profiles say they need.
  function _requiredCommands() {
    var seen = {}
    var out = []
    for (var i = 0; i < tunnels.length; i++) {
      var reqs = tunnels[i].requires || []
      for (var j = 0; j < reqs.length; j++) {
        var name = reqs[j]
        if (!name || seen[name]) continue
        seen[name] = true
        out.push(name)
      }
    }
    return out
  }

  // Called when the panel opens and after an import — never on load, and never
  // from the poll. A profile's requirement is only interesting to someone
  // actually looking at their profiles.
  function checkRequirements(force) {
    var wanted = _requiredCommands()
    var queue = []
    for (var i = 0; i < wanted.length; i++) {
      if (!force && missingCommands[wanted[i]] !== undefined) continue
      queue.push(wanted[i])
    }
    if (queue.length === 0) return
    _commandQueue = queue
    _checkNextCommand()
  }

  function recheckRequirement(command) {
    if (!command) return
    _commandQueue = [command]
    _checkNextCommand()
  }

  function _checkNextCommand() {
    if (commandProcess.running || _commandQueue.length === 0) return
    var next = _commandQueue.slice()
    _commandChecking = next.shift()
    _commandQueue = next
    commandProcess.command = ["omarchy-cmd-missing", _commandChecking]
    commandProcess.running = true
  }

  // Hands off exactly like the backend install does — never a package manager
  // from here.
  function installRequirement(command, packageName, label) {
    if (!command || !packageName) return
    if (reqInstallProcess.running) return
    actionStatus = "Installing " + (label || packageName) + "…"
    lastError = ""
    _reqInstallCommand = command
    reqInstallProcess.command = ["omarchy-install-app", label || packageName, packageName]
    reqInstallProcess.running = true
  }

  function _startRequirementWatch(command) {
    if (!command) return
    _reqWatchCommand = command
    _reqWatchTicks = 100          // 100 x 3s — five minutes, then give up
    reqWatchTimer.restart()
    recheckRequirement(command)
  }

  function _stopRequirementWatch() {
    _reqWatchCommand = ""
    _reqWatchTicks = 0
    reqWatchTimer.stop()
  }

  function _reqWatchTick() {
    var command = _reqWatchCommand
    if (command === "") {
      _stopRequirementWatch()
      return
    }
    if (_reqWatchTicks <= 0) {
      _requirementWatchExpired(command)
      return
    }
    _reqWatchTicks -= 1
    recheckRequirement(command)
  }

  // Same reasoning as the backend watch: reverting the button with no message
  // makes a declined install, a failed one and a slow mirror identical.
  function _requirementWatchExpired(command) {
    _stopRequirementWatch()
    lastError = "`" + command + "` still isn't installed. Finish the install in the"
      + " terminal and press Re-check, or install the package by hand."
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
    var name = Model.profileNameFromPath(path, backend.maxNameLength)
    if (name === "") {
      lastError = "That filename does not make a usable profile name."
      return
    }
    _importPath = path
    _importName = name
    actionStatus = "Reading " + name + "…"
    // Assigning the path triggers the read, and only a CHANGE triggers it —
    // re-importing the same file would otherwise sit at "Reading…" forever.
    // Same shape as the stdin re-arm below.
    importFile.path = ""
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
    // Same look-before-installing, for a command resolved through PATH. The
    // backend supplies the name and the sentence; the service only asks.
    var checks = plan.requiredCommands || []
    for (var c = 0; c < checks.length; c++) command.push("--command", checks[c])

    actionStatus = "Preparing " + _importName + "…"
    // Re-arm stdin before every run. `stdinEnabled = false` is what sends EOF,
    // and it only sends it on a CHANGE — after one import the property is
    // already false, so the next import's assignment fires nothing, the pipe
    // is never closed, and stage-profile's `cat` waits forever with the whole
    // config already written. Verified with a throwaway `quickshell -p`
    // config: the second run of the same Process writes its payload and never
    // exits, and re-arming fixes it.
    importProcess.stdinEnabled = true
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
      if (line.indexOf("missing-hook: ") === 0) {
        var path = line.substring("missing-hook: ".length)
        next.push("This profile runs `" + path + "`, which is not on this system. "
          + "The tunnel will fail to start until whatever provides it is installed.")
        continue
      }
      if (line.indexOf("missing-command: ") !== 0) continue
      var found = requirementFor(_importProtocol, line.substring("missing-command: ".length))
      if (found) next.push(found.warning)
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

  // ------------------------------------------------------- credentials
  //
  // Stored in a root-owned 0600 file beside the profile, because the realistic
  // attacker is a process running as the user: the session keyring auto-unlocks
  // at login and hands secrets to anything asking, while the profile directory
  // is not readable by an unprivileged process at all. The reasoning, and the
  // residual risk (an unencrypted backup of /etc), is in PLAN.md and the README.
  //
  // The password never becomes a command-line argument, and it is held here
  // only for the moment between asking the process to start and its stdin
  // existing to be written to — Quickshell's Process has no way to hand a
  // payload to a launch, so `onStarted` is where it goes, and _credentialPayload
  // is cleared there. It is never in stateJson, never in a command array, and
  // never persisted.

  function supportsCredentials(protocol) {
    var backend = backendFor(protocol)
    return !!backend && backend.supportsCredentials === true
  }

  function credentialLabels(protocol) {
    var backend = backendFor(protocol)
    return backend && backend.credentialLabels ? backend.credentialLabels : null
  }

  function setCredentials(tunnel, username, password) {
    if (!tunnel || credentialProcess.running) return
    if (!supportsCredentials(tunnel.protocol)) return
    if (String(username || "") === "") {
      lastError = "A username is required."
      return
    }

    _credentialProtocol = tunnel.protocol
    _credentialName = tunnel.name
    _credentialPresent = true
    actionStatus = "Saving credentials for " + tunnel.name + " — authorize to continue…"
    lastError = ""

    // The secret is NOT in this array. /proc/<pid>/cmdline is world-readable,
    // so an argument would be disclosed to every process on the machine for as
    // long as pkexec runs, whatever the file it lands in is chmodded to.
    credentialProcess.command = [
      "pkexec", pluginDir + "/bin/install-profile",
      "set-credentials", tunnel.protocol, tunnel.name
    ]
    // Two lines, exactly what the helper's two `read -r` calls consume.
    _credentialPayload = String(username) + "\n" + String(password || "") + "\n"
    // Re-arm before every run: `stdinEnabled = false` is what sends EOF and it
    // only sends it on a CHANGE, so the second save of a session would write
    // its two lines and then hang on the helper's `read`. Same trap as import.
    credentialProcess.stdinEnabled = true
    credentialProcess.running = true
  }

  function clearCredentials(tunnel) {
    if (!tunnel || credentialProcess.running) return
    if (!supportsCredentials(tunnel.protocol)) return

    _credentialProtocol = tunnel.protocol
    _credentialName = tunnel.name
    _credentialPresent = false
    actionStatus = "Removing credentials for " + tunnel.name + " — authorize to continue…"
    lastError = ""
    credentialProcess.command = [
      "pkexec", pluginDir + "/bin/install-profile",
      "clear-credentials", tunnel.protocol, tunnel.name
    ]
    _credentialPayload = ""
    credentialProcess.stdinEnabled = true
    credentialProcess.running = true
  }

  // ------------------------------------------------------------- kill switch
  //
  // Arming is a privileged operation and a visible one: it can take the
  // machine off the network, so it is never silent and never inferred. The
  // README documents `pkexec .../bin/killswitch off` as the way back if the
  // shell is not there to offer the button.

  function armKillswitch(tunnel) {
    if (!tunnel || killswitchProcess.running) return
    // The endpoint is "host:port". Without one there is nothing to permit,
    // and arming anyway would block the tunnel it is meant to protect.
    var endpoint = String(tunnel.endpoint || "")
    var cut = endpoint.lastIndexOf(":")
    if (cut < 1) {
      lastError = "`" + tunnel.name + "` has no endpoint, so the kill switch has nothing to allow through."
      return
    }
    var host = endpoint.substring(0, cut)
    var port = endpoint.substring(cut + 1)
    if (String(tunnel.device || "") === "") {
      lastError = "The tunnel device is not up yet."
      return
    }

    actionStatus = "Turning the kill switch on — authorize to continue…"
    lastError = ""
    killswitchProcess.command = [
      "pkexec", pluginDir + "/bin/killswitch",
      "on", tunnel.device, host, port, String(tunnel.endpointProto || "udp")
    ]
    killswitchProcess.running = true
  }

  function disarmKillswitch() {
    if (killswitchProcess.running) return
    actionStatus = "Turning the kill switch off — authorize to continue…"
    lastError = ""
    killswitchProcess.command = ["pkexec", pluginDir + "/bin/killswitch", "off"]
    killswitchProcess.running = true
  }

  function toggleKillswitch() {
    if (killswitchArmed) disarmKillswitch()
    else if (activeTunnel) armKillswitch(activeTunnel)
    else lastError = "Connect a tunnel first — a kill switch with nothing to protect just blocks everything."
  }

  // Called once per poll, after devices have been resolved. It only ever
  // arms: a tunnel that goes down on its own must leave the rules standing,
  // and the only paths that disarm are the user asking and a deliberate
  // disconnect.
  // Set false on every copy of the widget but one — see Panel.qml's
  // killswitchOwner. Without it, three monitors mean three pkexec calls for
  // one tunnel coming up.
  property bool killswitchOwner: true

  function _maintainKillswitch() {
    if (!killswitchOwner || killswitchProcess.running || !killSwitchEnabled) return
    var tunnel = activeTunnel
    if (!tunnel || String(tunnel.device || "") === "") return
    // Stale means the rules name a device that is no longer the tunnel's —
    // a reconnect that came back as tun1 would otherwise be blocked by the
    // switch that is supposed to be protecting it.
    if (!killswitchArmed || Model.killswitchStale(killswitch, tunnel)) armKillswitch(tunnel)
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
      missingCommands: {},
      requirementWatch: requirementWatch,
      // Presence and parameters, which are not secrets — the endpoint and
      // port are already on the profile row. Tier 3 asserts on this.
      killswitch: {
        armed: killswitchArmed,
        device: killswitch ? killswitch.device : "",
        endpoint: killswitch ? killswitch.endpoint : "",
        port: killswitch ? killswitch.port : "",
        proto: killswitch ? killswitch.proto : "",
        enabled: killSwitchEnabled,
        // Which copy of the widget arms automatically. One bar per monitor
        // means one Service per monitor, and only one of them may fire pkexec.
        owner: killswitchOwner,
        text: killswitchText
      },
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
        endpointProto: tunnel.endpointProto,
        state: tunnel.state,
        device: tunnel.device,
        rxBytes: telem.rxBytes,
        txBytes: telem.txBytes,
        defaultRoute: telem.defaultRoute,
        dns: telem.dns,
        addresses: telem.addresses,
        requires: tunnel.requires,
        // Presence only. The secret is never in this plugin's state, which is
        // exactly why this is asserted on rather than the file being read.
        needsCredentials: tunnel.needsCredentials,
        hasCredentials: tunnel.hasCredentials
      })
    }
    for (var key in missingDeps) out.missingDeps[key] = missingDeps[key]
    for (var cmd in missingCommands) out.missingCommands[cmd] = missingCommands[cmd]
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
      // Point of use: someone is looking at their profiles. Never on load.
      checkRequirements(false)
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
        // The stop the user asked for succeeded, so the rules come down with
        // it. Only here: a tunnel that dropped by itself never reaches this.
        if (root._disarmAfterStop) {
          root._disarmAfterStop = false
          root.disarmKillswitch()
        }
      } else {
        root._disarmAfterStop = false
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
    id: commandProcess
    running: false
    command: []
    onExited: function(exitCode) {
      // omarchy-cmd-missing exits 0 when the command is absent.
      var missing = exitCode === 0
      var next = {}
      for (var key in root.missingCommands) next[key] = root.missingCommands[key]
      next[root._commandChecking] = missing
      root.missingCommands = next

      if (!missing && root._reqWatchCommand === root._commandChecking) {
        root._stopRequirementWatch()
      }
      root._commandChecking = ""
      root._checkNextCommand()
    }
  }

  Process {
    id: reqInstallProcess
    running: false
    command: []
    onExited: {
      root.actionStatus = ""
      // Detached terminal: this fires on launch, not on completion.
      root._startRequirementWatch(root._reqInstallCommand)
    }
  }

  Timer {
    id: reqWatchTimer
    interval: 3000
    repeat: true
    running: root._reqWatchCommand !== ""
    onTriggered: root._reqWatchTick()
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

  Process {
    id: killswitchProcess
    running: false
    command: []
    stderr: StdioCollector { id: killswitchErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode !== 0) {
        var text = Model.cleanError(String(killswitchErr.text || ""))
        root.lastError = text !== "" ? text : "Authorization was declined."
      }
      // Read the marker back either way rather than assuming the command did
      // what it said: a failed arm that left half a table would otherwise be
      // invisible, and it is the state where being wrong costs the most.
      killswitchFile.reload()
    }
  }

  FileView {
    id: killswitchFile
    path: "/run/connor-vpn/killswitch"
    watchChanges: false
    printErrors: false
    onLoaded: root.killswitch = Model.parseKillswitch(text())
    // Absent is the normal case, not an error: the marker lives on a tmpfs
    // and does not exist until something arms.
    onLoadFailed: root.killswitch = Model.parseKillswitch("")
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

  // Both credential verbs, because they are mutually exclusive by nature and a
  // single in-flight guard is easier to reason about than two.
  Process {
    id: credentialProcess
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: credentialErr; waitForEnd: true }
    onStarted: {
      // Empty for clear-credentials, which reads nothing — the EOF still has
      // to be sent, or a helper that grew a read one day would hang here.
      write(root._credentialPayload)
      root._credentialPayload = ""
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      root.actionStatus = ""
      if (exitCode === 0) {
        store.markCredentials(root._credentialProtocol, root._credentialName,
                              root._credentialPresent)
      } else {
        var text = Model.cleanError(String(credentialErr.text || ""))
        root.lastError = text !== "" ? text : "Authorization was declined."
      }
      root._credentialProtocol = ""
      root._credentialName = ""
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
          endpoint: root._importPlan ? root._importPlan.endpoint : "",
          // The transport the tunnel dials out on, for the kill switch's
          // endpoint rule. Derived by the backend from the config; nothing
          // outside backends/ knows what decides it.
          endpointProto: root._importPlan ? root._importPlan.endpointProto : "udp",
          // Kept with the profile, not reported once and forgotten: the
          // profile stays broken until the package arrives.
          requires: root._importPlan ? root._importPlan.requiredCommands : [],
          // Whether the profile asks for a username and password. The backend
          // decides that from the config; nothing here reads one.
          needsCredentials: !!root._importPlan && root._importPlan.needsCredentials === true
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
