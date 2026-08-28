# connor.vpn — Omarchy bar widget

An Omarchy shell plugin: a bar widget for OpenVPN. This folder is the live
plugin — it is loaded from `~/.config/omarchy/plugins/connor.vpn/`, so edits
here affect the running shell directly.

Target audience is **strangers on the plugin marketplace**, not this machine.
That constraint drives most of the decisions below.

Scope decisions live in `REQUIREMENTS.md`. `PLAN.md` is the *forward* plan —
the MVP plan that produced this code shipped on 2026-08-27 and was replaced.

## Architecture

Two planes, and a hard rule about protocol names.

### Control plane — stock systemd template units, driven by polkit
No custom daemon, no unit file we install, no polkit policy we install.

`openvpn-client@<name>.service` ships with the `openvpn` package.
`systemctl start/stop` is authorized by the stock
`org.freedesktop.systemd1.manage-units` action, which resolves to
`auth_admin_keep` for an active session — so it prompts once through the
running `omarchy.polkit` agent and is retained for the session.

### Telemetry plane — kernel only, unprivileged
`/sys/class/net/<dev>/statistics/{rx,tx}_bytes`, `ip -j route`, `ip -j addr`,
`resolvectl status <dev>`. Zero privilege, protocol-agnostic, identical code
for a future WireGuard backend. The OpenVPN management socket is root-owned,
which is why negotiated cipher and reconnect count are not here.

### Privileged operations — exactly two
1. `systemctl start/stop <unit>` — stock polkit action.
2. `pkexec bin/install-profile` — install, remove, or list a profile in
   `/etc/openvpn/client/`.

### File map

| File | Role |
|---|---|
| `Panel.qml` | Bar button, popup, keyboard state machine. Presentation only. |
| `Service.qml` | All state and every process. **Names no protocol.** |
| `Telemetry.qml` | Kernel counters, routes, resolvers. |
| `ProfileStore.qml` | The index of installed profiles. |
| `Backends.qml` | Backend registry — the one runtime file that names a protocol. |
| `Model.js` | Pure logic, no QML types. Highest test coverage in the project. |
| `backends/openvpn/Backend.qml` | The OpenVPN strategy: unit naming, import. |
| `backends/openvpn/Config.js` | `.ovpn` parsing and rewriting. |
| `bin/install-profile` | Privileged helper. Untrusted caller — validates everything. |
| `bin/stage-profile` | Unprivileged staging, runs as the user. |

## The three constraints that shaped this

All three were found by reading the system, not by guessing, and each one
invalidates an obvious design.

**1. `ProtectHome=true` in the stock unit.** The service sees an empty `/home`,
so a profile referencing `askpass /home/you/...` starts and then dies. Import
must rewrite every file-valued directive to sit beside the config. This is what
`backends/openvpn/Config.js` exists for. The test profile hits it exactly.

**2. `/etc/openvpn/client` is `0750 openvpn:network`, and `network` is empty.**
Shipped that way by the openvpn package's tmpfiles, so it is true on every Arch
machine — not local drift. An unprivileged process cannot list that directory,
stat a file in it, or traverse into it. **Profile enumeration therefore cannot
be unprivileged**, which is why `ProfileStore.qml` keeps a user-side index and
why `rescan` (a privileged `list`) is user-initiated and never polled.

**3. `omarchy-pkg-add` shells out to `sudo`**, which has no tty inside the
shell process. Never call it from QML. `omarchy-install-app` runs it inside
Omarchy's themed floating terminal, which does have one.

`wg-quick` has the same shape — it re-execs itself under `sudo` when `$UID`
is not 0 — so it too must only ever be reached through its unit, never run
directly from the widget.

## How this plugin is loaded

`manifest.json` declares `kinds: ["bar-widget"]` and points
`entryPoints.barWidget` at `Panel.qml`. The long-running `omarchy-shell`
process discovers the folder, mounts `Panel.qml` into a bar slot, and injects
two properties into it:

- `bar` — the parent bar (theme colors via `bar.foreground`, `bar.urgent`,
  `bar.fontFamily`; panel switching via `bar.switchPanelFrom`)
- `settings` — this widget's inline entry from `~/.config/omarchy/shell.json`

Plugins run **inside** the shell process, unsandboxed, with the user's
permissions. Never start a second Quickshell process. Never add symlinks to
this folder — validation rejects them.

