# connor.vpn — v1 Plan

Supersedes the MVP plan, which shipped on 2026-08-27: OpenVPN import, connect,
disconnect, delete, Tier 1+2 stats, lazy dependency detection, four green test
tiers (139 assertions), verified end to end against a real PiVPN profile.

Scope decisions live in `REQUIREMENTS.md`. Architecture and conventions live in
`CLAUDE.md`. This is the build order for the next four pieces and how each gets
verified without a human.

## Binding principles (carried forward unchanged)

1. **Check, don't assume.** Probe with `omarchy-cmd-missing <cmd>` (exit 0 if
   any are absent). Never `pacman -Q`. Never assume base contents without
   checking `/usr/share/omarchy/install/omarchy-base.packages`.
2. **Degrade, don't crash.** Missing binary renders a hint, never throws, and
   never gates the whole widget — check at the point of use.
3. **Never auto-install.** No pacman/yay from the plugin. Hand off to
   `omarchy-install-app`.
4. **Requirements in the README**, with exact Arch package names.
5. **Prefer zero deps.** All four phases below cost zero new packages.
6. **No backend names outside `Backends.qml`.** Mechanically enforced.
7. **The privileged helper trusts nothing.** Its caller is unprivileged.
8. **Secrets never in argv.** `/proc/*/cmdline` is world-readable; stdin only.

## Phase order, and why this order

First-run comes before features because it is the only path the target audience
is *guaranteed* to hit and the only major one never actually executed.
WireGuard comes before the rest because it tests the protocol abstraction while
there are still only two backends — if the seams are wrong, that is much
cheaper to learn now. Kill switch is last because it is the only feature that
can leave the machine with no network and no UI.

---

## Phase 1 — First run and publishing readiness

**Goal:** a stranger with no `openvpn` gets from `omarchy plugin add` to a
working tunnel without typing in a terminal.

### The known defect
`installDependency()` runs `omarchy-install-app`, which `exec`s a **detached**
floating terminal. `installProcess.onExited` therefore fires almost immediately
— long before pacman finishes — and the `recheckDependency()` that follows
reports the package still missing. The card stays up and the user has to press
**Re-check** by hand.

Fix: poll for the binary on an interval after the hand-off (a few seconds
apart, capped, stopping on success), so the card clears itself when the install
lands. The manual Re-check button stays as the escape hatch.

### Also unverified
- Does `/etc/openvpn/client` exist immediately after a fresh `pacman -S
  openvpn`? pacman runs tmpfiles on install so it should, but
  `install-profile`'s `systemd-tmpfiles --create` fallback has never run.
- The dependency card has never been rendered on screen. Nobody has seen it.

### Publishing gaps
- **No `LICENSE` file** — the README claims MIT and there is nothing to back it.
- `manifest.json` is at `0.1.0`; every first-party plugin ships `1.0.0`.
- The README's install line still says `https://github.com/<you>/connor.vpn`.

### How to test without a second machine
Either a container, or `sudo mv /usr/bin/openvpn /usr/bin/openvpn.bak` and put
it back afterwards. The tunnel will not start meanwhile; nothing else breaks.

**Done when:** a from-scratch run on a machine without `openvpn` reaches a
connected tunnel with no terminal typing, and `test/dependency.test.sh` asserts
the post-install recheck actually clears the card.

### Status: complete, 2026-08-27

The defect is fixed by a bounded watch (3s interval, 100 ticks, stopping the
instant the probe comes back clean); the manual Re-check button survives as the
escape hatch. Tier 4 grew from 12 to 21 assertions covering it.

Answers to the open questions:

- **`/etc/openvpn/client` after a fresh install: yes, it exists.** The openvpn
  package ships `/usr/lib/tmpfiles.d/openvpn.conf`, and pacman's
  `21-systemd-tmpfiles.hook` runs `systemd-tmpfiles --create` post-transaction,
  after `20-systemd-sysusers.hook` has created the `openvpn` user — so the
  ownership is right too. `require_dir`'s fallback is therefore only reachable
  when someone has deleted the directory. It was exercised anyway, unprivileged,
  against the absent `/etc/wireguard`, and dies with a useful message.
