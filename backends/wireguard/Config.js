.pragma library

// WireGuard config parsing, and the import plan built from it.
//
// The format is INI-shaped and much smaller than the other backend's: a
// `[Interface]` section, one or more `[Peer]` sections, and `Key = Value`
// lines. Everything a tunnel needs is normally inside the file, so import
// copies no side files in the common case and rewrites nothing.
//
// Pure: no QML types, so `node test/wireguard-config.test.js` runs it directly.

// Keys whose value is a shell command line rather than data. wg-quick runs
// these with the interface up or down; they are not rewritten, for the same
// reason the other backend does not rewrite a script hook — it lives wherever
// it was installed.
var HOOK_KEYS = ["PreUp", "PostUp", "PreDown", "PostDown"]

// ------------------------------------------------------------------- parsing

// Returns the sections in order, each with its entries, plus the original
// lines. Comments and blank lines are kept so the file can be written back
// unchanged — a config the user can no longer recognise is a bad import.
function parse(text) {
  var raw = String(text || "").replace(/\r\n?/g, "\n")
  var lines = raw.split("\n")
  var sections = []
  var current = null

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    var trimmed = line.trim()
    if (trimmed === "" || trimmed.charAt(0) === "#") continue

    var header = trimmed.match(/^\[([A-Za-z]+)\]$/)
    if (header) {
      current = { name: header[1], entries: [] }
      sections.push(current)
      continue
    }

    var eq = trimmed.indexOf("=")
    if (eq === -1) continue
    var key = trimmed.substring(0, eq).trim()
    var value = trimmed.substring(eq + 1).trim()
    // A trailing comment is legal on a value line.
    var hash = value.indexOf("#")
    if (hash !== -1) value = value.substring(0, hash).trim()
    if (key === "") continue

    // A key before any section header belongs to nothing; wg-quick would
    // refuse the file, and validate() says so.
    if (current === null) {
      current = { name: "", entries: [] }
      sections.push(current)
    }
    current.entries.push({ key: key, value: value })
  }

  return { text: raw, lines: lines, sections: sections }
}

function sectionsNamed(parsed, name) {
  var out = []
  var all = (parsed && parsed.sections) || []
  for (var i = 0; i < all.length; i++) {
    if (all[i].name.toLowerCase() === name.toLowerCase()) out.push(all[i])
  }
  return out
}

// Keys are case-insensitive in wg-quick's own parser, so they are here too.
function valueOf(section, key) {
  if (!section) return ""
  for (var i = 0; i < section.entries.length; i++) {
    if (section.entries[i].key.toLowerCase() === key.toLowerCase()) {
      return section.entries[i].value
    }
  }
  return ""
}

function valuesOf(section, key) {
  var out = []
  if (!section) return out
  for (var i = 0; i < section.entries.length; i++) {
    if (section.entries[i].key.toLowerCase() === key.toLowerCase()) {
      out.push(section.entries[i].value)
    }
  }
  return out
}

// ---------------------------------------------------------------- validation

// Refuses a file the tunnel could not possibly come up with. Everything softer
// than that is a warning, because a config that merely looks unusual is still
// the user's config.
function validate(parsed) {
  var errors = []
  var interfaces = sectionsNamed(parsed, "Interface")
  var peers = sectionsNamed(parsed, "Peer")

  if (interfaces.length === 0) {
    errors.push("This file has no [Interface] section, so it is not a WireGuard configuration.")
    return errors
  }
  if (interfaces.length > 1) {
    errors.push("This file has more than one [Interface] section.")
  }
  if (valueOf(interfaces[0], "PrivateKey") === "") {
    // Without it wg-quick fails at `wg setconf` with a message about a key
    // that is much less clear than this one.
    errors.push("The [Interface] section has no PrivateKey, so the tunnel cannot authenticate.")
  }
  if (peers.length === 0) {
    errors.push("This file has no [Peer] section, so there is nothing to connect to.")
  }
  return errors
}

// -------------------------------------------------------------------- endpoint

// The server this profile connects to, for the panel's Endpoint row. Taken
// from the first peer that names one: a config can legitimately carry peers
// with no endpoint (they dial in), but a client profile always has one.
function endpoint(parsed) {
  var peers = sectionsNamed(parsed, "Peer")
  for (var i = 0; i < peers.length; i++) {
    var value = valueOf(peers[i], "Endpoint")
    if (value !== "") return value
  }
  return ""
}

// ------------------------------------------------------------------ importing

