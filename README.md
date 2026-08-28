# VPN — Omarchy bar widget

`connor.vpn`. Import, connect, and monitor OpenVPN tunnels from the Omarchy
bar, without opening a terminal.

The widget drives the **stock systemd template unit** that ships with the
`openvpn` package. It installs no daemon, no unit file, and no polkit policy of
its own — privileged operations authenticate through the polkit agent Omarchy
already runs.

## Requirements

| Package | Needed for | In Omarchy's base? |
|---|---|---|
| `openvpn` | Everything OpenVPN. Provides `openvpn-client@.service`. | **No — install it** |

Everything else the widget uses is already on every Omarchy install:
`systemd`, `iproute2` (`ip`), `systemd-resolved` (`resolvectl`), and
`python-gobject` (which backs the `omarchy-file-select` file chooser).

The widget does **not** install anything itself. If `openvpn` is missing you
get a card offering to install it, which hands off to Omarchy's
`omarchy-install-app` — and you only ever see that card at the moment you reach
for OpenVPN, never on load.

```bash
# If you would rather do it by hand:
sudo pacman -S --needed openvpn
```

### Optional

`curl` — only if you turn on **Show exit IP** (off by default; see Settings).

## Install

```bash
omarchy plugin add https://github.com/connor981332/omarchy-vpn.git
omarchy plugin enable connor.vpn
omarchy bar move connor.vpn
```

The repo is `omarchy-vpn` but the plugin id is `connor.vpn` — `omarchy plugin
add` names the install directory from `manifest.json`, not from the URL, so the
two later commands are correct as written.

## Using it

- **Left click** opens the panel.
- **Right click** connects the last used profile, or disconnects the active one.
- **Middle click** forces a refresh.

### Importing a profile

Press **＋** next to the OpenVPN heading and pick a `.ovpn` file. The widget:

1. parses it and refuses anything that is not a client profile;
2. rewrites every file reference — `ca`, `cert`, `key`, `askpass`, `tls-auth`
   and friends — to sit beside the config, because the stock unit runs with
   `ProtectHome=true` and cannot see your home directory (see below);
3. stages the result in your own cache directory;
4. asks polkit for permission once, and installs it into
   `/etc/openvpn/client/`.

Your original `.ovpn` is not modified or moved.

### Why your profile gets rewritten

`openvpn-client@.service` sets `ProtectHome=true`, so the service sees an empty
`/home`. A profile that says `askpass /home/you/.ovpn/password` will start and
then die. The importer copies those files next to the config and re-points the
directives at them, which is the only way to make such a profile work under the
stock unit.

Two things it deliberately does **not** rewrite:

- **`up` / `down` script hooks.** A hook lives wherever you installed it. If it
  points into `/home` you get a warning at import time rather than a tunnel
  that mysteriously has no DNS.
- **`script-security` and the hooks themselves.** They are preserved exactly.
  (NetworkManager's importer drops them, which is one of the reasons this
  widget does not use NetworkManager.)

## What the panel shows

Everything here is scoped to the **tunnel** interface. The built-in Omarchy
network widget already shows your physical interface, router ping and packet
loss; this deliberately does not duplicate any of it.

| Row | Why it is there |
|---|---|
| **Default route** | Catches the half-up tunnel: link established, traffic not using it. Turns red when the default route is not via the tunnel. |
| **DNS** | The resolvers actually scoped to the tunnel, from `resolvectl`. A leak indicator most clients don't show. |
| **Address** | The address the server assigned. |
| **Exit IP** | Off by default — see Settings. |
| **Connected** | Session duration, from the unit's own timestamp. |
| **Transferred** | Session totals, from the kernel's byte counters. |
| **Throughput** | Live rate on the tunnel device. |
| **Endpoint** | The server the profile connects to. |

Expensive probes only run while the panel is open — a bar widget should not
wake the radio for a panel nobody is looking at.

## Keyboard

Inside the panel:

| Key | Action |
|---|---|
| `j` / `k`, arrows | move the cursor (wraps through the header switch) |
| `enter` / `space` | connect or disconnect the selected profile |
| `i` | import a profile |
| `x` | delete the selected profile (asks first) |
| `d` | disconnect the active VPN |
| `r` | refresh |
| `tab` | switch to the neighbouring bar panel |
| `esc` | close (or dismiss the delete confirmation) |

## Settings

Per-widget settings live in the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Type | Default | Meaning |
|---|---|---|---|
| `refreshIntervalSec` | integer | `15` | How often to poll unit state |
| `hideWhenDisconnected` | boolean | `false` | Hide the bar icon while no VPN is up |
| `showExitIp` | boolean | `false` | Show the exit IP — **see the privacy note** |
| `lastTunnelId` | string | `""` | Written by the widget; the right-click target |

### Privacy note on `showExitIp`

Determining your exit IP means asking a third party what address they see you
coming from. With this on, the widget sends a request to
`https://api.ipify.org` over the tunnel whenever a tunnel comes up. That
discloses your VPN exit address to that service.

It is **off by default** and it is the only thing in this widget that ever
leaves your machine. Everything else is read from the kernel.

## When something goes wrong

The widget surfaces the cause in the panel. For the full story:

```bash
systemctl status openvpn-client@<profile>
journalctl -u openvpn-client@<profile> -n 50
```

**"Authorization was declined."** — the polkit prompt was dismissed or the
password was wrong. Nothing was changed.

**A profile you installed by hand is not listed.** The widget keeps its own
index of profiles it installed, because `/etc/openvpn/client` is mode `0750`
owned by `openvpn:network` and an unprivileged process cannot list it. Press
**⟳** next to the OpenVPN heading to rescan — that asks for authorization once
and rebuilds the index from what is actually installed.

**A profile is listed but starting it says the config is missing.** Same fix:
press **⟳**.

## Removing it

```bash
omarchy plugin remove connor.vpn
```

Profiles you imported stay in `/etc/openvpn/client/` — that is where OpenVPN
profiles belong, and removing a bar widget should not delete your VPN
credentials. Delete them from the panel first (**x** on each row) if you want
them gone.

## Development

```bash
./run-tests.sh                  # everything that needs no root
./run-tests.sh --integration    # also builds a real tunnel in a netns (sudo)
./validate.sh                   # manifest + qmllint + live IPC health check
```

See `CLAUDE.md` for the architecture and the things that look like bugs and
are not.

## Files

| File | Role |
|---|---|
| `manifest.json` | Plugin id, kind, entry point, settings schema |
| `Panel.qml` | Entry point: bar button, popup, keyboard state machine |
| `Service.qml` | State, polling, and every command — protocol-agnostic |
| `Telemetry.qml` | Kernel counters, routes, resolvers |
| `ProfileStore.qml` | The index of installed profiles |
| `Backends.qml` | Backend registry — the one file that names a protocol |
| `Model.js` | Pure protocol-agnostic logic — no QML types |
| `VpnIcon.qml` | Canvas-drawn shield mark |
| `backends/openvpn/` | Everything OpenVPN-specific |
| `bin/install-profile` | The privileged helper, run via `pkexec` |
| `bin/stage-profile` | Unprivileged staging, run as you |
| `test/` | The suite; `test/harness/` is the real-tunnel tier |

## Licence

MIT — see [LICENSE](LICENSE).
