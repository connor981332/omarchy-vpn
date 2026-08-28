# connor.vpn — Architecture

How this plugin is actually built, and why. Written for someone auditing it
before installing it: Omarchy plugins run unsandboxed, in the shell process,
with your permissions, so "read the code" is the only real security model and
this document exists to make that quicker.

`README.md` is for users. `FUTURE_WORK.md` is what was deliberately left out.
`CLAUDE.md` is the working notes — environment facts that cost a debugging
session to establish, kept because they are easy to rediscover the hard way.

---

## The shape in one paragraph

Two planes. The **control plane** starts and stops stock systemd template units
that ship with the `openvpn` and `wireguard-tools` packages. The **telemetry
plane** reads the kernel. Neither installs a daemon, a unit file, or a polkit
policy. Privileged work is three narrow operations, each authorized per
invocation through the polkit agent Omarchy already runs, and the widget holds
no privilege between them.

---

## What was rejected, and what changed on contact with reality

### Rejected: NetworkManager as the control plane

The starter code drove `nmcli`. NM is already running on every Omarchy machine
and would have cost nothing to call. It was rejected on capability, not
overhead:

- NM's OpenVPN importer **drops `script-security` and `up`/`down` hooks**,
  silently changing the behaviour of a working profile.
- No kill switch. Putting nftables beside NM's routing means two owners of the
  route table.
- No per-app split tunnelling — NM can only express route-based splits.
- No tunnel telemetry: no byte counters, no handshake age, no cipher.
- OpenVPN support needs `networkmanager-openvpn`, which is not in Omarchy's
  base packages — so the "free" option was not free either.

The ban is mechanically enforced: `test/architecture.test.sh` fails if the
string `nmcli` or `NetworkManager` appears in any runtime file.

### Three places the built design deviates from what was originally specified

Worth stating plainly, because the original plan is no longer in the
repository and the deviations are the interesting part.

**1. No daemon, and no management socket.** The plan was to drive OpenVPN over
a unix-domain management socket owned by a small privileged systemd service of
our own. What shipped uses the *stock* `openvpn-client@.service` and
`wg-quick@.service`, driven by `systemctl` through the stock
`org.freedesktop.systemd1.manage-units` polkit action.

That trade is the single most consequential decision here. It buys: nothing to
install, nothing to keep running, no unit file or policy of ours to review, and
state that survives a shell restart because the state lives in systemd. It
costs: the management socket is root-owned, so **negotiated cipher, reconnect
count, and interactive OTP are unreachable** — see `FUTURE_WORK.md`.

**2. Dependency installs hand off to `omarchy-install-app`, not `pkexec
pacman`.** The plan said to call `pkexec pacman -S --needed` directly, on the
reasoning that a polkit dialog is not a terminal. It shipped as a hand-off to
Omarchy's `omarchy-install-app`, which runs the install in Omarchy's themed
floating terminal. The plugin never invokes a package manager itself — also
mechanically checked.

**3. "All features in for v1" did not survive.** The original scope listed the
kill switch, auto-connect on untrusted Wi-Fi, split tunnelling, OTP, and
profile editing as v1. Four shipped areas (dependency handling, WireGuard,
credentials, kill switch); the rest are in `FUTURE_WORK.md` with what each
would actually take.

---

## Control plane

`Service.qml` owns every process and all state. It runs `systemctl start`,
`systemctl stop`, and one `systemctl show` per poll for state and uptime.

**Stock units, unescaped instance names.** `openvpn-client@<name>.service` and
`wg-quick@<name>.service` expand `%i` into a *filename*, so the instance must
be the profile name literally, not systemd-escaped. Profile names are therefore
restricted at import to characters that are already legal in an instance, and
the guard is asserted both ways: `Model.escapeUnitName()` is pinned against the
real `systemd-escape` binary, and a separate test proves that everything
`sanitizeProfileName()` can emit needs no escaping.

**Optimistic state.** A pending id steers the UI while a command is in flight;
the poll is the source of truth and clears it once it agrees; a timeout unsticks
the switch if confirmation never arrives. The panel reads `isActive(tunnel)`,
never a raw `state` field — checked mechanically.

