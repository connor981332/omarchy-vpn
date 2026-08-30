.pragma library

// Reading and rewriting an OpenVPN client config.
//
// This file exists because the stock `openvpn-client@.service` sets
// `ProtectHome=true`: the unit sees an empty /home, so any profile that
// references a key, a cert, or an askpass file under the user's home directory
// starts and then dies. Importing therefore cannot be a copy — every
// file-valued directive has to be collected and re-pointed at files that live
// beside the config in the unit's own WorkingDirectory.
//
// Everything here is pure text in, text out; test/config.test.js covers it.

// Directives whose first argument names a file. The number is how many
// arguments follow the filename and must be preserved — `tls-auth ta.key 1`
// carries a key direction, everything else carries nothing.
// Matches `credential_ext()` in bin/install-profile. The two have to agree:
// this file writes the reference into the config, that one writes the file.
var CREDENTIAL_EXT = "auth"

var FILE_DIRECTIVES = {
  "ca": 0,
  "cert": 0,
  "key": 0,
  "dh": 0,
  "pkcs12": 0,
  "secret": 1,
  "tls-auth": 1,
  "tls-crypt": 0,
  "tls-crypt-v2": 1,
  "crl-verify": 1,
  "askpass": 0,
  "auth-user-pass": 0,
  "extra-certs": 0
}

// Directives an imported profile may not carry, and the reason each one is
// refused. The unit runs `openvpn` as root — `openvpn-client@.service` sets no
// `User=` — so every one of these is a way for the author of a downloaded
// profile to choose what root does the moment the user starts the tunnel.
//
// They are REMOVED from the installed config, not warned about: a warning
// leaves the line in place, and the user approving a polkit prompt labelled
// "install a VPN profile" is not approving a root shell. bin/install-profile
// enforces the same list a second time on the file it is about to install,
// because everything up to that point runs as the user and is therefore
// input, not a check.
//
//   run   — root executes the named command line (needs `script-security 2`,
//           which is why arming it is on the list too)
//   load  — root dlopen()s a shared object, needing no script-security at all
//   arm   — turns the `run` directives on
//   write — root writes a file at a path the profile chooses. ProtectSystem=
//           true leaves /etc writable, so this reaches /etc/systemd/system.
var UNSAFE_DIRECTIVES = {
  "up": "run",
  "down": "run",
  "route-up": "run",
  "route-pre-down": "run",
  "ipchange": "run",
  "client-connect": "run",
  "client-disconnect": "run",
  "learn-address": "run",
  "tls-verify": "run",
  "auth-user-pass-verify": "run",
  "tls-crypt-v2-verify": "run",
  "plugin": "load",
  "script-security": "arm",
  "log": "write",
  "log-append": "write",
  "status": "write",
  "writepid": "write"
}

// Deliberately NOT on that list: `user`, `group` and `chroot` drop privilege
// rather than take it, and stripping them would make an imported profile run
// with more privilege than its author asked for.

// Splits a config line the way OpenVPN's own parser does: whitespace-separated,
// with double quotes grouping a value that contains spaces.
function tokenize(line) {
  var tokens = []
  var current = ""
  var quoted = false
  var started = false
  for (var i = 0; i < line.length; i++) {
    var ch = line[i]
    if (ch === '"') {
      quoted = !quoted
      started = true
    } else if (!quoted && /\s/.test(ch)) {
      if (started) { tokens.push(current); current = ""; started = false }
    } else {
      current += ch
      started = true
    }
  }
  if (started) tokens.push(current)
  return tokens
}