- **The card has now been rendered, and the whole path walked on real hardware**
  — package removed with `pacman -R`, card shown at point of use, install
  handed off, card cleared by itself, tunnel connected.

Two things worth carrying forward:

- **`pacman -R openvpn` does not touch imported profiles.** `pacman -Qo
  /etc/openvpn/client` reports no owner and `pacman -Ql openvpn` lists nothing
  under `/etc/openvpn`, so the directory (a tmpfiles creation) and its contents
  survive. The unit file *is* package-owned and does disappear.
- **Moving the binary aside is a weaker test than it looks.** `omarchy-pkg-add`
  guards on `omarchy-pkg-missing`, which asks `pacman -Q` — the package
  database, not the filesystem — so with the package still registered the
  install is a silent no-op and nothing is exercised. Remove the package to
  test this path for real.

---

## Phase 2 — WireGuard

**Goal:** deliver product goal #1 ("works out of the box with OpenVPN and
WireGuard") and prove the abstraction was worth building.

### Verify before building
- [ ] `wg-quick@.service` ships with `wireguard-tools` (`pacman -Fy` first).
- [ ] Does `wg-quick@.service` set `ProtectHome`? If it does not, path
      rewriting is not strictly required — but do it anyway, for one import
      path rather than two.
- [ ] What mode/owner does `wireguard-tools` give `/etc/wireguard`?
      `install-profile` already claims `root:root`, untested.
- [ ] **Does `wg show` need root?** If it does, last-handshake age is not
      available unprivileged and that Tier 3 stat is dropped rather than
      bought with a polkit prompt.

### The one real architecture change
`wg-quick` names the interface after the config file: `wg0.conf` → `wg0`. The
device is therefore **known in advance**, unlike OpenVPN where it has to be
discovered by diffing the netdev list. So `Backend` gains an optional
`deviceFor(name)`; when a backend implements it the service uses it directly
and `Model.newDevice()` discovery stays the fallback.

This is the honest test of the design: if adding a protocol needs exactly one
new seam, the abstraction held. If it needs more, say so in `CLAUDE.md` rather
than bending the service.

Second, smaller change: WireGuard interface names are capped at 15 characters
(`IFNAMSIZ`), where profile names are currently capped at 64. Name length
becomes a backend property.

### Work
`backends/wireguard/{Backend.qml,Config.js}`, one line in `Backends.qml`. The
config is INI-shaped (`[Interface]` / `[Peer]`), the endpoint comes from
`Peer.Endpoint`, and profiles are normally self-contained — so import is
simpler than OpenVPN's, with no side files in the common case.

**Done when:** import, connect, and stats work for a real WireGuard profile;
Tier 2 brings up a wg tunnel alongside the OpenVPN one; the architecture test
still passes with two backends registered.

### Also in this phase — surface why a tunnel actually failed

Not WireGuard work, but scheduled here because it is the largest first-run gap
left after Phase 1 and it costs no new dependency.

Found on 2026-08-27 while QA'ing Phase 1. Removing the AUR package
`openvpn-update-systemd-resolved`, which provides the `up` hook target
`/usr/bin/update-systemd-resolved`, made a previously working profile fail. The
journal said exactly why:

```
Options error: --up script fails with '/usr/bin/update-systemd-resolved': No such file or directory (errno=2)
```

The panel said only:

```
Job for openvpn-client@framework-omarchy.service failed because the control
process exited with error code. See "systemctl status openvpn...
```

— systemd's job-failed boilerplate, truncated on screen, carrying none of the
actual cause. `systemctl start` never prints the daemon's own stderr, so the
information exists but is not where we are looking.