// wg-quick names the interface after the config file, and the kernel caps an
// interface name at IFNAMSIZ. wg-quick enforces the same limit itself:
//   [[ $CONFIG_FILE =~ (^|/)([a-zA-Z0-9_=+.-]{1,15})\.conf$ ]] || die ...
var MAX_NAME_LENGTH = 15

// The plan Service.qml stages and installs, in the same shape the other
// backend produces. `assets` is normally empty: a WireGuard profile carries
// its keys inline, so there is nothing beside the config to copy.
function plan(text, opts) {
  opts = opts || {}
  var name = String(opts.name || "profile")

  var parsed = parse(text)
  var errors = validate(parsed)
  var warnings = []
  var hookTargets = []
  // Commands the profile will need at connect time that may not be installed.
  // The warning text lives here, with the protocol, rather than in the service
  // — naming a package is backend knowledge.
  var commandChecks = []

  if (name.length > MAX_NAME_LENGTH) {
    errors.push("The interface name may be at most " + MAX_NAME_LENGTH
      + " characters, and \"" + name + "\" is " + name.length + ".")
  }

  var interfaces = sectionsNamed(parsed, "Interface")
  var iface = interfaces.length > 0 ? interfaces[0] : null

  if (iface && valueOf(iface, "Address") === "") {
    warnings.push("The [Interface] section has no Address, so the tunnel will come up "
      + "with no IP and carry no traffic.")
  }

  // The DNS trap. wg-quick applies `DNS =` by shelling out to `resolvconf`,
  // which on Arch comes from openresolv — an *optional* dependency of
  // wireguard-tools and not in Omarchy's base. Without it wg-quick fails with
  // `resolvconf: command not found`, deletes the interface it just made, and
  // exits 127. Nearly every commercial WireGuard profile sets DNS, so this is
  // the most likely way a stranger's first WireGuard tunnel fails.
  if (iface && valueOf(iface, "DNS") !== "") {
    commandChecks.push({
      command: "resolvconf",
      warning: "This profile sets DNS, which wg-quick applies with `resolvconf` — "
        + "and that command is not installed. Install the openresolv package, or "
        + "remove the DNS line, or the tunnel will fail to start."
    })
  }

  var peers = sectionsNamed(parsed, "Peer")
  for (var p = 0; p < peers.length; p++) {
    if (valueOf(peers[p], "PublicKey") === "") {
      warnings.push("A [Peer] section has no PublicKey and will be rejected.")
    }
  }
  if (peers.length > 0 && endpoint(parsed) === "") {
    warnings.push("No peer names an Endpoint, so this profile waits to be connected to "
      + "rather than connecting out.")
  }

  // Hooks, handled exactly as the other backend handles a script directive:
  // never rewritten, warned about under /home, and otherwise handed to the
  // caller to look for on the real filesystem.
  for (var s = 0; s < (parsed.sections || []).length; s++) {
    var entries = parsed.sections[s].entries
    for (var e = 0; e < entries.length; e++) {
      if (!_isHookKey(entries[e].key)) continue
      var target = _commandPath(entries[e].value)
      if (target === "") continue
      if (target.indexOf("/home/") === 0 || target.indexOf("~") === 0) {
        warnings.push("`" + entries[e].key + "` runs `" + target + "`, which is in your "
          + "home directory. Move it somewhere outside /home so the service can reach it.")
      } else {
        hookTargets.push(target)
      }
    }
  }

  return {
    name: name,
    protocol: "wireguard",
    endpoint: endpoint(parsed),
    // Self-contained and left alone. Only the line endings are normalised, so
    // a config written on Windows does not arrive with carriage returns.
    content: parsed.text.replace(/\n+$/, "") + "\n",
    assets: [],
    hookTargets: hookTargets,
    commandChecks: commandChecks,
    warnings: warnings,
    errors: errors
  }
}

// ------------------------------------------------------------------ internals

function _isHookKey(key) {
  for (var i = 0; i < HOOK_KEYS.length; i++) {
    if (HOOK_KEYS[i].toLowerCase() === String(key).toLowerCase()) return true
  }
  return false
}

// A hook value is a shell command line, not a path. Only an absolute first
// word can be checked against the filesystem; `wg set %i ...` and anything
// resolved through PATH is left alone, because guessing wrong here would warn
// about a profile that works.
function _commandPath(value) {
  var first = String(value || "").trim().split(/\s+/)[0] || ""
  return first.charAt(0) === "/" ? first : ""
}
