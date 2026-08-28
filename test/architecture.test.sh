#!/bin/bash
# "No backend names outside the backend" is the rule that keeps WireGuard from
# being a rewrite instead of a folder. It is only worth stating because it is
# mechanically checkable, so it is checked.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

pass=0
fail=0

check() {
  local name="$1" result="$2" detail="${3-}"
  if [[ $result -eq 0 ]]; then
    echo "ok - $name"
    pass=$((pass + 1))
  else
    echo "not ok - $name"
    [[ -n $detail ]] && echo "$detail" | sed 's/^/  /'
    fail=$((fail + 1))
  fi
}

echo "# protocol names stay inside their backend"

# The shipped runtime: every .qml and .js that is not inside a backend folder
# and is not the registry that instantiates them.
#
# Backends.qml is excluded because something has to name the concrete backends,
# and concentrating that in one 30-line file is exactly what makes the rest of
# the widget checkable. It is size-capped below so it cannot quietly become the
# place protocol logic lives.
runtime_files() {
  find . -type f \( -name '*.qml' -o -name '*.js' \) \
    -not -path './backends/*' -not -path './test/*' -not -path './.git/*' \
    -not -name 'Backends.qml' | sort
}

for protocol in openvpn wireguard wg-quick nmcli NetworkManager; do
  hits="$(runtime_files | xargs grep -lni -- "$protocol" 2>/dev/null || true)"
  if [[ -z $hits ]]; then
    check "no runtime file names '$protocol'" 0
  else
    check "no runtime file names '$protocol'" 1 \
      "$(runtime_files | xargs grep -ni -- "$protocol" 2>/dev/null)"
  fi
done

echo "# the registry stays a registry"
registry_lines="$(grep -cvE '^\s*(//.*)?$' Backends.qml)"
if [[ $registry_lines -le 20 ]]; then
  check "Backends.qml is $registry_lines lines of code (cap 20)" 0
else
  check "Backends.qml has grown to $registry_lines lines — protocol logic belongs in backends/" 1
fi

# It may name backends; it may not implement them.
if grep -nE '\b(Process|systemctl|pkexec|FileView)\b' Backends.qml >/dev/null 2>&1; then
  check "Backends.qml runs nothing" 1 "$(grep -nE '\b(Process|systemctl|pkexec|FileView)\b' Backends.qml)"
else
  check "Backends.qml runs nothing" 0
fi

echo "# the one documented exception"
# bin/install-profile maps a protocol token to a destination directory. That
# mapping is a security control — a caller allowed to choose the directory
# could write anywhere — so it has to live in the privileged helper and cannot
# be pushed out into a backend the caller supplies.
if grep -q 'openvpn) echo "/etc/openvpn/client"' bin/install-profile; then
  check "install-profile owns the destination allowlist" 0
else
  check "install-profile owns the destination allowlist" 1
fi

echo "# the panel never sees a backend-shaped row"
# The starter code handed nmcli rows straight to the UI. Everything the panel
# reads now comes from Model.makeTunnel().
if grep -nE '\.(uuid|serviceType|service_type)\b' Panel.qml >/dev/null 2>&1; then
  check "Panel.qml has no backend-shaped fields" 1 "$(grep -nE '\.(uuid|serviceType)\b' Panel.qml)"
else
  check "Panel.qml has no backend-shaped fields" 0
fi

echo "# the panel reads state through the service's helper"
# Reading a raw `active`/`state` field skips the optimistic-state layer and
# makes a click look dropped.
if grep -nE 'tunnel\.state\s*===\s*"up"' Panel.qml >/dev/null 2>&1; then
  check "Panel.qml uses isActive() rather than a raw state compare" 1 \
    "$(grep -nE 'tunnel\.state\s*===\s*\"up\"' Panel.qml)"
else
  check "Panel.qml uses isActive() rather than a raw state compare" 0
fi

echo "# no literal colors or pixel sizes in the UI"
if grep -nE '(color|Color)\s*:\s*"#[0-9a-fA-F]{3,8}"' Panel.qml >/dev/null 2>&1; then
  check "Panel.qml themes through the bar" 1 "$(grep -nE 'color\s*:\s*"#' Panel.qml)"
else
  check "Panel.qml themes through the bar" 0
fi

