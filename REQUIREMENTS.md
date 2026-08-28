# connor.vpn — Requirements

Working document. Decisions here supersede the nmcli-era assumptions still
described in CLAUDE.md; CLAUDE.md gets rewritten once the new skeleton lands.

## Product goals

1. Works out of the box with OpenVPN and WireGuard.
2. **Never open a terminal.** Hard requirement. Import, credentials, editing,
   deleting, 2FA, and installing missing dependencies all happen in the UI.
   "Roll your own" is an acceptable cost to satisfy this.
3. Feature parity with the first-party Windows/macOS OpenVPN and WireGuard
   clients, at a polish level worth publishing.
4. VPN-specific stats in the widget, without duplicating the built-in network
   widget (which already shows physical-iface rx/tx, router/internet ping,
   and packet loss via `omarchy-network-status --verbose`).

## Backend decision

**Rejected: NetworkManager/nmcli as the control plane.**
Not for overhead — NM is already running and managing Wi-Fi here, has no GUI
installed, and would cost nothing to call. Rejected because it cannot reach the
scoped features:

- NM's importer drops `script-security` and `up`/`down` hooks, silently
  changing the behavior of the existing working profile
  (`~/.ovpn/framework-omarchy.ovpn` uses `update-systemd-resolved`).
- No kill switch. Adding nftables beside NM's routing means two owners of the
  route table.
- No per-app split tunneling (needs cgroup/netns + fwmark; NM can only express
  route-based splits).
- Interactive OTP/challenge handled poorly.
- No telemetry: no byte counters, no handshake, no cipher.
- OpenVPN support needs `networkmanager-openvpn`, which is NOT installed
  (`/usr/lib/NetworkManager/VPN/` is empty).

**Adopted: two planes.**

### Control plane — direct, per protocol
- **OpenVPN**: `openvpn` 2.7.6 (official `extra`, already installed), driven
  over a unix-domain **management socket** we own. Gives state events,
  bytecount, and precise interactive auth (`>PASSWORD:Need ...`, dynamic
  challenge) for OTP.
  - NOT openvpn3: AUR-only on Arch. Unacceptable dep for a published plugin.
- **WireGuard**: `wireguard-tools` (official `extra`), kernel module present.

Protocols differ in only two places — **profile import** and **which optional
telemetry exists**. Everything else is shared. So: one control-plane interface
with two small strategy objects, NOT two parallel backend stacks.

### Telemetry plane — protocol-agnostic, kernel-sourced
Once a tunnel is up it is just a netdev. `/sys/class/net/<dev>/statistics/*`,
`ip route`, `resolvectl status <dev>`. No root, no daemon socket. Per-protocol
bonus sources are additive, never load-bearing:
- WireGuard: `wg show` (last handshake).
- OpenVPN: management socket (`state`, `bytecount`, cipher).

## Privilege model

Direct control needs root (create tun, set routes, load nftables). The current
`~/.ovpn/vpn.sh` uses passwordless `sudo -n`; we do not ship that.

**Small privileged helper as a systemd system service, gated by a polkit
policy.** The QML plugin is an unprivileged client. Root operations prompt
through the existing `omarchy.polkit` agent; state survives shell restarts; no
root code runs inside the shell process.

Consequence to accept: this plugin is a client of a daemon we also write.

## Data shape

`Panel.qml` must never see a backend-shaped row. The starter code's
`{name, uuid, type, device, state, active}` is an nmcli row with an alias and
is discarded.

Own a protocol-agnostic `Tunnel`: identity, protocol, endpoint, state enum,
device, telemetry sub-object. Each backend is an adapter that produces it.

## Stats catalog

Tier 1 and 2 are always visible; tier 3 renders only where available.
Cheap counters ride the normal poll. Expensive probes (exit IP, endpoint ping)
run **only while the popup is open** — a bar widget must not wake the radio on
a closed panel.

### Tier 1 — "am I actually protected?"
Nothing else in Omarchy shows these. Highest value.
- **Exit IP** + coarse geo. Cache hard; refresh on state change only.
- **DNS resolvers in effect for the tunnel** (`resolvectl status <dev>`).
  A leak indicator. Most first-party clients don't show this.
- **Default route actually via tunnel?** Catches the half-up tunnel where the
  link is established but traffic isn't using it — the silent failure mode.

### Tier 2 — session facts
- Connected since / duration.
- Session bytes transferred (total).
- **Tunnel-interface** throughput (`tun0`/`wg0`). Not duplication — the network
  widget shows the *physical* iface. Label it clearly so it doesn't read as one.

