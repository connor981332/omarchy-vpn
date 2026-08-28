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