echo "# the plugin never invokes a package manager itself"
offenders="$(grep -rnE '"(pacman|yay|paru)"|pkexec[^"]*pacman' --include='*.qml' --include='*.js' . 2>/dev/null || true)"
if [[ -z $offenders ]]; then
  check "no pacman/yay call from QML" 0
else
  check "no pacman/yay call from QML" 1 "$offenders"
fi

echo "# properties that only act on a change are re-armed"
# The bug this catches cost an import: `stdinEnabled = false` is what sends
# EOF to a process reading stdin, and it only sends it on a CHANGE. After one
# run the property is already false, so the next run's assignment fires
# nothing, the pipe is never closed, and the helper's `cat` waits forever with
# the whole payload already written. The first import of a session worked and
# every one after it hung.
if grep -q 'stdinEnabled = false' Service.qml; then
  if grep -q '\.stdinEnabled = true' Service.qml; then
    check "a Process that closes stdin re-arms it before the next run" 0
  else
    check "a Process that closes stdin re-arms it before the next run" 1 \
      "$(grep -n 'stdinEnabled' Service.qml)"
  fi
else
  check "a Process that closes stdin re-arms it before the next run" 0
fi

# Same shape: assigning a FileView the path it already holds is not a change,
# so re-importing the same file never triggers a read.
if grep -q 'importFile.path = path' Service.qml; then
  if grep -B2 'importFile.path = path' Service.qml | grep -q 'importFile.path = ""'; then
    check "a FileView is cleared before being handed the same path again" 0
  else
    check "a FileView is cleared before being handed the same path again" 1 \
      "$(grep -n 'importFile.path' Service.qml)"
  fi
else
  check "a FileView is cleared before being handed the same path again" 0
fi

echo "# the poll may not rebuild a tunnel from scratch"
# makeTunnel() takes an explicit field list, so calling it on the poll path
# drops every field the caller forgot to restate. That is not hypothetical: it
# silently removed a profile's requirements on the first tick after import.
# Only rebuild(), which genuinely constructs tunnels from the index, may use
# it; everything else carries forward with updateTunnel().
makers="$(grep -n 'Model.makeTunnel(' Service.qml)"
bad_makers=""
while IFS= read -r line; do
  [[ -z $line ]] && continue
  lineno="${line%%:*}"
  fn="$(head -n "$lineno" Service.qml | grep -oE '^  function [A-Za-z_]+' | tail -1 | awk '{print $2}')"
  [[ $fn == "rebuild" ]] || bad_makers+="  line $lineno is inside ${fn:-<top level>}"$'\n'
done <<< "$makers"

if [[ -z $bad_makers ]]; then
  check "only rebuild() constructs a tunnel from scratch" 0
else
  check "only rebuild() constructs a tunnel from scratch" 1 "$bad_makers"
fi

echo "# advice lives in the backend, not in the profile index"
# The index stores command names only. Storing the sentence meant the first
# version of the openresolv advice -- which named the wrong package, and broke
# every tunnel that followed it -- stayed on disk after the code was fixed.
if grep -q 'warning:' ProfileStore.qml; then
  check "the profile index stores no advice text" 1 \
    "$(grep -n 'warning:' ProfileStore.qml)"
else
  check "the profile index stores no advice text" 0
fi

