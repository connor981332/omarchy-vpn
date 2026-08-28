#!/bin/bash
# Tier 4: the failure mode that cannot be reproduced locally — a stranger's
# machine where the VPN binary is simply not there.
#
# The requirement is not "detect it". It is "detect it lazily": the widget must
# render, must NOT warn on load, and must warn only when the user reaches for
# the thing that needs it. A WireGuard-only user must never see an OpenVPN
# warning. That is asserted three ways below — against the real probe, against
# the live plugin, and against the call sites.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0
fail=0

check() {
  local name="$1" result="$2" detail="${3-}"
  if [[ $result -eq 0 ]]; then
    echo "ok - $name"; pass=$((pass + 1))
  else
    echo "not ok - $name"; [[ -n $detail ]] && echo "$detail" | sed 's/^/  /'; fail=$((fail + 1))
  fi
}

echo "# the probe means what the service thinks it means"
# omarchy-cmd-missing exits 0 when ANY named command is absent — the inverted
# sense is easy to get backwards, and getting it backwards would warn every
# user on every machine.
FAKE="$(mktemp -d)"
trap 'rm -rf "$FAKE"' EXIT
printf '#!/bin/sh\nexit 0\n' > "$FAKE/definitely-here"
chmod +x "$FAKE/definitely-here"

# Invoked by absolute path: the probe has to survive a PATH that does not
# contain the probe itself, which is the whole point of the fake PATH.
PROBE="$(command -v omarchy-cmd-missing)"

PATH="$FAKE" "$PROBE" definitely-here >/dev/null 2>&1
check "exit 1 when the command is present" $(( $? == 1 ? 0 : 1 ))

PATH="$FAKE" "$PROBE" openvpn >/dev/null 2>&1
check "exit 0 when the command is absent (the stranger's machine)" $(( $? == 0 ? 0 : 1 ))

# And the mixed case: one present, one absent, which is what a multi-command
# backend looks like half-installed.
PATH="$FAKE" "$PROBE" definitely-here openvpn >/dev/null 2>&1
check "exit 0 when ANY of several is absent" $(( $? == 0 ? 0 : 1 ))

# The service reads `exitCode === 0` as missing. Pin that reading.
if grep -q 'var missing = exitCode === 0' Service.qml; then
  check "Service.qml reads the probe in the correct sense" 0
else
  check "Service.qml reads the probe in the correct sense" 1 \
    "$(grep -n 'exitCode' Service.qml | grep -i miss)"
fi

echo "# the dependency matrix, in both directions"
# The requirement that survives adding a second backend: a user of one
# protocol must never be warned about the other's missing binary. With two
# backends registered this is now testable rather than aspirational.
printf '#!/bin/sh\nexit 0\n' > "$FAKE/openvpn"; chmod +x "$FAKE/openvpn"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/wg"; chmod +x "$FAKE/wg"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/wg-quick"; chmod +x "$FAKE/wg-quick"

# OpenVPN present, WireGuard absent.
PATH="$FAKE" "$PROBE" openvpn >/dev/null 2>&1
a=$?
PATH="$FAKE" "$PROBE" wg wg-quick >/dev/null 2>&1
b=$?
check "with only OpenVPN installed, only WireGuard reads as missing" \
  $(( a == 1 ? 0 : 1 ))
rm -f "$FAKE/wg" "$FAKE/wg-quick"
PATH="$FAKE" "$PROBE" wg wg-quick >/dev/null 2>&1
check "  ...and it does read as missing" $(( $? == 0 ? 0 : 1 ))

# And the mirror image, which is the case that actually regressed historically:
# a WireGuard-only user seeing an OpenVPN warning.
printf '#!/bin/sh\nexit 0\n' > "$FAKE/wg"; chmod +x "$FAKE/wg"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/wg-quick"; chmod +x "$FAKE/wg-quick"
rm -f "$FAKE/openvpn"
PATH="$FAKE" "$PROBE" wg wg-quick >/dev/null 2>&1
check "with only WireGuard installed, WireGuard reads as present" $(( $? == 1 ? 0 : 1 ))
PATH="$FAKE" "$PROBE" openvpn >/dev/null 2>&1
check "  ...and OpenVPN is the one reported missing" $(( $? == 0 ? 0 : 1 ))

