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

// Directives that name an executable rather than a data file. These are NOT
// rewritten — a hook lives wherever the user installed it — but one under
// /home cannot work inside the unit, and saying so at import time is the
// difference between a clear warning and a tunnel that mysteriously has no DNS.
var SCRIPT_DIRECTIVES = ["up", "down", "route-up", "route-pre-down",
                         "ipchange", "client-connect", "client-disconnect",
                         "learn-address", "tls-verify", "auth-user-pass-verify"]

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

    var tokens = tokenize(trimmed)
    lines.push({ kind: "directive", raw: line, key: tokens[0], args: tokens.slice(1) })
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
  var seen = {}

  var out = []
  for (var i = 0; i < parsed.lines.length; i++) {
    var line = parsed.lines[i]

    if (line.kind !== "directive") {
      if (line.kind !== "unterminated") out.push(line.raw)
      continue
    }

    if (SCRIPT_DIRECTIVES.indexOf(line.key) !== -1) {
      var target = line.args[0] || ""
      if (target.indexOf("/home/") === 0 || target.indexOf("~") === 0) {
        warnings.push("`" + line.key + " " + target + "` points into your home directory, "
          + "which the VPN service cannot read. Move the script somewhere outside /home.")
      }
      out.push(line.raw)
      continue
    }

    if (!FILE_DIRECTIVES.hasOwnProperty(line.key)) {
      out.push(line.raw)
      continue
    }

    // The directive can also be satisfied inline (<ca>…</ca>), in which case
    // it takes no argument and there is nothing to copy.
    if (line.args.length === 0) {
      if (line.key === "auth-user-pass") {
        warnings.push("`auth-user-pass` has no file, so OpenVPN would prompt for a username "
          + "and password on a terminal the service does not have. The tunnel will not start "
          + "until you add a credentials file.")
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

  return {
    name: name,
    protocol: "openvpn",
    endpoint: endpoint(parsed),
    content: out.join("\n").replace(/\n+$/, "") + "\n",
    assets: assets,
    warnings: warnings,
    errors: errors
  }
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