**The half-up tunnel.** A unit can report `active` while its device never
appeared. `Model.reconcileState()` treats that as still activating, because the
silent failure mode of a VPN is a link that is up while traffic is not using
it.

## Telemetry plane

`Telemetry.qml`. Once a tunnel is up it is just a netdev, so none of this is
protocol-specific and none of it needs privilege:

| Source | Gives |
|---|---|
| `/sys/class/net/<dev>/statistics/{rx,tx}_bytes` | bytes and throughput |
| `ip -j route` | whether the default route is really via the tunnel |
| `ip -j addr` | the tunnel's addresses |
| `resolvectl status <dev>` | the resolvers in effect — a DNS-leak indicator |

Sampling is split by cost. Byte counters ride the normal poll because they are
two sysfs reads. Routes, resolvers and the exit-IP lookup run **only while the
popup is open** — a bar widget must not wake the radio for a panel nobody is
looking at.

The exit-IP lookup is the one thing in this plugin that ever contacts a third
party. It is off by default and documented in the README's privacy note.

---

## Privileged operations — exactly three

| What | Authorization | Triggered by |
|---|---|---|
| `systemctl start`/`stop <unit>` | stock `org.freedesktop.systemd1.manage-units` | connect / disconnect |
| `pkexec bin/install-profile` | polkit `org.freedesktop.policykit.exec` | import, delete, save or clear credentials |
| `pkexec bin/killswitch` | same | arming or disarming the kill switch |

Two helpers rather than one, deliberately: `install-profile` is about profiles,
`killswitch` can take the machine off the network. pkexec authorizes per
invocation either way, so merging them would buy no privilege separation and
would cost the reader an accurate name.

**Both helpers treat their caller as untrusted**, because an unprivileged
process can invoke them with any arguments it likes:

- The destination directory is chosen **inside** the helper from a protocol
  token. A caller that could name the directory could write anywhere.
- Profile names must match `^[A-Za-z0-9][A-Za-z0-9._-]*$`, be ≤64 characters,
  and contain no `..`. Names are *refused*, never sanitized — silently changing
  the name a caller asked for is how a delete removes the wrong file.
- A staging directory may contain only regular files belonging to that profile.
  A symlink there would make root copy something it was not shown.
- Every value the kill switch interpolates into an `nft` script (device, port,
  protocol, endpoint) has its own validator. That validation *is* the security
  boundary: a value that escaped its rule could write any rule at all.
- Secrets arrive on **stdin, never argv**, because `/proc/<pid>/cmdline` is
  world-readable. Four separate mechanical checks enforce this, each verified
  to fail when deliberately broken.

---

## The three environment constraints that shaped everything

All three were found by reading the system, and each one invalidates an obvious
design.

**1. `ProtectHome=true` in the stock OpenVPN unit.** The service sees an empty
`/home`, so a profile referencing `askpass /home/you/...` starts and then dies.
Import must rewrite every file-valued directive to sit beside the config. That
is what `backends/openvpn/Config.js` exists for.

**2. `/etc/openvpn/client` is `0750 openvpn:network`, and `network` is empty.**
Shipped that way by the openvpn package's tmpfiles, so it is true on every Arch
machine. An unprivileged process cannot list that directory, stat a file in it,
or traverse into it. **Profile enumeration therefore cannot be unprivileged** —
which is why `ProfileStore.qml` keeps a user-side index and why a rescan is a
privileged `list`, user-initiated and never polled.

**3. `omarchy-pkg-add` shells out to `sudo`**, which has no tty inside the
shell process. `omarchy-install-app` runs it inside Omarchy's themed floating
terminal, which does. `wg-quick` has the same shape — it re-execs itself under
`sudo` when `$UID` is not 0 — so it too is only ever reached through its unit.

---

## Components

