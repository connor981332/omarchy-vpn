// Tier 1: the .ovpn import decision, as pure text.
const { load } = require("./qmljs")
const t = require("./tap")
const C = load("backends/openvpn/Config.js")

// The real test profile from REQUIREMENTS.md, cert bodies elided. It is the
// worst case on purpose: inline blocks, an askpass file under /home, and
// script hooks.
const REAL_PROFILE = [
  "client",
  "dev tun",
  "proto udp",
  "remote vpn.example.com 1194",
  "resolv-retry infinite",
  "nobind",
  "remote-cert-tls server",
  "verify-x509-name pi-vpn_63519375 name",
  "cipher AES-256-CBC",
  "auth SHA256",
  "auth-nocache",
  "verb 3",
  "dhcp-option DNS 10.0.0.2",
  "script-security 2",
  "up /usr/bin/update-systemd-resolved",
  "down /usr/bin/update-systemd-resolved",
  "down-pre",
  "askpass /home/connor/.ovpn/password",
  "<ca>",
  "-----BEGIN CERTIFICATE-----",
  "MIIB",
  "-----END CERTIFICATE-----",
  "</ca>",
  "<key>",
  "-----BEGIN ENCRYPTED PRIVATE KEY-----",
  "MIHj",
  "-----END ENCRYPTED PRIVATE KEY-----",
  "</key>",
  "<tls-crypt>",
  "#",
  "# 2048 bit OpenVPN static key",
  "-----BEGIN OpenVPN Static key V1-----",
  "abc",
  "-----END OpenVPN Static key V1-----",
  "</tls-crypt>"
].join("\n")

t.suite("tokenizing")

t.test("splits on whitespace and honours quotes", () => {
  t.eq(C.tokenize("remote vpn.example.com 1194"), ["remote", "vpn.example.com", "1194"])
  t.eq(C.tokenize('ca "/path/with space/ca.crt"'), ["ca", "/path/with space/ca.crt"])
  t.eq(C.tokenize("   verb   3  "), ["verb", "3"])
  t.eq(C.tokenize(""), [])
})

t.suite("parsing")

t.test("keeps inline blocks out of the directive stream", () => {
  const parsed = C.parse(REAL_PROFILE)
  // "-----BEGIN CERTIFICATE-----" tokenizes perfectly well; if the parser did
  // not track blocks it would be treated as a directive.
  const keys = parsed.lines.filter((l) => l.kind === "directive").map((l) => l.key)
  t.ok(keys.indexOf("-----BEGIN") === -1, "PEM body is not a directive")
  t.ok(keys.indexOf("remote") !== -1)
})

t.test("captures inline block bodies", () => {
  const parsed = C.parse(REAL_PROFILE)
  t.ok(parsed.inline.ca.indexOf("BEGIN CERTIFICATE") !== -1)
  t.ok(parsed.inline["tls-crypt"].indexOf("Static key") !== -1)
})

t.test("a comment inside an inline block stays in the body", () => {
  // The real tls-crypt block opens with "#" lines. Treating them as comments
  // and dropping them would corrupt the key.
  const parsed = C.parse(REAL_PROFILE)
  t.ok(parsed.inline["tls-crypt"].indexOf("# 2048 bit") !== -1)
})

t.test("handles CRLF", () => {
  const parsed = C.parse("client\r\nremote host 1194\r\n")
  t.eq(C.endpoint(parsed), "host:1194")
  t.eq(parsed.lines.filter((l) => l.kind === "directive").length, 2)
})

t.test("comments and blank lines survive", () => {
  // Both comment markers, the blank line, and the empty line the trailing
  // newline produces — all non-directives, all re-emitted verbatim.
  const parsed = C.parse("# note\n\n;disabled\nclient\n")
  t.eq(parsed.lines.map((l) => l.kind),
       ["comment", "comment", "comment", "directive", "comment"])
})

t.suite("endpoint")

t.test("reads the first remote with a default port", () => {
  t.eq(C.endpoint(C.parse(REAL_PROFILE)), "vpn.example.com:1194")
  t.eq(C.endpoint(C.parse("remote host.example\n")), "host.example:1194")
  t.eq(C.endpoint(C.parse("remote a 1\nremote b 2\n")), "a:1")
  t.eq(C.endpoint(C.parse("client\n")), "")
})

t.suite("validation")

t.test("accepts the real profile", () => {
  t.eq(C.validate(C.parse(REAL_PROFILE)), [])
})

