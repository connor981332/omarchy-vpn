// Tier 1: pure functions, no QML, no root, no network.
const { load } = require("./qmljs")
const t = require("./tap")
const M = load("Model.js")

t.suite("unit name escaping")

// The values on the right are what `systemd-escape` actually printed on an
// Arch box; test/harness/escape.test.sh re-derives them from the binary so
// this table cannot silently drift from systemd.
t.test("escapes exactly like systemd-escape", () => {
  t.eq(M.escapeUnitName("work:vpn"), "work:vpn", "colon is a valid char")
  t.eq(M.escapeUnitName("my vpn"), "my\\x20vpn")
  t.eq(M.escapeUnitName("a/b"), "a-b", "slash folds to dash")
  t.eq(M.escapeUnitName(".hidden"), "\\x2ehidden", "leading dot")
  t.eq(M.escapeUnitName("ok-name_1.2"), "ok\\x2dname_1.2", "dash itself escapes")
  t.eq(M.escapeUnitName("a@b"), "a\\x40b")
  t.eq(M.escapeUnitName("a\\b"), "a\\x5cb")
  t.eq(M.escapeUnitName("ünïcode"), "\\xc3\\xbcn\\xc3\\xafcode", "utf-8 per byte")
})

t.test("interior dot is left alone", () => {
  t.eq(M.escapeUnitName("a.b"), "a.b")
})

t.test("empty name yields empty instance", () => {
  t.eq(M.escapeUnitName(""), "")
  t.eq(M.escapeUnitName(null), "")
})

t.test("round-trips through unescape", () => {
  const names = ["work:vpn", "my vpn", ".hidden", "ok-name_1.2", "a@b", "ünïcode", "plain"]
  names.forEach((name) => t.eq(M.unescapeUnitName(M.escapeUnitName(name)), name, name))
})

t.suite("unit instance names must not be escaped")

t.test("a sanitized name never needs escaping", () => {
  // The stock units expand %i — the RAW instance — into a filename, so the
  // instance has to equal the file stem. This is the property that makes it
  // safe to use the profile name literally as the instance.
  const names = ["work", "work-vpn", "framework-omarchy", "a.b", "A_1", "vpn.2024"]
  names.forEach((n) => {
    t.eq(M.sanitizeProfileName(n), n, n + " survives sanitizing unchanged")
    t.eq(M.isLiteralUnitInstance(n), true, n + " is usable as an instance as-is")
  })
})

t.test("everything sanitizeProfileName can emit is literal-safe", () => {
  // Fuzz the sanitizer's output rather than trusting the character class by
  // eye: if sanitizing is ever loosened, this fails instead of shipping a unit
  // that points at a file that does not exist.
  const inputs = ["My Work VPN", "a/b/c", "../etc/passwd", "ünïcode vpn", "a@b",
                  "tab\tsep", "%pct%", "quote-dq", "..hidden", "-lead", "trail-",
                  "a---b", "work:vpn", "x".repeat(200)]
  inputs.forEach((raw) => {
    const clean = M.sanitizeProfileName(raw)
    if (clean === "") return
    t.eq(M.isLiteralUnitInstance(clean), true,
         JSON.stringify(raw) + " -> " + JSON.stringify(clean) + " must be literal-safe")
  })
})

t.test("the guard rejects the names that really would break", () => {
  // These never survive sanitizing, but the guard has to catch them anyway —
  // it is the backstop if sanitizing is ever loosened.
  t.eq(M.isLiteralUnitInstance("work vpn"), false, "space")
  t.eq(M.isLiteralUnitInstance("a/b"), false, "slash")
  t.eq(M.isLiteralUnitInstance(".hidden"), false, "leading dot")
  t.eq(M.isLiteralUnitInstance("ünïcode"), false, "non-ascii")
  t.eq(M.isLiteralUnitInstance(""), false, "empty")
})

t.test("a literal hyphen is fine, even though systemd-escape would escape it", () => {
  // The exact confusion that caused the bug: systemd-escape turns "-" into
  // "\\x2d" because "-" is its stand-in for "/", but "-" is legal in an
  // instance name as written.
  t.eq(M.escapeUnitName("work-vpn"), "work\\x2dvpn", "the escaper still escapes it")
  t.eq(M.isLiteralUnitInstance("work-vpn"), true, "but it needs no escaping to be used")
})