### Tier 3 — protocol-specific
- WireGuard: last handshake age (the real wg health signal).
- OpenVPN: negotiated cipher, reconnect count.
- Latency to the **VPN endpoint**, and VPN overhead (endpoint RTT vs. a
  pre-connect baseline). Distinct from the network widget's internet ping.

## Feature scope — all IN for v1

- Kill switch (nftables).
- Auto-connect on untrusted Wi-Fi (SSID allowlist/denylist).
- Split tunneling — route-based and per-app (cgroup/netns + fwmark).
- 2FA / OTP — server here doesn't use it, but support it.
- Full profile lifecycle in UI: import, edit, delete, credentials.
  Note: the shell's `Ui` module has TextField / SearchableDropdown /
  MultiSelect / NumberField but no file-picker widget; `image-picker` rolls its own
  via `list.sh` — precedent for building one.

## Dependency posture

### Rule: "installed on Connor's laptop" is NOT evidence
This plugin ships to strangers via the marketplace. The only guarantee is
`/usr/share/omarchy/install/omarchy-base.packages` (147 packages, present on
every Omarchy install). Anything outside that file must be detected at runtime
and installed by us. Verify with that file, never with `pacman -Q`.

### There is no dependency mechanism in Omarchy
- `manifest.json` has no dependency field. Keys in use across all first-party
  plugins: schemaVersion, id, name, version, author, license, description,
  kinds, entryPoints, + the kind block. Nothing else.
- `omarchy-plugin-validate` checks only: schemaVersion == 1, required fields,
  entry points exist and are safe relative paths, no symlinks.
- `omarchy-plugin-add` = clone -> validate -> move -> rescanPlugins -> enable.
  **No dependency handling at any point.**

### How first-party plugins cope
- **Service-installer pattern** (tailscale, dropbox): `omarchy-install-service-X`
  runs `omarchy-pkg-add`, enables units, then calls `omarchy-plugin-enable`.
  The service installs the plugin, not the reverse.
  **Unavailable to us** - those scripts ship in `/usr/share/omarchy/bin`.
- **Runtime detection** (tailscale Panel): `which tailscale` -> `installed`
  bool -> renders "Tailscale CLI is not installed or not on PATH." and stops.
  The only pattern available to a third-party plugin - but it dead-ends at a
  message, which fails our never-open-a-terminal requirement.

### Our posture: detect, then offer to fix
Detect each binary at startup. If missing, show a first-run card with a
one-click install. **Use `pkexec pacman -S --needed` via the `omarchy.polkit`
agent, NOT `omarchy-pkg-add`** - that helper shells out to `sudo`, which has no
tty inside the shell process and will fail. A polkit dialog is not a terminal,
so this still satisfies the requirement.

### What we can rely on

| Package | In base? | Purpose |
|---|---|---|
| `networkmanager` | **yes** | guaranteed present (not used as control plane) |
| `python-gobject` | **yes** | backs `omarchy-file-select` |
| `nftables` | **yes, transitively** | `base` -> `iproute2` -> `libxtables.so` -> `iptables` -> depends `nftables`. Kill switch dep is free. |
| `openvpn` | **no** | must detect + offer install |
| `wireguard-tools` | **no** | must detect + offer install |
| `networkmanager-openvpn` | **no** | not used - dropped |

Official repos only, no AUR. Note both designs need exactly one non-base
package for OpenVPN (`openvpn` vs `networkmanager-openvpn`), so dependency cost
does **not** discriminate between the nmcli and direct paths. Capabilities do.


## Test profile

`~/.ovpn/framework-omarchy.ovpn` — PiVPN, `proto udp`, `remote vpn.example.com
1194`, `dev tun`, AES-256-CBC / SHA256, `tls-crypt`, `verify-x509-name`,
`askpass` (key passphrase in `~/.ovpn/password`), DNS via
`update-systemd-resolved` + `dhcp-option DNS 10.0.0.2`.
Exercises inline certs, askpass, and script hooks — a good worst case.

## Open items

- Does NM try to manage our `tun0`/`wg0`? Verify once a tunnel exists; may need
  `[keyfile] unmanaged-devices` in NM conf to prevent two owners.
- ~~Does manifest support declaring dependencies?~~ **ANSWERED: no.** See
  Dependency posture. We own the whole install flow.
- ~~No file picker~~ **SOLVED**: `omarchy-file-select` is a portal-based
  chooser (`--title`, `--extensions`, `--multiple`), python-gobject in base.
- Secret storage: where do credentials live? (kernel keyring / libsecret /
  root-only file owned by the helper.) Undecided.
- `Model.js` keepers: `splitEscaped` (only if any nmcli parsing survives),
  `cleanError`, and the optimistic-state pattern from `Service.qml`.
  Estimate ~30% of the starter code survives.