t.test("rejects a file that is not a client profile", () => {
  const errors = C.validate(C.parse("%PDF-1.4\nsome binary junk\n"))
  t.ok(errors.length > 0)
})

t.test("rejects a truncated inline block", () => {
  const errors = C.validate(C.parse("client\nremote a 1\n<ca>\n-----BEGIN"))
  t.ok(errors.join(" ").indexOf("truncated") !== -1, errors.join(" "))
})

t.test("rejects a profile with no remote", () => {
  const errors = C.validate(C.parse("client\ndev tun\n"))
  t.ok(errors.join(" ").indexOf("remote") !== -1)
})

t.suite("path resolution")

t.test("resolves a relative path against the folder the file came from", () => {
  // Not against the unit's working directory, which is where openvpn itself
  // would look and where the file certainly is not.
  t.eq(C.resolvePath("ca.crt", "/home/x/.ovpn"), "/home/x/.ovpn/ca.crt")
  t.eq(C.resolvePath("./certs/ca.crt", "/home/x/.ovpn"), "/home/x/.ovpn/certs/ca.crt")
  t.eq(C.resolvePath("../shared/ca.crt", "/home/x/.ovpn"), "/home/x/shared/ca.crt")
})

t.test("leaves an absolute path alone", () => {
  t.eq(C.resolvePath("/etc/ssl/ca.crt", "/home/x"), "/etc/ssl/ca.crt")
  t.eq(C.resolvePath("/a//b/./c", ""), "/a/b/c")
})

t.suite("import plan — ProtectHome")

const planned = C.plan(REAL_PROFILE, { name: "framework", sourceDir: "/home/connor/.ovpn" })

t.test("rewrites the askpass path out of /home", () => {
  // This is the exact failure the stock unit's ProtectHome=true causes.
  t.ok(planned.content.indexOf("/home/connor") === -1, "no home path survives:\n" + planned.content)
  t.ok(planned.content.indexOf("askpass framework.askpass") !== -1, planned.content)
})

t.test("collects the askpass file as an asset to copy", () => {
  t.eq(planned.assets, [{
    directive: "askpass",
    source: "/home/connor/.ovpn/password",
    target: "framework.askpass"
  }])
})

t.test("rewritten paths are bare filenames, not absolute", () => {
  // The unit's WorkingDirectory resolves them, so the destination directory
  // never has to be written into the config we generate.
  planned.assets.forEach((a) => t.ok(a.target.indexOf("/") === -1, a.target))
})

t.test("leaves every other directive byte-identical", () => {
  const before = REAL_PROFILE.split("\n").filter((l) => l.indexOf("askpass") === -1)
  const after = planned.content.split("\n").filter((l) => l.indexOf("askpass") === -1)
  t.eq(after.filter((l) => l !== ""), before.filter((l) => l !== ""))
})

t.test("keeps script-security and the up/down hooks", () => {
  // NetworkManager's importer drops these; that is a stated reason it was
  // rejected as the control plane, so it must not be reintroduced here.
  t.ok(planned.content.indexOf("script-security 2") !== -1)
  t.ok(planned.content.indexOf("up /usr/bin/update-systemd-resolved") !== -1)
})

t.test("reports no errors and no warnings for the real profile", () => {
  t.eq(planned.errors, [])
  t.eq(planned.warnings, [])
})

t.test("carries the endpoint through", () => {
  t.eq(planned.endpoint, "vpn.example.com:1194")
  t.eq(planned.protocol, "openvpn")
})

t.suite("import plan — other shapes")

t.test("a self-contained profile needs no assets", () => {
  const p = C.plan("client\nremote a 1194\n<ca>\nx\n</ca>\n", { name: "n", sourceDir: "/tmp" })
  t.eq(p.assets, [])
  t.ok(C.isSelfContained(p))
})

t.test("rewrites every file directive, resolving relative ones", () => {
  const p = C.plan([
    "client",
    "remote a 1194",
    "ca ca.crt",
    "cert client.crt",
    "key client.key",
    "tls-auth ta.key 1"
  ].join("\n"), { name: "work", sourceDir: "/home/x/vpn" })

  t.eq(p.assets.map((a) => a.source), [
    "/home/x/vpn/ca.crt",
    "/home/x/vpn/client.crt",
    "/home/x/vpn/client.key",
    "/home/x/vpn/ta.key"
  ])
  t.eq(p.assets.map((a) => a.target),
       ["work.ca", "work.cert", "work.key", "work.tls-auth"])
})