| File | Role |
|---|---|
| `Panel.qml` | Bar button, popup, keyboard state machine. Presentation only. |
| `Service.qml` | All state and every process. **Names no protocol.** |
| `Telemetry.qml` | Kernel counters, routes, resolvers. |
| `ProfileStore.qml` | The user-side index of installed profiles. |
| `Backends.qml` | Backend registry — the one runtime file that names a protocol. |
| `Model.js` | Pure logic, no QML types. Highest test coverage in the project. |
| `VpnIcon.qml` | Canvas-drawn shield mark. |
| `backends/<proto>/Backend.qml` | The strategy object: units, devices, import. |
| `backends/<proto>/Config.js` | That protocol's config parsing and rewriting. |
| `bin/install-profile` | Privileged: install, remove, list, credentials. |
| `bin/stage-profile` | Unprivileged staging, runs as the user. |
| `bin/killswitch` | Privileged: one nftables table, on/off/status. |

### The backend interface

Adding a protocol means adding a folder and one line in `Backends.qml`. A
backend is data plus four small functions — `unitFor`, `deviceFor`,
`planImport`, `endpointOf` — alongside declared properties: `protocol`,
`label`, `packageName`, `commands`, `unitTemplate`, `devicePrefixes`,
`fileExtensions`, `maxNameLength`, `supportsCredentials`, `configExtension`.

The evidence that the seam holds: adding WireGuard took `Backends.qml` from 14
to 16 lines of code, plus the folder and exactly one predicted new seam. The
registry is size-capped at 20 lines of code by a test, so protocol logic cannot
quietly move in.

### The data shape

`Panel.qml` must never see a backend-shaped row — the starter code handed
`nmcli` rows straight to the UI. Everything the panel reads comes from
`Model.makeTunnel()`: id, name, protocol, unit, endpoint, endpointProto, state,
device, path, requires, needsCredentials, hasCredentials, telemetry.

---

## Where state lives

| State | Where | Notes |
|---|---|---|
| Tunnel up/down | systemd | The source of truth; survives a shell restart. |
| Installed profiles | `$XDG_STATE_HOME/connor.vpn/profiles.json` | A user-side index, because the profile directory is unreadable to us. |
| Profile files and credentials | `/etc/openvpn/client`, `/etc/wireguard` | Root-owned, 0600. |
| Kill switch rules | the kernel's nftables ruleset | Never written to `/etc/nftables.conf`. |
| Kill switch mirror | `/run/connor-vpn/killswitch`, 0644 | Because `nft list` needs `CAP_NET_ADMIN` and polling through pkexec would prompt every tick. |
| Preferences | the widget's entry in `~/.config/omarchy/shell.json` | Written via `persistSettings()`; degrades to session-only if the entry is not writable. |

The kill switch's marker and its rules both live on volatile storage and die
together at a reboot, so they cannot disagree across one.

---

## Credentials

A bare `auth-user-pass` means "prompt on the terminal", and the service has no
terminal — such a profile used to install and never start. Import now rewrites
it to `auth-user-pass <name>.auth`, and the helper writes that file root-owned,
mode 0600, in OpenVPN's own two-line format (username, password). No invented
encoding to audit, and a reconnect picks it up with no session and no UI.

**Why a root-owned file and not the session keyring:** `pam_gnome_keyring.so
auto_start` unlocks the keyring at login and hands secrets to any process
running as you. `/etc/openvpn/client` is `0750 openvpn:network` with an empty
`network` group, so your own unprivileged processes cannot read it. Asserted in
the integration tier rather than assumed.

`<name>.auth` falls under the `$name.*` glob that `remove` already walks, so
deleting a profile deletes its credentials without a second rule that could
drift out of step.

WireGuard authenticates with keys already in the config; `supportsCredentials`
is false there and the helper refuses the verb for that protocol too.

---

## Kill switch

One table, `inet connor_vpn_killswitch`, with `output` and `forward` base
chains that both `jump` a shared guard chain. **Both are `policy drop`** — a
rule we forgot should cost connectivity, never privacy.

```
oifname "lo" accept
oifname "<tunnel device>" accept          # everything inside the tunnel
ip  daddr @endpoints4 <proto> dport <port> accept    # the tunnel's own traffic
ip6 daddr @endpoints6 <proto> dport <port> accept
meta l4proto { tcp, udp } th dport { 53, 853 } drop  # DNS, before the LAN pass
udp sport 68  dport 67  accept                        # keep the DHCP lease
udp sport 546 dport 547 accept
ip  daddr { RFC1918, link-local, multicast, broadcast } accept
ip6 daddr { fe80::/10, ff00::/8, fc00::/7 } accept
icmpv6 type { nd-* } accept
counter comment "blocked"                             # falls through to policy
```