t.suite("profile names")

t.test("derives a name from a chooser path", () => {
  t.eq(M.profileNameFromPath("/home/x/.ovpn/framework-omarchy.ovpn"), "framework-omarchy")
  t.eq(M.profileNameFromPath("/tmp/My Work VPN.ovpn"), "My-Work-VPN")
  t.eq(M.profileNameFromPath("client.conf"), "client")
})

t.test("refuses to build a traversing filename", () => {
  // The name becomes a path component in a system directory, so this is the
  // test that matters most in the file.
  t.eq(M.profileNameFromPath("/tmp/../../etc/passwd"), "passwd")
  t.eq(M.sanitizeProfileName("../../etc/passwd"), "etc-passwd")
  t.eq(M.sanitizeProfileName("/etc/shadow"), "etc-shadow")
  t.eq(M.sanitizeProfileName("..").indexOf(".."), -1)
})

t.test("strips a trailing .conf so names do not double up", () => {
  t.eq(M.sanitizeProfileName("work.conf"), "work")
})

t.test("caps length", () => {
  t.ok(M.sanitizeProfileName("x".repeat(200)).length === 64)
})

t.suite("tunnel shaping")

const tun = (name, protocol, state) => M.makeTunnel({ name, protocol, state })

t.test("makeTunnel fills every field", () => {
  const x = M.makeTunnel({ name: "work", protocol: "wireguard" })
  t.eq(x.id, "wireguard:work")
  t.eq(x.state, "down")
  t.eq(x.device, "")
  t.eq(x.telemetry.rxBytes, 0)
})

t.test("sorts active first, then protocol, then name", () => {
  const list = [
    tun("zeta", "alpha", "down"),
    tun("beta", "alpha", "down"),
    tun("gamma", "beta", "up")
  ]
  t.eq(M.sortTunnels(list).map((x) => x.name), ["gamma", "beta", "zeta"])
})

t.test("sortTunnels does not mutate its input", () => {
  const list = [tun("b", "p", "down"), tun("a", "p", "up")]
  M.sortTunnels(list)
  t.eq(list.map((x) => x.name), ["b", "a"])
})

t.test("replaceTunnel returns a new array and appends unknown ids", () => {
  const list = [tun("a", "p", "down")]
  const next = M.replaceTunnel(list, tun("a", "p", "up"))
  t.ok(next !== list, "new array")
  t.eq(next.length, 1)
  t.eq(next[0].state, "up")
  t.eq(M.replaceTunnel(list, tun("b", "p", "down")).length, 2)
})

t.test("groups and finds", () => {
  const list = [tun("a", "p", "up"), tun("b", "q", "down")]
  t.eq(M.groupByProtocol(list, "q").map((x) => x.name), ["b"])
  t.eq(M.findTunnel(list, "p:a").name, "a")
  t.eq(M.findTunnel(list, "nope"), null)
  t.eq(M.activeTunnels(list).map((x) => x.name), ["a"])
})

t.suite("state")

t.test("maps systemctl is-active vocabulary", () => {
  t.eq(M.stateFromIsActive("active\n"), "up")
  t.eq(M.stateFromIsActive("activating"), "activating")
  t.eq(M.stateFromIsActive("deactivating"), "deactivating")
  t.eq(M.stateFromIsActive("failed"), "failed")
  t.eq(M.stateFromIsActive("inactive"), "down")
  t.eq(M.stateFromIsActive(""), "down", "unknown unit prints nothing on stdout")
})

t.test("is-active on several units answers per line", () => {
  t.eq(M.stateFromIsActive("active\ninactive\n"), "up")
})

t.test("parses systemctl show blocks keyed by the Id systemd reports", () => {
  const out = M.parseShowBlocks([
    "Id=openvpn-client@work.service",
    "ActiveState=active",
    "ActiveEnterTimestampMonotonic=25501695",
    "",
    "Id=openvpn-client@home.service",
    "ActiveState=inactive",
    "ActiveEnterTimestampMonotonic=0"
  ].join("\n"))
  t.eq(Object.keys(out).sort(),
       ["openvpn-client@home.service", "openvpn-client@work.service"])
  t.eq(out["openvpn-client@work.service"].ActiveState, "active")
})