t.test("preserves the tls-auth key direction argument", () => {
  const p = C.plan("client\nremote a 1\ntls-auth ta.key 1\n", { name: "w", sourceDir: "/t" })
  t.ok(p.content.indexOf("tls-auth w.tls-auth 1") !== -1, p.content)
})

t.test("gives two of the same directive distinct filenames", () => {
  const p = C.plan("client\nremote a 1\nextra-certs one.pem\nextra-certs two.pem\n",
                   { name: "w", sourceDir: "/t" })
  t.eq(p.assets.map((a) => a.target), ["w.extra-certs", "w.extra-certs-2"])
})

t.test("handles a quoted path with spaces", () => {
  const p = C.plan('client\nremote a 1\nca "/home/x/my certs/ca.crt"\n', { name: "w", sourceDir: "/t" })
  t.eq(p.assets[0].source, "/home/x/my certs/ca.crt")
})

t.test("warns about a hook under /home instead of silently breaking", () => {
  const p = C.plan("client\nremote a 1\nup /home/x/bin/hook.sh\n", { name: "w", sourceDir: "/t" })
  t.eq(p.assets, [], "a script is not copied")
  t.ok(p.warnings.join(" ").indexOf("home directory") !== -1, p.warnings.join(" "))
  t.ok(p.content.indexOf("up /home/x/bin/hook.sh") !== -1, "the line is left as written")
})

t.test("does not warn about a hook outside /home", () => {
  const p = C.plan("client\nremote a 1\nup /usr/bin/hook\n", { name: "w", sourceDir: "/t" })
  t.eq(p.warnings, [])
})

t.test("warns when credentials would need a terminal", () => {
  const p = C.plan("client\nremote a 1\nauth-user-pass\n", { name: "w", sourceDir: "/t" })
  t.ok(p.warnings.join(" ").indexOf("terminal") !== -1, p.warnings.join(" "))
})

t.test("a file directive satisfied inline takes no asset", () => {
  const p = C.plan("client\nremote a 1\nca\n<ca>\nx\n</ca>\n", { name: "w", sourceDir: "/t" })
  t.eq(p.assets, [])
})

t.test("output always ends in exactly one newline", () => {
  const p = C.plan("client\nremote a 1\n\n\n", { name: "w", sourceDir: "/t" })
  t.ok(/[^\n]\n$/.test(p.content), JSON.stringify(p.content))
})

t.test("errors surface for a bad file rather than throwing", () => {
  const p = C.plan("not a config at all", { name: "w", sourceDir: "/t" })
  t.ok(p.errors.length > 0)
})

t.suite("hook targets")

// The hook that actually broke a working profile on 2026-08-27: the package
// providing it was removed, the config still parsed and imported cleanly, and
// the failure only appeared at connect time.
const WITH_HOOK = [
  "client",
  "dev tun",
  "remote vpn.example.com 1194",
  "script-security 2",
  "up /usr/bin/update-systemd-resolved",
  "down /usr/bin/update-systemd-resolved"
].join("\n")

t.test("hands absolute hook paths back for the caller to look for", () => {
  const p = C.plan(WITH_HOOK, { name: "h", sourceDir: "/t" })
  t.eq(p.hookTargets.length, 2)
  t.eq(p.hookTargets[0], "/usr/bin/update-systemd-resolved")
})

t.test("the hook itself is never rewritten", () => {
  // A hook lives wherever it was installed. Only data files move.
  const p = C.plan(WITH_HOOK, { name: "h", sourceDir: "/t" })
  t.ok(p.content.indexOf("up /usr/bin/update-systemd-resolved") !== -1)
  t.eq(p.assets.length, 0)
})

t.test("a hook under /home warns instead, and is not double-reported", () => {
  // That one is already a hard problem (ProtectHome) with its own message;
  // adding "not on this system" to it would be wrong as well as noisy.
  const p = C.plan("client\nremote h 1\nup /home/you/hook.sh", { name: "h", sourceDir: "/t" })
  t.eq(p.hookTargets.length, 0)
  t.ok(p.warnings.length === 1)
})

t.test("a bare command name is not treated as a path", () => {
  // `up systemd-resolved-helper` resolves through the daemon's own lookup,
  // not ours — checking it against the filesystem would warn wrongly.
  const p = C.plan("client\nremote h 1\nup some-helper", { name: "h", sourceDir: "/t" })
  t.eq(p.hookTargets.length, 0)
})

t.done()