**Why this matters more than it looks.** A profile that references a hook,
certificate or credential file which is not present is the most likely import
failure a stranger will hit: the `.ovpn` parses and imports cleanly, so nothing
warns, and the failure only appears at connect time. Import already warns about
hooks under `/home` (`ProtectHome`), but a hook pointing at a package-provided
path that simply is not installed passes every check we make. Today the panel's
answer is to go read the journal by hand, which the README has to document.

Work:

- On a failed start, read `journalctl -u <unit> -n 20 --no-pager -o cat` and
  prefer the daemon's own lines over systemd's job wrapper. **Verified
  unprivileged** — reading a system unit's journal needs no root here.
- Extend `Model.cleanError()` to pick the useful line, with Tier 1 cases over
  captured journal text.
- Consider warning at *import* when a hook path does not exist on the system,
  which catches this before the user ever tries to connect.
- Separately, the panel's error row truncated the message regardless of its
  content — check it for elision and give it room to wrap.

**Done when:** a profile with a deliberately bogus `up` path is imported and
started, and the panel names the missing file rather than systemd's boilerplate;
Tier 2 asserts it.

---

## Phase 3 — Credentials

**Goal:** `auth-user-pass` profiles work. Today they warn at import and refuse
to start, which excludes most commercial VPN providers.

### Decided: a root-owned file, mode 0600

Settled 2026-08-27 on evidence, not preference. The tempting answer was the
keyring — `libsecret` and `gnome-keyring` are both in base, the daemon runs,
and `org.freedesktop.secrets` answers on the session bus, so it costs no new
dependency. It is still the wrong choice here.

**The keyring auto-unlocks at login.** `pam_gnome_keyring.so auto_start` is
wired into both `sddm` and `sddm-autologin`, and `secret-tool` returns secrets
with no prompt. So any process running as the user can read them. Against the
realistic attacker:

| Threat | Keyring | Root-only 0600 file |
|---|---|---|
| Stolen / powered-off machine | Encrypted | Covered by FDE (Omarchy default) |
| Malicious process running as the user | **Readable, no prompt** | Not readable |
| Attacker with root | Readable | Readable |

The keyring's only real advantage is encryption at rest, which full-disk
encryption already provides. Against user-level compromise the root-only file
is strictly stronger, because a user process cannot read
`/etc/openvpn/client/` at all.

**The platform agrees, and splits by category rather than by ideology.**
Omarchy deliberately pins Chromium to `--password-store=gnome-libsecret`, so it
does not avoid keyrings for session/app secrets. But NetworkManager — in base,
managing this machine's Wi-Fi — keeps PSKs as plaintext in
`/etc/NetworkManager/system-connections/`, a directory an unprivileged user
cannot even list. System-daemon credentials go in root-only files; session
secrets go in the keyring. A VPN credential consumed by a root systemd unit is
the former.

It is also what OpenVPN natively expects (`auth-user-pass <file>`), so there is
no invented scheme to audit, and it supports reconnect and connect-before-login,
which the keyring cannot.

### Design
- `/etc/openvpn/client/<name>.auth`, mode 0600, owned like the rest of the
  profile. Native two-line format: username, then password. No custom encoding.
- The config gets `auth-user-pass <name>.auth`, exactly as import already
  rewrites `askpass`.
- The README states plainly where credentials live, that they are readable by
  root, and that they rely on disk encryption — no vague reassurance.
- **Residual risk worth naming in the README:** an unencrypted backup of `/etc`
  carries the credential off the encrypted disk. FDE does not travel with a
  tarball.

### Constraints
- Password never in argv. `set-credentials <protocol> <name>` on the helper,
  reading stdin, mirroring how import already streams the config. This is the
  rule the chosen design makes easy to break: the file is simple, so the
  temptation is to pass the password as a shell argument somewhere.
- `clear-credentials`, and deleting a profile must delete its credentials.
- The import-time warning becomes an offer to enter them.
- Failed auth must surface as "wrong username or password", not a unit error.