t.test("a unit systemd declines to describe does not shift its neighbours", () => {
  // The whole reason for keying on Id rather than argument position.
  const out = M.parseShowBlocks("Id=b.service\nActiveState=active\n")
  t.eq(Object.keys(out), ["b.service"])
  t.eq(out["a.service"], undefined)
})

t.test("show parsing survives values containing '='", () => {
  const out = M.parseShowBlocks("Id=a.service\nExecStart=/usr/bin/x --config=y\n")
  t.eq(out["a.service"].ExecStart, "/usr/bin/x --config=y")
})

t.test("reads uptime and turns a monotonic stamp into a duration", () => {
  t.near(M.parseUptimeSeconds("732830.12 5812345.67"), 732830.12, 1e-6)
  t.eq(M.parseUptimeSeconds(""), 0)
  // 25501695us is 25.5s after boot, so a machine up 732830s has held it that
  // long minus 25.5s.
  t.near(M.activeSeconds("25501695", 732830.12), 732804.618, 0.01)
})

t.test("a unit that never went active has no duration", () => {
  // systemd writes 0 for "never entered", which is not "entered at boot".
  t.eq(M.activeSeconds("0", 732830), 0)
  t.eq(M.activeSeconds("", 732830), 0)
  t.eq(M.activeSeconds("999999999999", 10), 0, "stamp in the future clamps to 0")
})

t.test("a unit claiming active with no device is still activating", () => {
  // The half-up tunnel: this is the silent failure the panel must not report
  // as connected.
  t.eq(M.reconcileState("up", false), "activating")
  t.eq(M.reconcileState("up", true), "up")
  t.eq(M.reconcileState("failed", false), "failed")
})

t.suite("telemetry")

t.test("parses a sysfs counter", () => {
  t.eq(M.parseCounter("123456\n"), 123456)
  t.eq(M.parseCounter(""), 0)
  t.eq(M.parseCounter("garbage"), 0)
  t.eq(M.parseCounter("-5"), 0)
})

t.test("computes a rate", () => {
  t.near(M.rate(1000, 3000, 1000, 3000), 1000, 1e-6, "2000 bytes over 2s")
})

t.test("rate guards the three ways sampling goes wrong", () => {
  t.eq(M.rate(0, 100, 0, 1000), 0, "no previous sample")
  t.eq(M.rate(0, 100, 1000, 1000), 0, "clock did not move")
  t.eq(M.rate(9000, 10, 1000, 2000), 0, "counter reset when the device was recreated")
})

t.test("detects a default route via the tunnel", () => {
  const routes = JSON.stringify([
    { dst: "default", dev: "wlan0", gateway: "192.168.1.1" },
    { dst: "0.0.0.0/1", dev: "tun0" },
    { dst: "128.0.0.0/1", dev: "tun0" }
  ])
  t.eq(M.defaultRouteVia(routes, "tun0"), true, "the split default a full-tunnel VPN installs")
  t.eq(M.defaultRouteVia(routes, "wlan0"), true)
  t.eq(M.defaultRouteVia(routes, "tun1"), false)
  t.eq(M.defaultRouteVia(routes, ""), false)
})

t.test("a tunnel that only routes a subnet is not the default route", () => {
  const routes = JSON.stringify([
    { dst: "default", dev: "wlan0" },
    { dst: "10.0.0.0/24", dev: "tun0" }
  ])
  t.eq(M.defaultRouteVia(routes, "tun0"), false, "split tunnel, not full")
})

t.test("survives malformed ip output", () => {
  t.eq(M.defaultRouteVia("not json", "tun0"), false)
  t.eq(M.parseAddresses(""), [])
  t.eq(M.parseLinkDevices("{"), [])
})

t.test("parses addresses and skips link-local", () => {
  const addr = JSON.stringify([{
    ifname: "tun0",
    addr_info: [
      { local: "10.8.0.2", prefixlen: 24, scope: "global" },
      { local: "fe80::1", prefixlen: 64, scope: "link" }
    ]
  }])
  t.eq(M.parseAddresses(addr), ["10.8.0.2/24"])
})

