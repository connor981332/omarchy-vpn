.pragma library

// Protocol-agnostic core. No QML types and no backend names on purpose:
// everything here is exercised by `node test/model.test.js`, and the same
// functions serve every protocol the widget grows. Anything that knows a
// config-file format lives in backends/<protocol>/ instead.

// ---------------------------------------------------------------- unit names

// systemd's escaping for a template instance (`foo@<instance>.service`).
//
// NOT used to build unit names in this plugin — see isLiteralUnitInstance()
// and Backend.unitFor() for why escaping an instance here would break the
// stock units. Kept because it is pinned against the real systemd-escape
// binary and a backend whose unit expands `%I`, or takes a path-shaped
// instance, would need it.
// Derived from unit_name_escape(): the valid set is [A-Za-z0-9:_.], "/" folds
// to "-", every other byte becomes \xNN over its UTF-8 encoding, and a leading
// "." is escaped so an instance can never look like a dotfile. Pinned against
// the real `systemd-escape` binary in test/harness/escape.test.sh.
function escapeUnitName(name) {
  var input = String(name || "")
  if (input === "") return ""

  var out = ""
  for (var i = 0; i < input.length; i++) {
    var ch = input[i]
    if (ch === "/") {
      out += "-"
    } else if (/[A-Za-z0-9:_.]/.test(ch)) {
      out += ch
    } else {
      out += _escapeBytes(ch)
    }
  }
  // A leading dot only: ".hidden" -> "\x2ehidden", but "a.b" keeps its dot.
  if (out[0] === ".") out = "\\x2e" + out.substring(1)
  return out
}

// \xNN per UTF-8 byte, which is what systemd emits for anything non-ASCII.
function _escapeBytes(ch) {
  var out = ""
  var encoded = encodeURIComponent(ch) // "%C3%BC" for "ü"
  for (var i = 0; i < encoded.length; i++) {
    if (encoded[i] === "%") {
      out += "\\x" + encoded.substring(i + 1, i + 3).toLowerCase()
      i += 2
    } else {
      out += "\\x" + encoded.charCodeAt(i).toString(16)
    }
  }
  return out
}

function unescapeUnitName(escaped) {
  var input = String(escaped || "")
  var bytes = []
  for (var i = 0; i < input.length; i++) {
    if (input[i] === "\\" && input[i + 1] === "x" && i + 3 < input.length) {
      bytes.push(parseInt(input.substring(i + 2, i + 4), 16))
      i += 3
    } else if (input[i] === "-") {
      bytes.push(0x2f)
    } else {
      bytes.push(input.charCodeAt(i))
    }
  }
  var percent = ""
  for (var b = 0; b < bytes.length; b++) {
    percent += "%" + ("0" + bytes[b].toString(16)).slice(-2)
  }
  try {
    return decodeURIComponent(percent)
  } catch (e) {
    return input
  }
}

// True when a name can be used AS-IS as a template instance.
//
// Note this is not the same question as "does systemd-escape leave it alone".
// systemd-escape exists to round-trip paths, so it escapes "-" (its stand-in
// for "/") even though a literal "-" is perfectly legal inside an instance
// name. Asking the escaper would reject "work-vpn", which is fine.
//
// The question that matters: the stock template units expand `%i` — the RAW
// instance name — straight into a filename (`--config %i.conf`), so the
// instance has to BE the filename stem, and it must therefore be legal both as
// a unit instance and as a filename. Systemd's valid set is
// [A-Za-z0-9:_.-] plus "\\"; a leading "." is refused so an instance can never
// become a dotfile.
function isLiteralUnitInstance(name) {
  var value = String(name || "")
  if (value === "") return false
  if (value[0] === ".") return false
  if (value.indexOf("/") !== -1) return false
  return /^[A-Za-z0-9:_.-]+$/.test(value)
}