**Done when:** a profile using `auth-user-pass` imports, prompts once, connects,
and reconnects later without prompting again.

---

## Phase 4 — Kill switch

**Goal:** no traffic leaves outside the tunnel while the switch is on.

### The risk that drives every decision
The danger is not writing wrong firewall rules. It is **leaving the user
offline with no way back** — if the shell crashes while the switch is up, there
is no UI and no network. Everything below follows from that:

- Own a dedicated `inet connor_vpn_killswitch` table and touch nothing else, so
  teardown is `nft delete table` and cannot damage another owner's rules.
  This machine runs Docker, which owns rules of its own — a real collision risk.
- Helper gains `killswitch on <endpoint> <port> <device>`, `off`, and `status`.
- **The README documents the terminal recovery command**
  (`pkexec .../install-profile killswitch off`). A kill switch that can only be
  turned off from a GUI you cannot reach is a trap, and being ideologically
  pure about "never open a terminal" here would be actively harmful.
- The panel shows an unmissable indicator whenever it is armed, including when
  no tunnel is up — that is exactly the state where it is confusing.
- State lives in nftables, not in the widget, so a shell restart reads reality.

### Verify before building
- [ ] Can `nft` add and delete our own table via pkexec without disturbing
      NetworkManager's or Docker's rules?
- [ ] What happens across suspend/resume, and on a reconnect where the server
      resolves to a different endpoint IP?
- [ ] Does the tunnel's own handshake traffic survive the rules? (The switch
      must permit traffic to the endpoint or it deadlocks the connection.)

**Done when:** with the switch armed and the tunnel forcibly killed, no packet
reaches the internet; disarming restores connectivity fully; and a Tier 2 test
asserts both, in a namespace, without touching the host's rules.

---

## Testing additions

The existing four tiers stay. Each phase adds to them rather than inventing a
fifth:

- **Tier 1** — WireGuard config parsing; `cleanError()` against captured
  journal text; credential redaction (assert no secret ever appears in a
  command array or an error string).
- **Tier 2** — a wg tunnel beside the OpenVPN one; a profile with a bogus `up`
  path, asserting the panel reports the missing file and not systemd's
  boilerplate; the kill-switch assertions, run inside the namespace so the
  host's rules are never touched.
- **Tier 3** — `state` JSON grows kill-switch status and credential presence
  (presence only, never the secret).
- **Tier 4** — the post-install recheck; and the dependency matrix gains
  WireGuard, so a machine with one protocol installed and not the other is
  covered in both directions.

One rule learned the hard way during MVP: **a check that prints no detail on
failure hides the log that explains it.** Every new assertion prints the
relevant log on failure.

## Consolidated verify-before-building list

- [ ] `wg-quick@.service` ships with `wireguard-tools`
- [ ] `wg-quick@.service`'s sandboxing directives (`ProtectHome`?)
- [ ] `/etc/wireguard` mode and owner as shipped
- [ ] `wg show` unprivileged?
- [x] `/etc/openvpn/client` exists right after a fresh install — **yes**, via
      the package's tmpfiles and pacman's post-transaction hook (Phase 1)
- [ ] nftables coexistence with Docker and NetworkManager
- [ ] endpoint-permitting rules do not deadlock the tunnel handshake

## Not covered by this plan

`REQUIREMENTS.md` lists these as v1 and they are **deliberately not** in the
four phases above. Recording them so they are not lost by omission:

- **Split tunnelling**, route-based and per-app (needs cgroup/netns + fwmark).
- **OTP / 2FA** — needs the OpenVPN management socket, which is root-owned;
  blocked on a design for reaching it without holding privilege.
- **Auto-connect on untrusted Wi-Fi** (SSID allowlist/denylist).
- **Exit-IP geo** and **endpoint latency / VPN overhead** (Tier 3 stats).
- **Profile editing** in the UI — currently import and delete only.
