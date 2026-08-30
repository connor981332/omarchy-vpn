# connor.vpn — Future work

Six features that were scoped and deliberately not built. They are recorded
here so they are not lost by omission, and because "we didn't get to it" and
"the architecture forbids it" are very different answers — three of these are
an afternoon each, one is effectively closed, and two are subsystems.

Everything below is possible. The architecture was built expecting most of it:
adding WireGuard cost two lines in `Backends.qml` plus a folder, and the kill
switch cost one new helper and no changes to the control plane. See
`ARCHITECTURE.md` for the seams these would plug into.

Ordered by what I would build next.

---

## 1. Endpoint latency and VPN overhead

**What it is.** Round-trip time to the VPN endpoint, and the overhead the
tunnel adds — endpoint RTT measured against a pre-connect baseline. Distinct
from the built-in network widget's internet ping, which measures the physical
interface.

**Why it was left out.** Time, and nothing else. It was specified as a Tier 3
stat and simply did not make the four phases.

**What it would take.** A sampler in `Telemetry.qml` beside the existing ones,
a `StatRow` in the panel, and a `Model.js` function to format the result. It is
unprivileged (`ping`, in base via `iputils`), protocol-agnostic, and needs no
helper change and no new dependency.

The only real design question is cost. It must follow the existing rule that
expensive probes run **only while the popup is open**, and it wants a baseline
captured before connecting — which means storing one number per profile in the
index, or accepting that overhead is only meaningful when you have a
disconnected sample to compare against.

**Effort: an afternoon.** The smallest item here, and it fills the one visible
hole in the stats the panel already shows.

---

## 2. Exit-IP geolocation

**What it is.** Coarse location — city and country — for the exit address the
panel already displays.

**Why it was left out.** The exit IP itself shipped; geo did not, because it is
not simply an extra field. The exit-IP lookup is **the only thing in this
plugin that ever contacts a third party**, which is why `showExitIp` is off by
default and carries an explicit privacy note in the README.

**What it would take.** Mechanically, almost nothing: a provider that returns
geo alongside the address, a wider parse, another `StatRow`. The work is the
part that is not mechanical — adding geo widens what is disclosed to that
service, and it deserves the same treatment the exit IP got rather than being
folded in quietly. That means naming the provider in the README, keeping it
behind the same off-by-default setting, and being honest that a coarse location
is derived from an address the provider now knows you are using.

**Effort: an afternoon of code, plus a decision about disclosure.**

---

## 3. Profile editing in the UI

**What it is.** Change a profile after importing it, rather than deleting and
re-importing. The original scope called for the full lifecycle in the UI:
import, edit, delete, credentials. Three of the four shipped.

**Why it was left out.** A constraint, not time. `/etc/openvpn/client` is
`0750 openvpn:network` with an empty `network` group, so **we cannot read back
a profile we installed.** Every other feature works around that by keeping a
user-side index; editing cannot, because an editor needs the actual file.

**What it would take.** A privileged `read` verb on `bin/install-profile` — and
that is the whole problem. It turns a helper that only ever *writes* into one
that hands file contents to an unprivileged caller, and those files contain
private keys and the credential file. Any bug in the name validation becomes an
arbitrary-file-read as root rather than a misplaced write.

If built, it should be narrow: read only the config file, never `<name>.*`;
refuse the credential extension explicitly rather than by omission; and strip
inline `<key>` blocks before returning, so the editor never receives key
material it does not need. The UI side is easy — `stage-profile`,
`install-profile install`, and `Config.js` already do the writing, and the
shell's `Ui` module has a `TextField`.

**Effort: a day, most of it spent on the helper's read path and its tests.**

---

## 4. Auto-connect on untrusted Wi-Fi

**What it is.** An SSID allowlist or denylist: connect automatically on
networks you have not marked as trusted.

**Why it was left out.** It is the only feature that would make the widget
**act on its own**, and that changes its risk profile. Everything the plugin
does today is a response to a click.

**What it would take.** Three parts. SSID awareness, which means subscribing to
NetworkManager over D-Bus — NM is in base and already manages Wi-Fi, so this is
the one place where reading NM state is right even though driving it was
rejected. A settings UI for the list. And a policy for the cases that make it
hard:

- **Captive portals.** Connecting a VPN before you have authenticated to the
  network means the portal is unreachable and the user is stuck, especially
  with the kill switch armed.