// Parses into a line list that can be rewritten and re-emitted verbatim, so an
// import never reorders or drops a directive it did not understand.
//
// Inline blocks (<ca>…</ca>) are marked so nothing inside them is mistaken for
// a directive — a PEM body contains lines that tokenize just fine.
function parse(text) {
  var raw = String(text || "").replace(/\r\n/g, "\n").split("\n")
  var lines = []
  var inline = {}
  var openTag = ""
  var buffer = []

  for (var i = 0; i < raw.length; i++) {
    var line = raw[i]
    var trimmed = line.trim()

    if (openTag !== "") {
      if (trimmed === "</" + openTag + ">") {
        inline[openTag] = buffer.join("\n")
        lines.push({ kind: "inline-end", raw: line, tag: openTag })
        openTag = ""
        buffer = []
      } else {
        buffer.push(line)
        lines.push({ kind: "inline-body", raw: line, tag: openTag })
      }
      continue
    }

    var open = trimmed.match(/^<([A-Za-z0-9_-]+)>$/)
    if (open) {
      openTag = open[1]
      buffer = []
      lines.push({ kind: "inline-start", raw: line, tag: openTag })
      continue
    }

    if (trimmed === "" || trimmed[0] === "#" || trimmed[0] === ";") {
      lines.push({ kind: "comment", raw: line })
      continue
    }

    // OpenVPN accepts a directive in a config file with or without the `--`
    // it would carry on the command line, so `--up` and `up` are the same
    // option and have to be the same key here. Missing this would leave the
    // spelling that bypasses UNSAFE_DIRECTIVES.
    var tokens = tokenize(trimmed)
    var key = String(tokens[0] || "").replace(/^--/, "")
    lines.push({ kind: "directive", raw: line, key: key, args: tokens.slice(1) })
  }

  // An unterminated block is a truncated file, not a config.
  if (openTag !== "") lines.push({ kind: "unterminated", raw: "", tag: openTag })

  return { lines: lines, inline: inline }
}

function directives(parsed, key) {
  var out = []
  for (var i = 0; i < parsed.lines.length; i++) {
    var line = parsed.lines[i]
    if (line.kind === "directive" && line.key === key) out.push(line)
  }
  return out
}

// "host:port" for the panel's endpoint row. First `remote` wins, which is what
// OpenVPN does absent `remote-random`.
function endpoint(parsed) {
  var remotes = directives(parsed, "remote")
  if (remotes.length === 0) return ""
  var args = remotes[0].args
  var host = args[0] || ""
  var port = args[1] || "1194"
  return host === "" ? "" : host + ":" + port
}

// Which transport the tunnel dials out on, for the kill switch's endpoint
// rule — the one thing that must stay permitted while everything else is
// dropped. `proto` sets it globally; a third argument on `remote` overrides it
// for that server. OpenVPN's own default is udp.
//
// The `-client`/`-server` suffixes are the same wire protocol: `udp4`, `udp6`
// and `tcp-client` all reduce to the two the firewall understands.
function endpointProto(parsed) {
  var value = ""
  var remotes = directives(parsed, "remote")
  if (remotes.length > 0 && remotes[0].args.length > 2) value = remotes[0].args[2]
  if (value === "") {
    var protos = directives(parsed, "proto")
    if (protos.length > 0) value = protos[0].args[0] || ""
  }
  return /^tcp/i.test(value) ? "tcp" : "udp"
}

function isClientConfig(parsed) {
  return directives(parsed, "client").length > 0 ||
         directives(parsed, "tls-client").length > 0 ||
         directives(parsed, "remote").length > 0
}

// A parse-level sanity check, so a PDF renamed to .ovpn is rejected with a
// sentence rather than installed and left to fail inside systemd.
function validate(parsed) {
  var errors = []
  for (var i = 0; i < parsed.lines.length; i++) {
    if (parsed.lines[i].kind === "unterminated") {
      errors.push("The <" + parsed.lines[i].tag + "> block is never closed — the file looks truncated.")
    }
  }
  if (!isClientConfig(parsed)) {
    errors.push("This does not look like an OpenVPN client profile (no `client` or `remote` line).")
  }
  if (directives(parsed, "remote").length === 0) {
    errors.push("The profile has no `remote` server to connect to.")
  }
  return errors
}

// Where a path in the config actually points. OpenVPN resolves a relative path
// against its working directory, which for the stock unit is
// /etc/openvpn/client — not the folder the user picked the file from. So a
// relative path has to be resolved against the source folder at import time or
// it silently means something else afterwards.
function resolvePath(path, sourceDir) {
  var value = String(path || "")
  if (value === "") return ""
  if (value[0] === "/") return normalizePath(value)
  var base = String(sourceDir || "").replace(/\/+$/, "")
  return normalizePath(base + "/" + value)
}

function normalizePath(path) {
  var parts = String(path).split("/")
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    if (part === "" || part === ".") continue
    if (part === "..") { out.pop(); continue }
    out.push(part)
  }
  return "/" + out.join("/")
}

