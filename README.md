# VPN — Omarchy bar widget

`connor.vpn`. Import, connect, and monitor OpenVPN and WireGuard tunnels from
the Omarchy bar, without opening a terminal.

It stores credentials for profiles that need a username and password, and has
an optional **kill switch** that blocks everything outside the tunnel.

![The panel: tunnel-scoped stats, the kill switch toggle, and one profile per
backend](preview.png)

The widget drives the **stock systemd template units** that ship with the
`openvpn` and `wireguard-tools` packages. It installs no daemon, no unit file,
and no polkit policy of its own — privileged operations authenticate through
the polkit agent Omarchy already runs.

## What runs with privilege

Omarchy plugins run **unsandboxed, inside the shell process, with your
permissions** — that is true of every plugin, not just this one, so it is worth
being able to see exactly what this one does with that access. Three things,
and nothing else:

| What | How | When |
|---|---|---|
| `systemctl start`/`stop` on a tunnel's unit | The stock `org.freedesktop.systemd1.manage-units` polkit action | You connect or disconnect |
| `bin/install-profile` | `pkexec` | You import, delete, or save credentials for a profile |
| `bin/killswitch` | `pkexec` | You turn the kill switch on or off |

Both helpers are short shell scripts in this repository, meant to be read.
They treat their caller as untrusted, because it is: the destination directory
is chosen inside the helper rather than taken from an argument, profile names
and device names must match strict patterns, and passwords arrive on stdin so
they never appear in `/proc/<pid>/cmdline`.

**No daemon, no unit file, and no polkit policy is installed.** Everything goes
through the polkit agent Omarchy already runs, and every prompt is one you
triggered. Nothing is done in the background: the widget polls with unprivileged
kernel reads only.

The one thing that leaves your machine is the optional exit-IP lookup, which is
off by default — see the privacy note below.

## Requirements

| Package | Needed for | In Omarchy's base? |
|---|---|---|
| `openvpn` | OpenVPN profiles. Provides `openvpn-client@.service`. | **No — install it** |
| `wireguard-tools` | WireGuard profiles. Provides `wg-quick@.service`. | **No — install it** |
| `nftables` | The kill switch. | Yes — `ufw` needs `iptables`, which needs this |

You only need the one your profiles use. Neither is probed until you reach for
it, so a WireGuard-only user is never told about OpenVPN.

Everything else the widget uses is already on every Omarchy install:
`systemd`, `iproute2` (`ip`), `systemd-resolved` (`resolvectl`), and
`python-gobject` (which backs the `omarchy-file-select` file chooser).

The widget does **not** install anything itself. If `openvpn` is missing you
get a card offering to install it, which hands off to Omarchy's
`omarchy-install-app` — and you only ever see that card at the moment you reach
for OpenVPN, never on load.

```bash
# If you would rather do it by hand:
sudo pacman -S --needed openvpn          # for OpenVPN profiles
sudo pacman -S --needed wireguard-tools  # for WireGuard profiles
```

### Optional

`systemd-resolvconf` — only for a **WireGuard** profile with a `DNS =` line.
`wg-quick` applies that setting by shelling out to `resolvconf`, which is not
installed by default. Without it `wg-quick` brings the interface up, fails with
`resolvconf: command not found`, tears the interface back down and exits 127.
Most commercial WireGuard profiles set `DNS`, so this is worth knowing —
importing such a profile warns you about it before anything is installed.

```bash
sudo pacman -S --needed systemd-resolvconf
```

**Not `openresolv`.** It is the other package that provides `resolvconf`, and
on Omarchy it does not work: `/etc/resolv.conf` is a symlink to
systemd-resolved's stub, and openresolv refuses to manage a file it did not
create — `resolvconf: signature mismatch: /etc/resolv.conf`, and the tunnel
fails to start. `systemd-resolvconf` points `resolvconf` at `resolvectl`, which
speaks the same interface and applies DNS through the resolver actually in
charge. If you already installed `openresolv`, replace it:

```bash
sudo pacman -S systemd-resolvconf   # answer yes to removing openresolv
```

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

Press **＋** next to a protocol's heading and pick a profile — a `.ovpn` file
for OpenVPN, a `.conf` file for WireGuard. The widget:

1. parses it and refuses anything that is not a client profile;
2. rewrites every file reference — `ca`, `cert`, `key`, `askpass`, `tls-auth`
   and friends — to sit beside the config, because the stock unit runs with
   `ProtectHome=true` and cannot see your home directory (see below);
3. stages the result in your own cache directory;
4. asks polkit for permission once, and installs it into
   `/etc/openvpn/client/`.

Your original file is not modified or moved.

A WireGuard profile is normally self-contained — its keys are inline — so
steps 2 and 3 do almost nothing and the config is installed as you wrote it.
Two things are checked that `wg-quick` would otherwise only complain about
later: the profile name must fit the kernel's 15-character interface-name
limit, because `wg-quick` names the interface after the file; and a
`PostUp`/`PreUp` hook naming an absolute path is looked for on your system
before anything is installed.

### Profiles that need a username and password

Most commercial providers ship a profile with a bare `auth-user-pass` line,
which means "ask on the terminal". The VPN service has no terminal, so such a
profile would start and hang. Importing one instead points it at a credential
file and offers you two fields under the profile row; enter them once and the
tunnel connects, reconnects and survives a reboot without asking again.

Credentials are stored in **`/etc/openvpn/client/<profile>.auth`, mode 0600**,
owned by the same user as the rest of the profile — username on the first line,
password on the second, which is the format OpenVPN itself defines. Deleting
the profile deletes them; **Remove** under the profile clears them on their own.