- **Tethering and known-unknown networks.** What happens on an SSID that is on
  neither list.
- **Boot and resume.** An auto-connect that fires before the session is fully
  up interacts badly with the kill switch's deliberate lack of persistence.

**Effort: a few days, most of it policy rather than code.** The D-Bus
subscription is the easy part; deciding what the widget does when it is wrong
is the work.

---

## 5. Split tunnelling

**What it is.** Send only some traffic through the tunnel. Two quite different
features share the name: **route-based** splitting (these subnets go through
the tunnel) and **per-app** splitting (this application goes through the
tunnel, everything else does not).

**Why it was left out.** It is the largest item here, and per-app splitting
needs machinery nothing else in the plugin uses: a cgroup or network namespace
per application, an `fwmark` to tag its packets, and a policy-routing table
selected by that mark. That is a second owner of routing sitting beside the
kill switch's nftables rules — and "two owners of the route table" is precisely
the objection that got NetworkManager rejected as the control plane. Putting
ourselves in that position needs a real design, not an increment.

**What it would take.** Route-based first, and it is much the easier half:
`ip route` additions scoped to the tunnel device, which the telemetry plane
already reads and the kill switch already accounts for via `oifname`. It is
mostly a UI for entering subnets plus a privileged helper verb.

Per-app is the real project. It would want its own helper (as the kill switch
got one), rules that compose with the kill switch's table rather than fighting
it, and the same namespace-based test harness — `unshare --user --net` can
model the whole thing without root, which is how the kill switch rules were
developed.

**Effort: route-based, a couple of days. Per-app, a project.**

---

## 6. OTP / two-factor authentication

**What it is.** Profiles that ask for a one-time code, or issue a dynamic
challenge, in addition to a username and password.

**Why it was left out.** This one is **blocked by the central architectural
decision**, not by time or by a policy question. The original design drove
OpenVPN over a management socket owned by a privileged daemon of ours, which is
the clean way to answer an interactive prompt: the socket reports
`>PASSWORD:Need ...` and accepts the reply. What shipped uses the *stock*
`openvpn-client@.service`, whose management socket is root-owned — and reading
it means holding privilege inside the shell process, which is the one thing
this design refuses to do.

**What it would take.** One of two things, and both are a different plugin from
the one described in `ARCHITECTURE.md`:

- **Ship our own unit file** with a management socket we can reach, abandoning
  the "no daemon, no unit file, no policy of our own" property that makes this
  plugin auditable in an afternoon.
- **Ship a privileged broker** that owns the socket and exposes a narrow
  interface to the unprivileged widget. Smaller than a full daemon, but it is
  still a long-running root process we wrote, and it would need to be as
  carefully argued as the two helpers are today.

There is no third option: a stock unit gives no way to answer a prompt, and a
static credential file cannot contain a code that changes every thirty seconds.

**Effort: a redesign.** Worth doing only if enough users need it to justify
giving up what the current control plane buys — and if so, it should be
designed deliberately rather than bolted on.

---

## 7. Keeping a script hook you actually trust

Import removes every directive that would let a profile run code or write files
as root — see the import boundary in `ARCHITECTURE.md`. That is the right
default for a downloaded profile, and it is the only safe default when the
widget cannot tell a provider's file from one you wrote yourself.

It does mean a user with a genuine hook of their own has nowhere to put it. The
missing piece is a way to say "I wrote this line, keep it": the removed lines
are already carried through the plan verbatim and shown in the panel, so the UI
half is a confirmation on top of what is displayed today.

The hard half is the privileged one. `bin/install-profile` refuses these
directives outright, and it has to — its caller is unprivileged, so any flag
saying "the user approved this" is a flag an attacker can also pass. Doing this
properly means the approval has to be something the helper can verify itself,
which is a polkit action of its own with its own prompt text, naming the
command that will run as root.

**Effort: a day, most of it on the polkit action and its wording.** Worth doing
only once someone actually asks — on Arch the hooks commercial profiles carry
are Debian scripts that were never installed here in the first place.

---

## Not on this list

Two capabilities are absent for the same reason as OTP and are worth naming so
their absence reads as deliberate:

- **OpenVPN's negotiated cipher and reconnect count** — management socket,
  root-owned.
- **WireGuard's last-handshake age** — `wg show` needs root. There is a test
  asserting it still does, so if that ever changes we will find out.