// The profile name is also a filename in a system directory, so it is
// sanitized rather than escaped: escaping would let a name round-trip through
// the unit but still write "../../etc/passwd" on disk.
// `maxLength` is a backend property, not a constant: one protocol names its
// interface after the config file and so inherits the kernel's 15-character
// IFNAMSIZ limit, while the other only needs a filename. Defaults to the
// privileged helper's own cap so a caller that does not care still cannot
// produce a name install-profile would refuse.
function sanitizeProfileName(name, maxLength) {
  var limit = Number(maxLength) > 0 ? Number(maxLength) : 64
  var value = String(name || "").trim()
  value = value.replace(/\.[Cc][Oo][Nn][Ff]$/, "")
  value = value.replace(/[^A-Za-z0-9._-]+/g, "-")
  value = value.replace(/^[.-]+/, "")
  value = value.replace(/-{2,}/g, "-")
  value = value.replace(/[.-]+$/, "")
  value = value.substring(0, limit)
  // Truncating can re-expose a trailing separator the pass above removed.
  return value.replace(/[.-]+$/, "")
}

function profileNameFromPath(path, maxLength) {
  var raw = String(path || "")
  var base = raw.substring(raw.lastIndexOf("/") + 1)
  base = base.replace(/\.[A-Za-z0-9]+$/, "")
  return sanitizeProfileName(base, maxLength)
}

// ------------------------------------------------------------- tunnel shaping

// The one shape Panel.qml is allowed to see. Backends are adapters that
// produce these; nothing downstream may reach past `protocol` for behaviour.
function makeTunnel(fields) {
  var f = fields || {}
  var name = String(f.name || "")
  var protocol = String(f.protocol || "")
  return {
    id: protocol + ":" + name,
    name: name,
    protocol: protocol,
    unit: String(f.unit || ""),
    endpoint: String(f.endpoint || ""),
    state: String(f.state || "down"),
    device: String(f.device || ""),
    path: String(f.path || ""),
    telemetry: f.telemetry || emptyTelemetry()
  }
}

function emptyTelemetry() {
  return {
    since: 0,
    rxBytes: 0,
    txBytes: 0,
    rxRate: 0,
    txRate: 0,
    addresses: [],
    dns: [],
    defaultRoute: false,
    sampledAt: 0
  }
}

var STATES = ["down", "activating", "up", "deactivating", "failed"]

function isUp(tunnel) {
  return !!tunnel && tunnel.state === "up"
}

function isBusyState(state) {
  return state === "activating" || state === "deactivating"
}

// `systemctl is-active` vocabulary -> ours. Kept here rather than in the
// backend because every systemd-driven protocol answers with the same words.
function stateFromIsActive(text) {
  var value = String(text || "").trim().split("\n")[0].trim()
  if (value === "active") return "up"
  if (value === "activating" || value === "reloading") return "activating"
  if (value === "deactivating") return "deactivating"
  if (value === "failed") return "failed"
  return "down"
}

// A unit can report active while the tun device never appeared — the half-up
// tunnel. The device list is what promotes "up" from a claim to a fact.
// `systemctl show a.service b.service -p Id -p ActiveState -p X` emits one
// blank-line-separated block per unit. Keying the result by the Id it reports,
// rather than by argument position, means a unit systemd declines to describe
// shifts nothing onto its neighbours.
function parseShowBlocks(text) {
  var blocks = {}
  var current = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.trim() === "") {
      if (current.Id) blocks[current.Id] = current
      current = {}
      continue
    }
    var split = line.indexOf("=")
    if (split === -1) continue
    current[line.substring(0, split)] = line.substring(split + 1)
  }
  if (current.Id) blocks[current.Id] = current
  return blocks
}

// /proc/uptime: "732830.12 5812345.67" — seconds since boot, then idle time.
function parseUptimeSeconds(text) {
  var first = String(text || "").trim().split(/\s+/)[0]
  var value = parseFloat(first)
  return isFinite(value) && value >= 0 ? value : 0
}

// systemd reports ActiveEnterTimestampMonotonic in microseconds since boot,
// which only means something next to the current uptime. 0 is systemd's "never
// entered", not "entered at boot".
function activeSeconds(enterMonotonicUs, uptimeSeconds) {
  var enter = parseFloat(enterMonotonicUs)
  if (!isFinite(enter) || enter <= 0) return 0
  var seconds = Number(uptimeSeconds) - enter / 1000000
  return seconds > 0 ? seconds : 0
}