Be clear about what that does and does not protect:

- **Root can read them.** So can anyone who can become root on your machine.
- **Your own user account cannot** — the profile directory is not readable by
  an unprivileged process at all. This is the main reason it is a root-owned
  file rather than the session keyring: the keyring unlocks automatically at
  login and hands secrets to any process running as you, without a prompt.
- **At rest they rely on disk encryption**, which Omarchy enables by default.
- **An unencrypted backup of `/etc` carries them off the encrypted disk.** Full
  disk encryption does not travel with a tarball. If you back up `/etc`, that
  backup holds your VPN password in plaintext.

WireGuard profiles carry their keys inline and never ask for any of this, so
they are never offered the fields.

### The kill switch

With the kill switch on, nothing leaves your machine except through the
tunnel. Turn it on with the **Kill switch** toggle in the panel, under the
tunnel's stats.

What stays allowed, deliberately:

- **Your local network.** Printers, a NAS, another machine on your desk — all
  still reachable. A kill switch that cut those off would be turned off within
  the day.
- **The tunnel's own traffic to your VPN server**, which has to leave outside
  the tunnel or nothing could connect at all.
- **DHCP**, so you keep your address on the network.

What is blocked: everything else, including IPv6 and including traffic from
Docker containers. **DNS to your router is blocked too**, even though the rest
of your local network is allowed — otherwise every name you looked up would
still be visible to your ISP, which is most of what a VPN is for.

**If the tunnel drops, traffic stays blocked.** That is the point. Turning the
switch off, or disconnecting on purpose, is what lifts it.

#### Turning it off when you cannot reach the panel

If the shell crashes while the kill switch is on, you have no window and no
internet. Two ways back:

```bash
pkexec ~/.config/omarchy/plugins/connor.vpn/bin/killswitch off
```

Or **reboot**. The rules live only in the kernel — this widget never writes to
`/etc/nftables.conf`, so a restart always clears them. That is a deliberate
guarantee, not a side effect.

#### What it does to your firewall

It adds one nftables table, `inet connor_vpn_killswitch`, and touches nothing
else. If you run `ufw` (Omarchy sets it up by default) or Docker, their rules
are left exactly as they are, and turning the switch off removes only our
table. You can see it with:

```bash
sudo nft list table inet connor_vpn_killswitch
```

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
| `killSwitch` | boolean | `false` | Arm the kill switch whenever a tunnel comes up |
| `lastTunnelId` | string | `""` | Written by the widget; the right-click target |

### Privacy note on `showExitIp`

Determining your exit IP means asking a third party what address they see you
coming from. With this on, the widget sends a request to
`https://api.ipify.org` over the tunnel whenever a tunnel comes up. That
discloses your VPN exit address to that service.

It is **off by default** and it is the only thing in this widget that ever
leaves your machine. Everything else is read from the kernel.

## When something goes wrong

When a tunnel fails to start, the widget reads that unit's journal and shows
the daemon's own reason — `systemctl start` reports only that the job failed,
which is never the useful half. Reading the journal needs no privilege, so
this costs no extra authorization prompt. For the full story:

```bash
systemctl status openvpn-client@<profile>
journalctl -u openvpn-client@<profile> -n 50
```

**"The server rejected the username or password for this profile."** — exactly
that; the credentials are wrong or expired. Press **Change** under the profile
and enter them again.

**"Authorization was declined."** — the polkit prompt was dismissed or the
password was wrong. Nothing was changed.

**A profile you installed by hand is not listed.** The widget keeps its own
index of profiles it installed, because `/etc/openvpn/client` is mode `0750`
owned by `openvpn:network` and an unprivileged process cannot list it. Press
**⟳** next to the OpenVPN heading to rescan — that asks for authorization once
and rebuilds the index from what is actually installed.

**A profile is listed but starting it says the config is missing.** Same fix:
press **⟳**.

**No internet, and the panel says the kill switch is on.** That is the kill
switch doing its job — it stays on when a tunnel drops, on purpose. Turn it
off with the button in the panel, or from a terminal:

```bash
pkexec ~/.config/omarchy/plugins/connor.vpn/bin/killswitch off
```

Rebooting also clears it.

**Names do not resolve while the kill switch is on and a tunnel is up.** Your
profile is probably not pushing DNS servers — check the DNS row in the panel.
The kill switch blocks DNS to your router deliberately, so a tunnel that
supplies no resolver of its own leaves nothing to ask.

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
| `backends/wireguard/` | Everything WireGuard-specific |
| `bin/install-profile` | The privileged helper, run via `pkexec` |
| `bin/stage-profile` | Unprivileged staging, run as you |
| `bin/killswitch` | The nftables helper, run via `pkexec` |
| `test/` | The suite; `test/harness/` is the real-tunnel tier |

### Documentation

| File | For |
|---|---|
| `README.md` | Using it — this file |
| `ARCHITECTURE.md` | How it is built and why. **Start here if you are auditing it.** |
| `FUTURE_WORK.md` | What was deliberately left out, and what each item would take |
| `CLAUDE.md` | Working notes: environment facts and traps that cost a debugging session |

## Authorship

This plugin was built with [Claude Code](https://claude.com/claude-code) as a
coding assistant, under my direction — I set the requirements and architecture
decisions (see `ARCHITECTURE.md`), reviewed and tested every
change, and I'm the sole author of record on the commit history. Noting it
here in the interest of transparency, since the target audience is strangers
evaluating this on a plugin marketplace.

## Licence

MIT — see [LICENSE](LICENSE).
