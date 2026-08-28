// Tier 1: the WireGuard config parser. Pure functions, no QML, no root.
const { load } = require("./qmljs")
const t = require("./tap")
const C = load("backends/wireguard/Config.js")

// A profile in the shape wg-quick actually ships: self-contained, keys inline,
// nothing beside it to copy. That is the whole reason this import path is
// simpler than the other backend's.
const PROFILE = [
  "[Interface]",
  "PrivateKey = 4Nl4tR1QaW5nS2V5RXhhbXBsZUJhc2U2NDA9",
  "Address = 10.6.0.2/32",
  "DNS = 10.6.0.1",
  "",
  "[Peer]",
  "PublicKey = cGVlclB1YmxpY0tleUV4YW1wbGVCYXNlNjQwPQ==",
  "AllowedIPs = 0.0.0.0/0, ::/0",
  "Endpoint = vpn.example.com:51820",
  "PersistentKeepalive = 25"
].join("\n")

t.suite("parsing")

t.test("reads the sections in order", () => {
  const p = C.parse(PROFILE)
  t.eq(p.sections.length, 2)
  t.eq(p.sections[0].name, "Interface")
  t.eq(p.sections[1].name, "Peer")
})

t.test("keys are case-insensitive, as wg-quick treats them", () => {
  const p = C.parse("[Interface]\nprivatekey = k\n[Peer]\nPUBLICKEY = q")
  t.eq(C.valueOf(p.sections[0], "PrivateKey"), "k")
  t.eq(C.valueOf(p.sections[1], "publickey"), "q")
})

t.test("a value containing '=' survives, since base64 keys end in one", () => {
  const p = C.parse("[Interface]\nPrivateKey = abc/def+ghi=\n[Peer]\nPublicKey = x")
  t.eq(C.valueOf(p.sections[0], "PrivateKey"), "abc/def+ghi=")
})

t.test("comments and CRLF do not derail it", () => {
  const p = C.parse("# lead\r\n[Interface]\r\nAddress = 10.0.0.1/32 # trailing\r\n")
  t.eq(C.valueOf(p.sections[0], "Address"), "10.0.0.1/32")
})

t.test("multiple peers are all kept", () => {
  const p = C.parse("[Interface]\nPrivateKey=k\n[Peer]\nPublicKey=a\n[Peer]\nPublicKey=b")
  t.eq(p.sections.length, 3)
})

t.suite("endpoint")

t.test("reads the endpoint from the first peer that names one", () => {
  t.eq(C.endpoint(C.parse(PROFILE)), "vpn.example.com:51820")
})

t.test("a peer with no endpoint is skipped rather than answered with blank", () => {
  // A config can legitimately carry dial-in peers before the one we call out to.
  const cfg = "[Interface]\nPrivateKey=k\n[Peer]\nPublicKey=a\n[Peer]\nPublicKey=b\nEndpoint=h:1"
  t.eq(C.endpoint(C.parse(cfg)), "h:1")
})

t.suite("validation")

t.test("accepts a real profile", () => {
  t.eq(C.validate(C.parse(PROFILE)).length, 0)
})

t.test("rejects a file that is not a WireGuard config at all", () => {
  const errs = C.validate(C.parse("client\ndev tun\nremote host 1194"))
  t.ok(errs.length > 0)
  t.ok(errs[0].indexOf("[Interface]") !== -1)
})

t.test("rejects a config with no peer", () => {
  const errs = C.validate(C.parse("[Interface]\nPrivateKey = k\nAddress = 10.0.0.1/32"))
  t.ok(errs.some(e => e.indexOf("[Peer]") !== -1))
})

t.test("rejects an interface with no private key", () => {
  // wg-quick fails on this too, but with a message about `wg setconf` that
  // says nothing about what the user should do.
  const errs = C.validate(C.parse("[Interface]\nAddress = 10.0.0.1/32\n[Peer]\nPublicKey = q"))
  t.ok(errs.some(e => e.indexOf("PrivateKey") !== -1))
})