// The whole import, as data. Returns the config text to write, the side files
// to copy next to it, and anything the user should be told — without touching
// the filesystem, so the decision is testable and the privileged step stays a
// dumb copier.
//
// Rewritten paths are bare filenames on purpose: the unit's WorkingDirectory is
// the profile directory, so a filename resolves there, and no destination path
// has to be baked into the config we generate.
function plan(text, options) {
  var opts = options || {}
  var name = String(opts.name || "profile")
  var sourceDir = String(opts.sourceDir || "")

  var parsed = parse(text)
  var errors = validate(parsed)
  var warnings = []
  var assets = []
  // Every UNSAFE_DIRECTIVES line taken out, verbatim, so the panel can show
  // the user exactly what was dropped rather than a count.
  var removed = []
  var seen = {}
  var needsCredentials = false

  var out = []
  for (var i = 0; i < parsed.lines.length; i++) {
    var line = parsed.lines[i]

    if (line.kind !== "directive") {
      if (line.kind !== "unterminated") out.push(line.raw)
      continue
    }

    if (UNSAFE_DIRECTIVES.hasOwnProperty(line.key)) {
      removed.push({ key: line.key, reason: UNSAFE_DIRECTIVES[line.key], raw: line.raw.trim() })
      continue
    }

    if (!FILE_DIRECTIVES.hasOwnProperty(line.key)) {
      out.push(line.raw)
      continue
    }

    // The directive can also be satisfied inline (<ca>…</ca>), in which case
    // it takes no argument and there is nothing to copy.
    if (line.args.length === 0) {
      // `auth-user-pass` with no argument means "prompt on the terminal", and
      // the service has no terminal — so the tunnel would start and hang.
      // Point it at the credential file the privileged helper writes, and tell
      // the caller the profile is not usable until that file exists. The name
      // must match the helper's `<name>.auth`; it is a bare filename because
      // the unit's WorkingDirectory is the profile directory.
      if (line.key === "auth-user-pass") {
        needsCredentials = true
        out.push("auth-user-pass " + name + "." + CREDENTIAL_EXT)
        continue
      }
      out.push(line.raw)
      continue
    }

    var source = resolvePath(line.args[0], sourceDir)
    var filename = assetName(name, line.key, seen)
    assets.push({ directive: line.key, source: source, target: filename })

    var rewritten = [line.key, filename].concat(line.args.slice(1))
    out.push(rewritten.join(" "))
  }

  if (removed.length > 0) warnings.push(removalWarning(removed))

  return {
    name: name,
    protocol: "openvpn",
    endpoint: endpoint(parsed),
    endpointProto: endpointProto(parsed),
    content: out.join("\n").replace(/\n+$/, "") + "\n",
    assets: assets,
    // The lines that were taken out. The panel shows them; nothing installs them.
    removed: removed,
    // True when the profile asks for a username and password interactively.
    // The caller has to collect them and hand them to the helper; until then
    // the profile is installed and will not start.
    needsCredentials: needsCredentials,
    warnings: warnings,
    errors: errors
  }
}

// One sentence for the whole set, naming the lines rather than counting them:
// a profile that quietly loses its DNS hook and says only "1 line removed" is
// a support question, and the user needs enough to go and ask their provider.
function removalWarning(removed) {
  var quoted = []
  for (var i = 0; i < removed.length; i++) quoted.push("`" + removed[i].raw + "`")
  var noun = removed.length === 1 ? "one line" : quoted.length + " lines"
  return "Removed " + noun + " that would have let this profile run commands or "
    + "write files as root when the tunnel starts: " + quoted.join(", ")
    + ". The tunnel itself is unaffected; only a profile relying on its own "
    + "scripts for DNS or routing will notice."
}

// `<name>.<directive>`, with a counter when one directive appears twice
// (`extra-certs` legitimately can), so two assets never collide on disk.
function assetName(name, directive, seen) {
  var base = name + "." + directive
  seen[directive] = (seen[directive] || 0) + 1
  return seen[directive] === 1 ? base : base + "-" + seen[directive]
}

// True when the profile carries everything it needs in the file itself, which
// is the common case for a downloaded .ovpn and means the import needs no
// side files at all.
function isSelfContained(planned) {
  return planned.assets.length === 0
}