function reconcileState(unitState, deviceExists) {
  if (unitState === "up" && !deviceExists) return "activating"
  return unitState
}

function sortTunnels(tunnels) {
  var sorted = (tunnels || []).slice()
  sorted.sort(function(a, b) {
    var aUp = isUp(a)
    var bUp = isUp(b)
    if (aUp !== bUp) return aUp ? -1 : 1
    if (a.protocol !== b.protocol) return a.protocol < b.protocol ? -1 : 1
    return String(a.name).localeCompare(String(b.name))
  })
  return sorted
}

function activeTunnels(tunnels) {
  var active = []
  for (var i = 0; i < (tunnels || []).length; i++) {
    if (isUp(tunnels[i])) active.push(tunnels[i])
  }
  return active
}

function groupByProtocol(tunnels, protocol) {
  var group = []
  for (var i = 0; i < (tunnels || []).length; i++) {
    if (tunnels[i].protocol === protocol) group.push(tunnels[i])
  }
  return group
}

function findTunnel(tunnels, id) {
  for (var i = 0; i < (tunnels || []).length; i++) {
    if (tunnels[i].id === id) return tunnels[i]
  }
  return null
}

// Replaces one tunnel by id and returns a NEW array — QML does not notify on
// in-place mutation, so every path through here reassigns.
function replaceTunnel(tunnels, tunnel) {
  var next = []
  var found = false
  for (var i = 0; i < (tunnels || []).length; i++) {
    if (tunnels[i].id === tunnel.id) {
      next.push(tunnel)
      found = true
    } else {
      next.push(tunnels[i])
    }
  }
  if (!found) next.push(tunnel)
  return next
}

function protocolLabel(protocol) {
  return String(protocol || "").toUpperCase()
}

// ------------------------------------------------------------------ telemetry

// /sys/class/net/<dev>/statistics/<x>_bytes is a bare integer plus a newline.
function parseCounter(text) {
  var n = parseInt(String(text || "").trim(), 10)
  return isFinite(n) && n >= 0 ? n : 0
}

// Bytes per second between two samples. Guards the three ways this goes wrong:
// no previous sample, a clock that did not move, and a counter that went
// backwards (the device was recreated, so the old total is meaningless).
function rate(prevBytes, curBytes, prevMs, curMs) {
  if (!isFinite(prevMs) || prevMs <= 0) return 0
  var elapsed = (curMs - prevMs) / 1000
  if (elapsed <= 0) return 0
  var delta = curBytes - prevBytes
  if (delta < 0) return 0
  return delta / elapsed
}

// `ip -j route` — is the default route (or a 0/1 + 128/1 split default, which
// is what a full-tunnel VPN actually installs) pointed at our device?
function defaultRouteVia(routeJson, device) {
  if (!device) return false
  var routes = _parseJson(routeJson, [])
  for (var i = 0; i < routes.length; i++) {
    var r = routes[i] || {}
    if (r.dev !== device) continue
    var dst = String(r.dst || "")
    if (dst === "default" || dst === "0.0.0.0/1" || dst === "128.0.0.0/1") return true
  }
  return false
}

// `ip -j addr show dev <dev>`
function parseAddresses(addrJson) {
  var links = _parseJson(addrJson, [])
  var out = []
  for (var i = 0; i < links.length; i++) {
    var info = (links[i] || {}).addr_info || []
    for (var j = 0; j < info.length; j++) {
      var entry = info[j] || {}
      if (!entry.local) continue
      if (entry.scope === "link" || entry.scope === "host") continue
      out.push(entry.local + "/" + entry.prefixlen)
    }
  }
  return out
}