t.suite("import plan")

t.test("a self-contained profile copies nothing and rewrites nothing", () => {
  const p = C.plan(PROFILE, { name: "wg0" })
  t.eq(p.assets.length, 0)
  t.eq(p.errors.length, 0)
  t.eq(p.warnings.length, 0)
  t.eq(p.protocol, "wireguard")
  t.eq(p.endpoint, "vpn.example.com:51820")
})

t.test("the config text is handed through intact", () => {
  // The user has to be able to recognise their own file afterwards.
  const p = C.plan(PROFILE, { name: "wg0" })
  t.ok(p.content.indexOf("PersistentKeepalive = 25") !== -1)
  t.ok(p.content.indexOf("[Peer]") !== -1)
})

t.test("output always ends in exactly one newline", () => {
  t.ok(/[^\n]\n$/.test(C.plan(PROFILE + "\n\n\n", { name: "wg0" }).content))
})

t.test("CRLF is normalised on the way in", () => {
  const p = C.plan(PROFILE.replace(/\n/g, "\r\n"), { name: "wg0" })
  t.ok(p.content.indexOf("\r") === -1)
})

t.test("a name longer than IFNAMSIZ is an error, not a surprise later", () => {
  // 16 characters. wg-quick refuses it, so the profile would install and then
  // never start — which is the failure mode this whole phase exists to avoid.
  const p = C.plan(PROFILE, { name: "abcdefghijklmnop" })
  t.ok(p.errors.length > 0)
  t.ok(p.errors[0].indexOf("15") !== -1)
})

t.test("exactly 15 characters is accepted", () => {
  t.eq(C.plan(PROFILE, { name: "abcdefghijklmno" }).errors.length, 0)
})

t.suite("import plan — warnings")

t.test("warns when the interface has no address", () => {
  const cfg = "[Interface]\nPrivateKey = k\n[Peer]\nPublicKey = q\nEndpoint = h:1"
  const p = C.plan(cfg, { name: "wg0" })
  t.eq(p.errors.length, 0, "still importable")
  t.ok(p.warnings.some(w => w.indexOf("Address") !== -1))
})

t.test("warns when no peer can be dialled out to", () => {
  const cfg = "[Interface]\nPrivateKey = k\nAddress = 10.0.0.1/32\n[Peer]\nPublicKey = q"
  t.ok(C.plan(cfg, { name: "wg0" }).warnings.some(w => w.indexOf("Endpoint") !== -1))
})

t.suite("hooks")

t.test("an absolute hook command is handed back to be looked for", () => {
  const cfg = PROFILE + "\nPostUp = /usr/bin/nft -f /etc/wg.rules"
  t.eq(C.plan(cfg, { name: "wg0" }).hookTargets[0], "/usr/bin/nft")
})

t.test("a hook under /home warns and is not reported as missing", () => {
  const cfg = PROFILE + "\nPostUp = /home/you/setup.sh"
  const p = C.plan(cfg, { name: "wg0" })
  t.eq(p.hookTargets.length, 0)
  t.ok(p.warnings.some(w => w.indexOf("/home") !== -1))
})

t.test("a command resolved through PATH is left alone", () => {
  // `PostUp = resolvectl dns %i 10.0.0.1` is normal and works. Checking it
  // against the filesystem would warn about a profile that is fine.
  const p = C.plan(PROFILE + "\nPostUp = resolvectl dns %i 10.0.0.1", { name: "wg0" })
  t.eq(p.hookTargets.length, 0)
  t.eq(p.warnings.length, 0)
})

t.test("every hook key is recognised", () => {
  const cfg = PROFILE
    + "\nPreUp = /a/one\nPostUp = /a/two\nPreDown = /a/three\nPostDown = /a/four"
  t.eq(C.plan(cfg, { name: "wg0" }).hookTargets.length, 4)
})

t.done()