Four decisions inside that:

- **`inet`, not `ip`.** An IPv6 leak is the classic way a kill switch fails,
  and it fails invisibly.
- **A `forward` chain too**, because `docker` is in Omarchy's base packages and
  a container routing out through the host is a real leak path on a stock
  machine.
- **LAN allowed, DNS to the LAN not.** Printers and a NAS keep working. But the
  LAN pass would otherwise re-open DNS to the router — every query visible to
  the ISP — so 53 and 853 are dropped just above it. In-tunnel DNS is
  unaffected, having been accepted two rules earlier by `oifname`.
- **The endpoint is pinned by address**, resolved by the helper at arm time.
  This is the rule that keeps the tunnel alive; without it the switch deadlocks
  the connection it is protecting.

**Coexistence.** In nftables an `accept` means "carry on to the next base
chain" — only `drop` is final. So our verdict does not depend on priority or on
being installed before `ufw`, and our table can be deleted without touching
anyone else's. Proven against a stand-in table with `policy accept`.

**Behaviour.** Armed while a tunnel is up. **If the tunnel drops unexpectedly
the rules stay** — a kill switch that opens on failure is decoration.
Disconnecting deliberately disarms it; `_disarmAfterStop` distinguishes the two
cases, and it must be set as it happens because nothing afterwards can tell
them apart. Not persistent across a reboot: "always-on from boot" is the
variant that locks a user out with no UI to fix it.

**Recovery** is documented in the README and is load-bearing:
`pkexec .../bin/killswitch off`, or reboot.

**Only one copy of the widget arms automatically.** The bar mounts the widget
once per monitor, each with its own `Service` and its own poll, so three
monitors would otherwise mean three `pkexec` calls for one tunnel coming up.
One is elected via QML's `Screen` attached property. The election gates the
automatic path only — the toggle works from whichever copy you clicked.

---

## Dependencies

**Rule: `pacman -Q` is not evidence.** Whether a package is installed on the
author's laptop says nothing about a stranger's machine. The only guarantee is
`/usr/share/omarchy/install/omarchy-base.packages`, present on every Omarchy
install. This mistake was made once during design, when `openvpn` was briefly
treated as ambient because it happened to be installed by hand.

| Package | In base? | Why |
|---|---|---|
| `nftables` | **yes, transitively** | `ufw` is in base → needs `iptables` → needs `nftables`. `docker` requires it too. The kill switch costs nothing. |
| `python-gobject` | yes | backs `omarchy-file-select`, the portal file chooser |
| `iproute2`, `systemd-resolved` | yes | telemetry |
| `openvpn` | **no** | detect at point of use, offer to install |
| `wireguard-tools` | **no** | same |
| `systemd-resolvconf` | **no** | only for a WireGuard profile with `DNS =` |

**Omarchy has no plugin dependency mechanism at all** — `manifest.json` has no
dependency field, validation checks only schema and entry points, and
`omarchy plugin add` is clone → validate → move → rescan → enable. We own the
whole flow.

**Degrade lazily.** Never gate the whole widget on a missing binary: a
WireGuard-only user must never see an OpenVPN warning. Checks happen at the
point of use — importing, or activating a profile — never on load.
`test/dependency.test.sh` enforces this by walking every call site.

---

## Rules that are mechanically enforced

These are in `test/architecture.test.sh` and `test/dependency.test.sh`, and
each exists because breaking it would be silent.

- **No protocol name outside its backend.** No runtime file except
  `Backends.qml` may contain `openvpn`, `wireguard`, `wg-quick`, `nmcli`, or
  `NetworkManager`. The registry is capped at 20 lines of code and may not
  contain `Process`, `systemctl`, `pkexec` or `FileView`.