# A half-installed backend must read as missing, not as present: wireguard-tools
# ships both binaries, so one without the other is a broken install.
printf '#!/bin/sh\nexit 0\n' > "$FAKE/wg"; chmod +x "$FAKE/wg"
rm -f "$FAKE/wg-quick"
PATH="$FAKE" "$PROBE" wg wg-quick >/dev/null 2>&1
check "a half-installed backend counts as missing" $(( $? == 0 ? 0 : 1 ))

# Every registered backend must declare what to probe for and what to install,
# or the card renders with an empty button.
for field in protocol label packageName commands; do
  missing=""
  for backend in backends/*/Backend.qml; do
    grep -qE "property (string|var|int) $field" "$backend" || missing+=" $backend"
  done
  if [[ -z $missing ]]; then
    check "every backend declares $field" 0
  else
    check "every backend declares $field" 1 "$missing"
  fi
done

echo "# nothing checks a dependency on load"
# Every call site of the check, so a new one cannot be added on a load path
# without this failing.
sites="$(grep -n '_ensureDependency(' Service.qml | grep -v 'function _ensureDependency')"
# _startDependencyWatch and _watchTick are the post-install poll. They are on
# the allowlist only because the next block proves the watch is reachable from
# the install hand-off and from nowhere else.
expected="connectTunnel|beginImport|recheckDependency|_startDependencyWatch|_watchTick"
bad=""
while IFS= read -r line; do
  [[ -z $line ]] && continue
  lineno="${line%%:*}"
  # The enclosing function is the nearest preceding `function name(` line.
  fn="$(head -n "$lineno" Service.qml | grep -oE '^  function [A-Za-z_]+' | tail -1 | awk '{print $2}')"
  [[ $fn =~ ^($expected)$ ]] || bad+="  line $lineno is inside ${fn:-<top level>}"$'\n'
done <<< "$sites"

if [[ -z $bad ]]; then
  check "dependency checks only happen at the point of use" 0
else
  check "dependency checks only happen at the point of use" 1 "$bad"
fi

echo "# the post-install watch clears the card by itself"
# The defect this replaces: omarchy-install-app execs a DETACHED terminal, so
# installProcess exits on launch, not on completion. A single recheck there
# always reported the package still missing and stranded the card.

# 1. The install hand-off starts the watch, and does not just re-check once.
if grep -n 'onExited' -A 6 Service.qml | grep -q '_startDependencyWatch'; then
  check "the install hand-off starts a watch" 0
else
  check "the install hand-off starts a watch" 1 \
    "$(grep -n 'installProcess' -A 12 Service.qml | tail -14)"
fi

# 2. The watch is started from the install path ONLY — never on load, never
#    from the poll. This is what buys the two allowlist entries above.
starts="$(grep -n '_startDependencyWatch(' Service.qml | grep -v 'function _startDependencyWatch')"
if [[ $(printf '%s\n' "$starts" | grep -c .) -eq 1 ]]; then
  startline="${starts%%:*}"
  ctx="$(sed -n "$((startline > 12 ? startline - 12 : 1)),${startline}p" Service.qml)"
  if grep -q 'id: installProcess' <<< "$ctx"; then
    check "the watch is only ever started by the install hand-off" 0
  else
    check "the watch is only ever started by the install hand-off" 1 "$ctx"
  fi
else
  check "the watch is only ever started by the install hand-off" 1 "$starts"
fi

# 3. It is bounded. An unbounded poll would fork forever on a declined install.
if grep -q '_depWatchTicks -= 1' Service.qml \
   && grep -qE '_depWatchTicks = [0-9]+' Service.qml \
   && grep -q '_depWatchTicks <= 0' Service.qml; then
  check "the watch is bounded and gives up" 0
else
  check "the watch is bounded and gives up" 1 \
    "$(grep -n '_depWatchTicks' Service.qml)"
fi

# 4. It stops the moment the probe comes back clean — that is what clears the
#    card without the user pressing Re-check.
if grep -n 'var missing = exitCode === 0' -A 14 Service.qml | grep -q '_stopDependencyWatch'; then
  check "a clean probe stops the watch and clears the card" 0
else
  check "a clean probe stops the watch and clears the card" 1 \
    "$(grep -n 'var missing = exitCode === 0' -A 14 Service.qml)"
fi

# 5. Re-probing must not blank the recorded answer first: doing so makes the
#    card vanish and reappear on every tick.
if grep -n 'function recheckDependency' -A 4 Service.qml | grep -q 'missingDeps = next'; then
  check "re-checking does not blink the card" 1 \
    "$(grep -n 'function recheckDependency' -A 4 Service.qml)"
else
  check "re-checking does not blink the card" 0
fi

# 6. Giving up must not be silent. Reverting the button from "Waiting..." to
#    "Install" with no message makes a declined install, a failed install and a
#    slow mirror indistinguishable.
if grep -n 'function _dependencyWatchExpired' -A 8 Service.qml | grep -q 'lastError'; then
  check "running out of budget explains itself" 0
else
  check "running out of budget explains itself" 1 \
    "$(grep -n 'function _dependencyWatchExpired' -A 8 Service.qml)"
fi

# 7. And the exhausted-budget branch must route through that function rather
#    than stopping silently, which is the regression that would restore the gap.
if grep -n '_depWatchTicks <= 0' -A 2 Service.qml | grep -q '_dependencyWatchExpired'; then
  check "an exhausted budget takes the explaining path" 0
else
  check "an exhausted budget takes the explaining path" 1 \
    "$(grep -n '_depWatchTicks <= 0' -A 2 Service.qml)"
fi

# 8. A retry must not sit under the previous attempt's failure message.
if grep -n 'function installDependency' -A 10 Service.qml | grep -q 'lastError = ""'; then
  check "starting an install clears a stale failure message" 0
else
  check "starting an install clears a stale failure message" 1 \
    "$(grep -n 'function installDependency' -A 10 Service.qml)"
fi

# 9. The manual escape hatch survives. The card must still offer Re-check.
if grep -q 'onClicked: vpn.recheckDependency' Panel.qml; then
  check "the manual Re-check button is still there" 0
else
  check "the manual Re-check button is still there" 1
fi

# The load path itself.
if grep -nE 'Component\.onCompleted.*(_ensureDependency|depProcess)' Service.qml >/dev/null 2>&1; then
  check "Component.onCompleted does not probe" 1
else
  check "Component.onCompleted does not probe" 0
fi

if grep -nE 'function refresh\(\)' -A 12 Service.qml | grep -q '_ensureDependency'; then
  check "the poll does not probe" 1
else
  check "the poll does not probe" 0
fi

echo "# the panel scopes the warning to one protocol"
# The dependency card is rendered inside the per-backend Repeater and keyed on
# that backend's own protocol, so it cannot appear for a protocol the user does
# not use.
if grep -q 'depMissing: vpn.missingDeps\[backend.protocol\] === true' Panel.qml; then
  check "the card is keyed on its own section's protocol" 0
else
  check "the card is keyed on its own section's protocol" 1
fi

if grep -q 'visible: section.depMissing' Panel.qml; then
  check "the card renders only for the section that is missing something" 0
else
  check "the card renders only for the section that is missing something" 1
fi

# Nothing gates the whole widget on a dependency.
if grep -nE '^\s*visible:.*(missingDeps|installed)' Panel.qml | grep -v 'section\.' >/dev/null 2>&1; then
  check "no top-level visibility gate on a dependency" 1 \
    "$(grep -nE '^\s*visible:.*(missingDeps|installed)' Panel.qml)"
else
  check "no top-level visibility gate on a dependency" 0
fi

echo "# the live plugin has not probed anything"
if command -v omarchy-shell >/dev/null 2>&1; then
  state="$(omarchy-shell connor.vpn state 2>/dev/null || true)"
  if [[ -z $state || $state == "Function not found."* ]]; then
    echo "ok - SKIP: plugin is not mounted (restart the shell to include this check)"
    pass=$((pass + 1))
  else
    deps="$(printf '%s' "$state" | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["missingDeps"]))')"
    if [[ $deps == "{}" ]]; then
      check "a freshly started widget has probed no dependency" 0
    else
      check "a freshly started widget has probed no dependency" 1 "missingDeps=$deps"
    fi
  fi
else
  echo "ok - SKIP: omarchy-shell not available"
  pass=$((pass + 1))
fi

echo "# never install anything ourselves"
if grep -q 'omarchy-install-app' Service.qml && ! grep -qE '"(pacman|yay|paru)"' Service.qml; then
  check "installs are handed off to omarchy-install-app" 0
else
  check "installs are handed off to omarchy-install-app" 1
fi

echo "1..$((pass + fail))"
echo "# pass $pass  fail $fail"
[[ $fail -eq 0 ]]