// `resolvectl status <dev>`. The block we want is "DNS Servers: a b" plus any
// bare continuation lines under it — a tunnel that pushed three resolvers
// wraps them across lines.
function parseResolvers(text) {
  var lines = String(text || "").split("\n")
  var servers = []
  var collecting = false
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var match = line.match(/^\s*(?:Current )?DNS Servers?:\s*(.*)$/i)
    if (match) {
      collecting = true
      _pushTokens(servers, match[1])
      continue
    }
    if (!collecting) continue
    // A continuation is indented and has no "Key:" of its own.
    if (/^\s+\S/.test(line) && line.indexOf(":") === -1) {
      _pushTokens(servers, line)
      continue
    }
    if (/^\s*\S.*:/.test(line)) collecting = false
  }
  return _unique(servers)
}

// `ip -j link` -> the device names that currently exist.
function parseLinkDevices(linkJson) {
  var links = _parseJson(linkJson, [])
  var names = []
  for (var i = 0; i < links.length; i++) {
    if (links[i] && links[i].ifname) names.push(links[i].ifname)
  }
  return names
}

// A tunnel's device is not in its config — it is whichever tun/wg device
// appeared that nothing else claims. Comparing the device list from before
// the unit started against the one after is the protocol-agnostic answer.
function newDevice(before, after, prefixes) {
  var known = {}
  for (var i = 0; i < (before || []).length; i++) known[before[i]] = true
  var wanted = prefixes || ["tun", "tap", "wg"]
  for (var j = 0; j < (after || []).length; j++) {
    var name = after[j]
    if (known[name]) continue
    for (var k = 0; k < wanted.length; k++) {
      if (name.indexOf(wanted[k]) === 0) return name
    }
  }
  return ""
}

// ----------------------------------------------------------------- formatting

function formatBytes(bytes) {
  var n = Number(bytes) || 0
  if (n < 1024) return n + " B"
  var units = ["KB", "MB", "GB", "TB"]
  var value = n / 1024
  var unit = 0
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024
    unit++
  }
  return (value < 10 ? value.toFixed(1) : Math.round(value)) + " " + units[unit]
}

function formatRate(bytesPerSec) {
  return formatBytes(Math.round(Number(bytesPerSec) || 0)) + "/s"
}