`Panel.qml` derives from `Panel` in `qs.Ui`, which supplies
`open()`/`close()`/`toggle()`, `opened`, `controller`, `barForeground`, and
`setting(name, fallback)`. The base type is imported from the module even
though this file is also named `Panel.qml` — that is the established
first-party pattern, not an accident.

## Dependencies — the rule that is easiest to get wrong

**`pacman -Q` is not evidence.** Whether a package is installed on this laptop
says nothing about a stranger's machine. This mistake was made once already
during design: `openvpn` is here only because it was installed by hand for a
personal PiVPN setup, and it was briefly treated as ambient.

The only guarantee is `/usr/share/omarchy/install/omarchy-base.packages`
(149 lines, present on every Omarchy install). Verify against that file.

Known-good: `networkmanager`, `python-gobject`, `nftables` (transitively).
NOT in base: `openvpn`, `wireguard-tools`.

**Omarchy has no plugin dependency mechanism at all.** `manifest.json` has no
dependency field, `omarchy-plugin-validate` only checks
schemaVersion/required fields/entry points/symlinks, and `omarchy-plugin-add`
is clone → validate → move → rescan → enable with no dependency step anywhere.
We own the whole flow.

Binding principles: check with `omarchy-cmd-missing`, degrade rather than
crash, **never call pacman/yay ourselves** (hand off to
`omarchy-install-app "OpenVPN" openvpn`), document exact package names in the
README, and prefer zero deps.

**Degrade lazily.** Never gate the whole widget on a missing binary — a
WireGuard-only user must never see an OpenVPN warning. Check at the point of
use: importing, or activating a profile. `test/dependency.test.sh` enforces
this by walking every call site of `_ensureDependency`.

## Useful Omarchy helpers (all in base)

```bash
omarchy-cmd-missing cmd...    # exit 0 if ANY named command is absent
omarchy-cmd-present cmd...    # exit 0 if ALL are present
omarchy-file-select --title T --extensions "ovpn conf"   # portal file chooser
omarchy-install-app "Name" pkg…   # themed floating terminal, runs omarchy-pkg-add
```

## Conventions to follow

- **No backend names outside the backend.** No runtime file except
  `Backends.qml` may contain the string "openvpn". This is mechanically checked
  by `test/architecture.test.sh`, which also caps `Backends.qml` at 20 lines of
  code so protocol logic cannot quietly move in.
- **Optimistic state.** A pending id steers the UI while a command is in
  flight; the poll is the source of truth and clears it once it agrees. A
  timeout unsticks the switch if confirmation never lands. Read the service's
  `isActive(x)` helper in the UI, never a raw `state` field.
- **Reassign, don't mutate.** Object and array properties are replaced
  wholesale — mutating in place does not fire change notifications in QML.
  The corollary is a trap: the poll replaces the whole tunnel list on every
  tick, so a rebuild from an explicit field list silently drops any field the
  caller forgot to restate. `Model.makeTunnel()` is therefore only for
  `rebuild()`, which genuinely builds from the index; every other path uses
  `Model.updateTunnel(tunnel, changes)`, which carries the rest forward. This
  is mechanically checked — a field that survives import and vanishes seconds
  later is nearly impossible to read as a *state* bug.
- **`instanceof Array` is unreliable across contexts.** `Model.js` and each
  `Config.js` are `.pragma library`, each with its own JavaScript context, so
  an array built in a QML component is not an instance of *that* file's
  `Array`. Duck-type instead (and exclude strings, which have a length too).
- **Theme through the bar.** Use `root.foreground` / `dim` / `urgent` /
  `fontFamily` and `Style.space(n)`, never literal colors or pixel values. The
  guards (`bar ? bar.foreground : Color.foreground`) matter: the bar-widget
  contract instantiates the item bare before injecting `bar`.
- **The privileged helper trusts nothing.** Its caller is unprivileged, so the
  destination directory is chosen inside the helper from a protocol token, the
  profile name must match a strict pattern, and the staging directory may
  contain only regular files. Changing any of those needs a test.
- **Settings writes** go through `persistSettings()` in `Panel.qml`: apply
  locally first, then `bar.shell.updateEntryInline`. With no writable entry it
  degrades to session-only, which is intended.

## Workflow