t.test("parses resolvectl DNS servers including wrapped lines", () => {
  const output = [
    "Link 12 (tun0)",
    "    Current Scopes: DNS",
    "         Protocols: -DefaultRoute",
    "  Current DNS Server: 10.0.0.2",
    "         DNS Servers: 10.0.0.2 10.0.0.3",
    "                      10.0.0.4",
    "          DNS Domain: ~."
  ].join("\n")
  t.eq(M.parseResolvers(output), ["10.0.0.2", "10.0.0.3", "10.0.0.4"])
})

t.test("reports no resolvers when the tunnel pushed none", () => {
  t.eq(M.parseResolvers("Link 12 (tun0)\n  Current Scopes: none\n"), [])
})

t.test("an unrelated tunnel device that already existed is not mistaken for ours", () => {
  // Another VPN client's tun0 was already up when our unit started. This is
  // the property that makes Service._currentDevices() have to snapshot every
  // netdev rather than only the ones this widget has claimed.
  t.eq(M.newDevice(["lo", "wlan0", "tun0"], ["lo", "wlan0", "tun0", "tun1"], ["tun", "tap"]), "tun1")
  t.eq(M.newDevice(["lo", "wlan0", "tun0"], ["lo", "wlan0", "tun0"], ["tun", "tap"]), "",
       "nothing new, even though a tun device exists")
})

t.test("spots the device that appeared while the unit started", () => {
  t.eq(M.newDevice(["lo", "wlan0"], ["lo", "wlan0", "tun0"]), "tun0")
  t.eq(M.newDevice(["lo", "wlan0"], ["lo", "wlan0", "wg0"]), "wg0")
  t.eq(M.newDevice(["lo"], ["lo", "docker0"]), "", "not a tunnel device")
  t.eq(M.newDevice(["lo", "tun0"], ["lo", "tun0"]), "", "nothing new")
})

t.suite("formatting")

t.test("formats bytes", () => {
  t.eq(M.formatBytes(0), "0 B")
  t.eq(M.formatBytes(512), "512 B")
  t.eq(M.formatBytes(1024), "1.0 KB")
  t.eq(M.formatBytes(1536), "1.5 KB")
  t.eq(M.formatBytes(1024 * 1024 * 20), "20 MB")
  t.eq(M.formatBytes(1024 * 1024 * 1024 * 3.5), "3.5 GB")
})

t.test("formats rate", () => {
  t.eq(M.formatRate(2048), "2.0 KB/s")
  t.eq(M.formatRate(0), "0 B/s")
})

t.test("formats duration", () => {
  t.eq(M.formatDuration(5), "5s")
  t.eq(M.formatDuration(65), "1m 05s")
  t.eq(M.formatDuration(3700), "1h 01m")
  t.eq(M.formatDuration(90000), "1d 1h")
  t.eq(M.formatDuration(-5), "0s")
})

t.test("status line", () => {
  t.eq(M.statusText([]), "No VPN profiles configured")
  t.eq(M.statusText([tun("a", "p", "down")]), "Not connected")
  t.eq(M.statusText([tun("a", "p", "up")]), "Connected to a")
  t.eq(M.statusText([tun("a", "p", "up"), tun("b", "p", "up")]), "Connected to 2 VPNs")
  t.eq(M.statusText([tun("a", "p", "down")], "a"), "Connecting to a…")
})

t.test("status line never mentions a missing dependency", () => {
  // Lazy degradation: a WireGuard-only user must not be told about another
  // protocol's missing binary in the summary line.
  t.ok(M.statusText([]).toLowerCase().indexOf("install") === -1)
})

t.test("cleans systemctl noise off an error", () => {
  t.eq(M.cleanError("Error: something broke"), "something broke")
  t.eq(
    M.cleanError("Failed to start openvpn-client@x.service: Unit not found."),
    "Unit not found."
  )
  t.eq(M.cleanError("  multi\n  line\n  text "), "multi line text")
  t.ok(M.cleanError("x".repeat(300)).length <= 140)
})

t.done()