function formatDuration(seconds) {
  var total = Math.max(0, Math.floor(Number(seconds) || 0))
  var days = Math.floor(total / 86400)
  var hours = Math.floor((total % 86400) / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var secs = total % 60
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + _pad(minutes) + "m"
  if (minutes > 0) return minutes + "m " + _pad(secs) + "s"
  return secs + "s"
}

// The one-line summary under the hero title. Deliberately says nothing about
// dependencies: a missing binary is reported at the point of use, not here.
function statusText(tunnels, pendingName) {
  if (pendingName) return "Connecting to " + pendingName + "…"
  var active = activeTunnels(tunnels)
  if (active.length === 0) {
    return (tunnels || []).length === 0 ? "No VPN profiles configured" : "Not connected"
  }
  if (active.length === 1) return "Connected to " + active[0].name
  return "Connected to " + active.length + " VPNs"
}

// systemctl and pkexec both editorialise on stderr. Strip the ceremony so the
// panel shows the cause.
function cleanError(text) {
  var value = String(text || "").replace(/\s+/g, " ").trim()
  value = value.replace(/^(Error|Failed to \w+ \S+):\s*/i, "")
  // The "See ..." pointer is the tail of a one-line job-failure message, not a
  // line of its own — anchoring this at ^ meant it never fired once the
  // whitespace above had been collapsed, and the truncation that followed was
  // what actually reached the panel.
  value = value.replace(/\s*See ['"]?systemctl status.*$/i, "")
  return value.length > 140 ? value.substring(0, 137) + "…" : value
}

// ------------------------------------------------------------ journal errors

// `systemctl start` reports only that the job failed; the daemon's own reason
// goes to the journal and never crosses stderr. So a failed start is followed
// by a read of `journalctl -o cat`, and this picks the one line worth showing.
//
// Two rules carry it. Scope to the CURRENT attempt — the journal holds every
// previous run of the unit, and a stale error from an hour ago is worse than
// no error at all. Then rank, because most of what is left is bookkeeping and
// a few lines look like failures without being one.

// Never the answer: systemd's job machinery, the daemon's own follow-ups to an
// error it has already explained, and routine progress chatter.
var _JOURNAL_NOISE = [
  /^(Starting|Started|Stopping|Stopped|Reached|Created) /,
  /^Failed to start /,
  /: (Main process exited|Failed with result|Scheduled restart|Start request repeated|Deactivated successfully|Consumed )/,
  /^Options error: Please correct this error\./i,
  /^Use --help for more information\./i,
  // Pushed by the server and merely unrecognised by this client. It prints on
  // a perfectly healthy connection — observed on a working tunnel — so it must
  // never be reported as the cause of a failure.
  /^Options error: Unrecognized option or missing or extra parameter\(s\) in \[PUSH-OPTIONS\]/i,
  /^(net_|OPTIONS IMPORT|PUSH:|MANAGEMENT:|VERIFY OK|Validating|Attempting|Outgoing|Incoming|Control Channel|Data Channel|Peer Connection Initiated|Timers:|Protocol options:|library versions|Initialization Sequence)/,
  /^(WARNING|NOTE|DEPRECATED OPTION):/,
  // A shell transcript. One tunnel helper echoes every command it runs with
  // this prefix, so the last line before a failure is its cleanup rather than
  // its reason — reporting that would name the teardown as the cause.
  /^\[#\] /,
  /^SIG(TERM|HUP|INT|USR1)/,
  /^event_wait /
]

// The lines that are the cause, in the order we would rather report them.
// Authentication first: it is the one a user can act on immediately, and it is
// usually followed by a cascade of lower-level errors that would otherwise win.
var _JOURNAL_STRONG = [
  /AUTH_FAILED|auth-failure/i,
  /^Options error:/i,
  /(No such file or directory|Permission denied|Cannot open|Cannot resolve|Cannot load)/i,
  // A helper the tunnel needs that is not installed. The line names the
  // missing command, which is the whole answer.
  /: command not found/i,
  /^(TLS Error|RESOLVE:|Could not|Unable to)/i,
  /Exiting due to fatal error/i
]

function _isJournalNoise(line) {
  for (var i = 0; i < _JOURNAL_NOISE.length; i++) {
    if (_JOURNAL_NOISE[i].test(line)) return true
  }
  return false
}

// Returns "" when the journal says nothing useful, so the caller can keep
// whatever it already had rather than replacing it with a worse message.
function journalError(text) {
  var all = String(text || "").split(/\r?\n/)

  // systemd's "Starting <description>..." is the boundary between attempts.
  // The last one begins the attempt that just failed.
  var start = -1
  var i
  for (i = 0; i < all.length; i++) {
    if (/^Starting /.test(all[i].trim())) start = i
  }

  var lines = []
  for (i = start + 1; i < all.length; i++) {
    var line = all[i].replace(/\s+/g, " ").trim()
    if (line !== "" && !_isJournalNoise(line)) lines.push(line)
  }
  if (lines.length === 0) return ""

  // Among recognised causes, the FIRST wins: what follows it is usually the
  // fallout rather than the reason.
  for (var p = 0; p < _JOURNAL_STRONG.length; p++) {
    for (i = 0; i < lines.length; i++) {
      if (_JOURNAL_STRONG[p].test(lines[i])) return cleanError(lines[i])
    }
  }

  // Nothing recognised. Fall back to the LAST thing said before the process
  // died, which is the opposite choice for the opposite reason: with no
  // pattern to trust, proximity to the failure is the only signal left.
  return cleanError(lines[lines.length - 1])
}

// ------------------------------------------------------------------- internals

function _pad(n) {
  return n < 10 ? "0" + n : String(n)
}

function _parseJson(text, fallback) {
  var raw = String(text || "").trim()
  if (raw === "") return fallback
  try {
    var parsed = JSON.parse(raw)
    return parsed === null || parsed === undefined ? fallback : parsed
  } catch (e) {
    return fallback
  }
}

function _pushTokens(list, text) {
  var parts = String(text || "").trim().split(/\s+/)
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] !== "") list.push(parts[i])
  }
}

function _unique(list) {
  var seen = {}
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (seen[list[i]]) continue
    seen[list[i]] = true
    out.push(list[i])
  }
  return out
}