```bash
./run-tests.sh                             # no root, ~3s
./run-tests.sh --integration               # real tunnel in a netns (sudo)
./validate.sh                              # manifest + qmllint + live IPC
omarchy-shell shell rescanPlugins          # pick up new/renamed files
omarchy restart shell                      # pick up EDITS — see below
omarchy plugin enable connor.vpn           # add to the bar
omarchy-shell connor.vpn state             # structured state as JSON
journalctl --user -u omarchy-shell -f      # QML errors land here
```

Editing a QML file does **not** hot-reload. `rescanPlugins` picks up new and
renamed files but keeps the mounted copy of an edited one, so a changed
`Panel.qml` silently keeps running the old code — the giveaway is
`omarchy-shell connor.vpn state` answering `Function not found.` Restart the
shell.

### Testing

Four tiers, in `run-tests.sh`:

- **Tier 1** — pure functions in `Model.js` and `Config.js`. `node`, no root.
  `test/harness/escape.test.sh` additionally pins the systemd escaper against
  the real `systemd-escape` binary, because getting escaping wrong does not
  fail loudly — it starts the wrong unit.
- **Tier 2** — `test/harness/up.sh`. Generates a throwaway CA, runs an OpenVPN
  server in a network namespace, and connects through the real unit. Every
  assertion runs the plugin's own parsers against real kernel output, which is
  what catches a parser that drifts from reality. Needs root; opt-in.
- **Tier 3** — `omarchy-shell connor.vpn state` returns structured JSON, so
  panel logic is asserted on without screenshots.
- **Tier 4** — `test/dependency.test.sh`. Simulates the stranger's clean
  machine with a fake PATH and proves the widget renders, does not warn on
  load, and warns only at the point of use.

Tier 2 is verified green against a real tunnel: the unit starts, `tun0`
appears, byte counters move in both directions, and `parseResolvers` /
`parseAddresses` are exercised against genuine `resolvectl` and `ip -j` output
rather than fixtures.

### Two facts that cost a session to establish

**`stdinEnabled = false` closes stdin and sends EOF.** Quickshell's docs do not
say so, and the first-party precedent (`network/Panel.qml` piping a Wi-Fi
password to `nmcli`) never needs EOF, so it does not settle the question. The
import path depends on it: `bin/stage-profile` ends in `cat > "$file"`, which
blocks forever without EOF. Verified with a throwaway `quickshell -p` config
running `cat` and checking the file was written and the process exited 0. If a
process that reads stdin ever hangs, this is the first thing to check.

**`stdinEnabled = false` only sends EOF on a CHANGE, so it must be re-armed.**
Found the hard way: the first import of a shell session worked and every one
after it hung. After a run the property is already `false`, so the next run's
`stdinEnabled = false` fires no change, the pipe is never closed, and
`stage-profile`'s `cat` waits forever — with the whole config already written,
which is what makes it look like a parsing problem rather than a plumbing one.
Set `stdinEnabled = true` before starting the process every time.

The same shape bites any property whose effect is the transition rather than
the value: assigning a `FileView` the path it already holds triggers no read,
so re-importing the same file sits at "Reading…" forever. Both are pinned by
`test/architecture.test.sh`. **When a symptom is "worked once, then hung",
look for an assignment that is a no-op the second time.**

**A tunnel can be tested without root, using a user namespace.**

```bash
unshare --user --map-root-user --net -- bash -c '
  ip link set lo up
  openvpn --config server.conf --cd "$D" --log "$D/s.log" &   # NOT --daemon
  sleep 4
  openvpn --config client.ovpn --cd "$D" --log "$D/c.log"
'
```

This gives `CAP_NET_ADMIN` inside a private netns, so both ends run and a real
`tun0` appears — enough to check certificates, the TLS handshake, and device
creation with no `sudo` at all. Two traps: `--daemon` does not return control
to the shell (background it with `&` instead), and piping the output to `tail`
loses it when the outer `timeout` fires (redirect to a file).

It cannot replace Tier 2, because `systemctl start` on a system unit needs real
root — but it is the fastest way to isolate anything below that line, and it is
how the kill-switch rules in Phase 4 should be developed so the host's nftables
ruleset is never touched.

Two refinements found while building the WireGuard harness section:

- **`/sys` inside the namespace is still the host's.** `/sys/class/net` shows
  the host's interfaces, so a byte-counter read finds nothing. `mount -t sysfs
  none /sys` (with `--mount`) fixes it.
- **A second namespace, for the far end, needs `/run` to be writable.**
  `ip netns add` writes to `/run/netns`, which is real root's tmpfs and refuses
  a mapped root. `mount -t tmpfs none /run` first. Then a WireGuard interface
  can be created in the outer namespace and moved in with `ip link set <dev>
  netns <ns>` — its UDP socket stays behind, which is what makes the two ends
  reachable over loopback.

Still needs a human: visual polish, the polkit prompt appearing from the QML
plugin, and a real-world connection as a final sanity check.

**`systemctl start` succeeding does not mean the tunnel came up.**
`openvpn-client@.service` is `Type=notify`, and OpenVPN signals `READY` before
the TLS handshake — so `start` returns 0 with a *wrong password*, and the
rejection lands a second or two later. Any assertion about whether a
connection actually worked has to watch what the unit does after the exchange:
poll for it to leave active on the failure side, and wait for OpenVPN's
`Initialization Sequence Completed` on the success side. `is-active` right
after `start` is true in both cases. The same timing trap makes a journal read
too early answer with the version banner, which looks like a parser bug and is
not.

Three harness lessons worth keeping, each of which cost a debugging round:
generated certs need `keyUsage` as well as `extendedKeyUsage` or
`remote-cert-tls server` fails with a misleading trust error; a `check`
that prints no detail on failure hides the log that explains it; and
**`command -v node` does not mean node runs.**

That last one is the dangerous shape. A version manager puts a shim on PATH
that is present and executable but exits non-zero, printing nothing on stdout,
when no version is pinned for the directory. Every `$NODE` call then yields an
empty string — and an assertion of the form `[[ -z $result ]]` *passes*. One
integration run reported `ok` for a check while nothing whatsoever had been
tested. `test/find-node.sh` therefore resolves node by **running** a candidate,
not by finding one, and any assertion whose expected value is empty must carry
a marker (`ran:`) so "found nothing" and "never ran" cannot be confused.

### Three things that look like bugs and are not

- **`qmllint` fails on `Panel.qml` with exit 255 and no message.** It cannot
  parse Quickshell's typed IPC functions (`function open(): void`) and dies with
  "Unexpected token `void`" — on the shipped first-party plugins too.
  `validate.sh` and `run-tests.sh` skip it deliberately. Other QML files lint
  clean; keep them that way.
- **`IpcHandler ... will not be used because another handler is registered for
  target connor.vpn`** in the journal. The bar instantiates the widget once per
  monitor (three here), so only the first handler binds. Every first-party panel
  logs the same line. Harmless.
- **`omarchy plugin list` reports `active: false`** even when the widget is
  mounted and answering IPC. Not a health check — the IPC call is the real one.

## Reference plugins

- `/usr/share/omarchy/shell/plugins/panels/tailscale/` — closest structural
  analogue (service + panel + model split, `which`-probe degradation). Note its
  degradation **dead-ends at a message** and never offers to install; our
  never-open-a-terminal requirement means we go further.
- `/usr/share/omarchy/shell/plugins/panels/network/` — already shows physical-
  interface rx/tx, router/internet ping, and packet loss via
  `omarchy-network-status --verbose`. **Do not duplicate these.** Our stats are
  tunnel-scoped.

## Still open

- `wg-quick@.service` shipping with `wireguard-tools` is **unverified** —
  `pacman -Fl` needs `pacman -Fy` first (root + network). Only gates the
  WireGuard backend, which is out of MVP scope.
- ~~Whether NetworkManager tries to manage `tun0`.~~ **ANSWERED: it does not.**
  During a Tier 2 run NM logged `manager: (tun0): new Generic device` and
  `carrier: link connected` — it registers an externally created tun device as
  Generic and observes it, but assigns no address, route or DNS. The harness's
  route, address and resolver assertions all passed while that device was up,
  which is the evidence it did not interfere. No `[keyfile] unmanaged-devices`
  entry is needed. (Caveat: the harness tunnel is short-lived and deliberately
  does not push a default route. A full-tunnel profile is worth one more look.)
- Secret storage for `auth-user-pass` credentials. Currently a profile needing
  interactive credentials warns at import and will not start.
- Post-MVP, all structurally accommodated but not implemented: WireGuard, kill
  switch, split tunnelling, auto-connect on untrusted Wi-Fi, OTP/2FA, exit-IP
  geo, endpoint latency.