# And every requirement a backend advertises must be actionable: a note with
# no package name renders an Install button that installs nothing.
missing_pkg=""
for backend in backends/*/Backend.qml; do
  grep -q 'property var requirements' "$backend" || continue
  # Anchored to the entry indentation, so the backend's own packageName
  # property is not counted as one of its requirements.
  count_cmd="$(grep -cE '^ +command:' "$backend")"
  count_pkg="$(grep -cE '^ +packageName:' "$backend")"
  [[ $count_cmd -eq $count_pkg ]] || missing_pkg+=" $backend ($count_cmd commands, $count_pkg packages)"
done
if [[ -z $missing_pkg ]]; then
  check "every advertised requirement names a package" 0
else
  check "every advertised requirement names a package" 1 "$missing_pkg"
fi

echo "# a secret never reaches an argument list or the state surface"
# /proc/<pid>/cmdline is world-readable, so a password passed as an argument is
# disclosed to every process on the machine for as long as pkexec runs — the
# 0600 file it ends up in does not undo that. The credential command array must
# therefore end at the profile name.
cred_arrays="$(awk '/credentialProcess.command = \[/,/^ *\]/' Service.qml)"
if [[ -z $cred_arrays ]]; then
  check "the credential command array carries no secret" 1 "no credential command array found"
elif grep -qE 'password|_credentialPayload' <<< "$cred_arrays"; then
  check "the credential command array carries no secret" 1 "$cred_arrays"
else
  check "the credential command array carries no secret" 0
fi

# The payload is held only between asking the process to start and its stdin
# existing. If onStarted stops clearing it, the password stays in a QML
# property for the rest of the session.
if grep -A6 'onStarted:' Service.qml | grep -q '_credentialPayload = ""'; then
  check "the credential payload is cleared as soon as it is written" 0
else
  check "the credential payload is cleared as soon as it is written" 1 \
    "$(grep -n '_credentialPayload' Service.qml)"
fi

# stateJson() is a public IPC surface — `omarchy-shell connor.vpn state` prints
# it, and the tests read it. It may report that credentials exist and never
# what they are.
state_body="$(awk '/^  function stateJson\(\)/,/^  }$/' Service.qml)"
if [[ -z $state_body ]]; then
  check "the IPC state surface exposes presence, not secrets" 1 "stateJson() not found"
elif grep -qE 'password|_credentialPayload' <<< "$state_body"; then
  check "the IPC state surface exposes presence, not secrets" 1 \
    "$(grep -nE 'password|_credentialPayload' <<< "$state_body")"
else
  check "the IPC state surface exposes presence, not secrets" 0
fi

# Same rule for the panel: the form may hold what is being typed, but nothing
# may persist it. A settings write would put it in shell.json in plaintext.
if grep -nE 'persistSettings\(.*password|password.*persistSettings' Panel.qml >/dev/null; then
  check "the panel never persists a credential" 1 "$(grep -n 'persistSettings' Panel.qml)"
else
  check "the panel never persists a credential" 0
fi

# The credential UI is gated on a backend property, not on a protocol name —
# the same rule as everything else in the panel.
if grep -q 'supportsCredentials' Panel.qml && grep -q 'supportsCredentials' backends/wireguard/Backend.qml; then
  check "the credential offer is gated on a backend property" 0
else
  check "the credential offer is gated on a backend property" 1 \
    "Panel.qml or a backend does not declare supportsCredentials"
fi

# The config writes `<name>.auth`; the helper writes the file. A disagreement
# produces a profile that installs cleanly and fails at connect time.
cfg_ext="$(grep -oE 'var CREDENTIAL_EXT = "[a-z]+"' backends/openvpn/Config.js | grep -oE '"[a-z]+"' | tr -d '"')"
helper_ext="$(grep -A2 'credential_ext()' bin/install-profile | grep -oE 'echo "[a-z]+"' | grep -oE '"[a-z]+"' | tr -d '"')"
if [[ -n $cfg_ext && $cfg_ext == "$helper_ext" ]]; then
  check "the config and the helper agree on the credential filename" 0
else
  check "the config and the helper agree on the credential filename" 1 \
    "Config.js says '${cfg_ext:-<none>}', install-profile says '${helper_ext:-<none>}'"
fi

echo "# the kill switch stays fail-closed and never disarms itself"
# The single behaviour that makes it a kill switch rather than a decoration:
# a tunnel that drops on its own leaves the rules standing. Only two paths may
# take them down — the user asking, and a stop the user asked for.
disarm_callers="$(grep -n 'disarmKillswitch()' Service.qml | grep -v 'function disarmKillswitch')"
bad_disarm=""
while IFS= read -r line; do
  [[ -z $line ]] && continue
  lineno="${line%%:*}"
  fn="$(head -n "$lineno" Service.qml | grep -oE '^  function [A-Za-z_]+' | tail -1 | awk '{print $2}')"
  case "$fn" in
    toggleKillswitch) ;;
    *) bad_disarm+="  line $lineno is inside ${fn:-<an inline handler>}"$'\n' ;;
  esac
done <<< "$disarm_callers"

# The one inline handler allowed is actionProcess.onExited, and only behind
# the _disarmAfterStop flag that disconnectTunnel sets.
if grep -q 'if (root._disarmAfterStop)' Service.qml; then
  check "an unexpected drop leaves the rules standing" 0
else
  check "an unexpected drop leaves the rules standing" 1 \
    "nothing distinguishes a deliberate stop from a tunnel that fell over"
fi

if grep -q '_disarmAfterStop = killswitchArmed' Service.qml; then
  check "only a stop the user asked for disarms" 0
else
  check "only a stop the user asked for disarms" 1 "$bad_disarm"
fi

# _maintainKillswitch runs every poll. If it ever learns to disarm, a dropped
# tunnel would silently re-open the machine.
maintain_body="$(awk '/^  function _maintainKillswitch\(\)/,/^  }$/' Service.qml)"
if [[ -z $maintain_body ]]; then
  check "the poll's maintenance only ever arms" 1 "_maintainKillswitch() not found"
elif grep -q 'disarm' <<< "$maintain_body"; then
  check "the poll's maintenance only ever arms" 1 "$maintain_body"
else
  check "the poll's maintenance only ever arms" 0
fi

# Both base chains must be policy drop. An accept policy would mean the rules
# read as a kill switch and block nothing at all.
if [[ "$(grep -c 'policy drop;' bin/killswitch)" -eq 2 ]]; then
  check "both base chains are fail-closed" 0
else
  check "both base chains are fail-closed" 1 \
    "$(grep -n 'type filter hook\|policy' bin/killswitch)"
fi

# inet, not ip: an IPv6 leak is the classic way a kill switch fails, and it
# fails invisibly.
if grep -q 'FAMILY="inet"' bin/killswitch; then
  check "the table covers IPv6 as well as IPv4" 0
else
  check "the table covers IPv6 as well as IPv4" 1
fi

# The DNS drop must come BEFORE the LAN accept. Reversed, every query still
# goes to the router in plaintext and the rule set looks correct while doing
# it. Order is the whole content of this rule.
dns_line="$(grep -n 'comment "dns"' bin/killswitch | cut -d: -f1)"
lan_line="$(grep -n 'comment "lan"' bin/killswitch | cut -d: -f1)"
if [[ -n $dns_line && -n $lan_line && $dns_line -lt $lan_line ]]; then
  check "DNS is dropped before the local network is allowed" 0
else
  check "DNS is dropped before the local network is allowed" 1 \
    "dns at line ${dns_line:-<none>}, lan at line ${lan_line:-<none>}"
fi

# Nothing may write the firewall's persistent config. A reboot restoring the
# rules would take away the last recovery path there is.
if grep -rn 'nftables.conf' --include='*.qml' --include='*.js' bin/ . 2>/dev/null \
     | grep -v 'README\|PLAN\|CLAUDE\|test/' | grep -q .; then
  check "nothing writes /etc/nftables.conf, so a reboot always recovers" 1 \
    "$(grep -rn 'nftables.conf' bin/ --include='*.qml' --include='*.js' . 2>/dev/null | grep -v 'README\|PLAN\|CLAUDE\|test/')"
else
  check "nothing writes /etc/nftables.conf, so a reboot always recovers" 0
fi

# The bar mounts this widget once per monitor, each with its own Service and
# its own poll. Only one may fire the privileged arm, or three monitors mean
# three pkexec calls for one tunnel coming up.
if grep -q 'killswitchOwner' Panel.qml && grep -q 'killswitchOwner' Service.qml; then
  check "only one copy of the widget arms automatically" 0
else
  check "only one copy of the widget arms automatically" 1 \
    "the per-monitor election is missing from Panel.qml or Service.qml"
fi

# The election gates the AUTOMATIC path only. Gating the toggle as well would
# make the button dead on every monitor but one.
if awk '/^  function toggleKillswitch\(\)/,/^  }$/' Service.qml | grep -q 'killswitchOwner'; then
  check "the manual toggle is not gated by the election" 1 \
    "$(awk '/^  function toggleKillswitch\(\)/,/^  }$/' Service.qml)"
else
  check "the manual toggle is not gated by the election" 0
fi

echo "# no symlinks — plugin validation rejects them"
links="$(find . -type l -not -path './.git/*' 2>/dev/null || true)"
if [[ -z $links ]]; then
  check "no symlinks in the plugin folder" 0
else
  check "no symlinks in the plugin folder" 1 "$links"
fi

echo "1..$((pass + fail))"
echo "# pass $pass  fail $fail"
[[ $fail -eq 0 ]]