- **Reassign, don't mutate.** QML does not notify on in-place edits. The
  corollary is a trap: the poll replaces the whole tunnel list every tick, so
  rebuilding from an explicit field list silently drops any field the caller
  forgot to restate. `Model.makeTunnel()` is therefore only legal inside
  `rebuild()`; every other path uses `Model.updateTunnel(tunnel, changes)`.
- **Properties whose effect is the transition must be re-armed.**
  `stdinEnabled = false` is what sends EOF, and it only fires on a *change* —
  so the second import of a session hangs forever unless it is set back to
  `true` first. Assigning a `FileView` the path it already holds has the same
  shape. Both are checked.
- **No secret in an argument list or on the IPC surface.** The credential
  command array carries no secret, the payload is cleared the moment it is
  written, `stateJson()` reports presence only, and the panel never routes a
  credential through `persistSettings()`.
- **The kill switch stays fail-closed**: both chains `policy drop`, the `inet`
  family, the DNS drop above the LAN accept, the poll's maintenance never
  disarming, and nothing writing `/etc/nftables.conf`.
- **Theme through the bar** — no literal colours or pixel sizes in `Panel.qml`.
- **Never invoke a package manager ourselves.**
- **No symlinks** anywhere in the plugin folder; plugin validation rejects them.

---

## Testing

Four tiers, in `run-tests.sh`. **274 assertions need no root and run in about
three seconds**; a further 79 need root and are opt-in.

- **Tier 1** — pure functions in `Model.js` and each `Config.js`, under `node`.
  `test/harness/escape.test.sh` additionally pins the systemd escaper against
  the real binary, because getting escaping wrong does not fail loudly — it
  starts the wrong unit.
- **Kill switch** — `test/killswitch.test.sh`. Runs the real rules against real
  interfaces and counts real packets inside
  `unshare --user --map-root-user --net`, which has its own complete nftables
  ruleset. **No root, and the host's ruleset is never touched.** Every
  assertion is about a packet, not the text of a rule: a rule set that reads
  correctly and drops the tunnel's own handshake is the failure worth catching.
- **Tier 2** — `test/harness/up.sh`, opt-in, needs root. Generates a throwaway
  CA, runs OpenVPN and WireGuard servers in a network namespace, and connects
  through the real units. The plugin's own parsers run against genuine kernel
  and `resolvectl` output, which is what catches a parser that has drifted from
  reality.
- **Tier 3** — `omarchy-shell connor.vpn state` returns structured JSON, so
  panel logic is asserted on without screenshots.
- **Tier 4** — `test/dependency.test.sh` simulates a clean machine with a fake
  PATH and proves the widget renders, does not warn on load, and warns only at
  the point of use.

Two habits worth keeping. **A check that prints no detail on failure hides the
log that explains it** — every assertion prints the relevant output when it
fails. And **an assertion whose expected value is empty must carry a `ran:`
marker**, so "found nothing" and "never executed" cannot be confused; one
integration run once reported `ok` for a check while nothing had been tested.

---

## Known limitations

- **No negotiated cipher, reconnect count, or OTP**, because the OpenVPN
  management socket is root-owned. Direct consequence of using stock units.
- **No WireGuard handshake age** — `wg show` needs root. Asserted, so the
  omission is deliberate rather than forgotten.
- **A commercial full-tunnel profile has never been connected.** Everything is
  proven against a throwaway CA in a namespace. That is also the last look at
  the NetworkManager question: NM was observed *not* interfering with `tun0`,
  but only against a profile that routes a single /24 and never moves the
  default route.
- **The kill switch has never run on a real host firewall.** The rules are
  identical and coexistence was proven against a stand-in table, but `ufw` and
  Docker on a real machine are a different sample.
- **One helper assertion degrades to `SKIP` on a machine that has WireGuard.**
  `helper.test.sh` exercises the "profile directory does not exist" branch, and
  installing `wireguard-tools` creates `/etc/wireguard` — so that branch stops
  being covered on a developer machine once WireGuard is installed. It skips
  loudly rather than passing silently.
- **`Panel.qml` is excluded from `qmllint`** — it cannot parse Quickshell's
  typed IPC functions (`function open(): void`) and dies with
  "Unexpected token `void`", on the shipped first-party plugins too. That file
  is covered only by the architecture greps and by running it.
