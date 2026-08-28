#!/bin/bash
# Everything that can run without a human. Tier 2 needs root and is opt-in.
#
#   ./run-tests.sh                 fast suite (no root, no network)
#   ./run-tests.sh --integration   also brings up a real tunnel (asks for sudo)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT" || exit 1

INTEGRATION=0
[[ ${1-} == "--integration" ]] && INTEGRATION=1

failed=()
skipped=()

# Exit 77 is "skipped" (the automake convention). A suite that cannot run must
# never read as one that passed — that is how a whole tier goes missing without
# anyone noticing.
run() {
  local name="$1"; shift
  echo
  echo "═══ $name"
  "$@"
  local code=$?
  if [[ $code -eq 0 ]]; then
    echo "─── $name: PASS"
  elif [[ $code -eq 77 ]]; then
    echo "─── $name: SKIPPED"
    skipped+=("$name")
  else
    echo "─── $name: FAIL"
    failed+=("$name")
  fi
}

# Not `command -v node`: a version manager's shim is executable and still
# fails at runtime when no version is pinned, which makes every Tier 1 suite
# fail at once with a message about the shim rather than about this project.
# find-node.sh runs its candidates instead of inspecting them.
NODE="$(./test/find-node.sh || true)"
if [[ -z $NODE ]]; then
  echo "node is required for the unit tests, and no working one was found."
  echo "If you use a version manager, pin a version — e.g. mise use -g node@lts"
  exit 1
fi
export NODE
[[ $NODE == "$(command -v node 2>/dev/null || true)" ]] || echo "# node: $NODE"

run "Tier 1  Model.js"                "$NODE" test/model.test.js
run "Tier 1  OpenVPN config"          "$NODE" test/config.test.js
run "Tier 1  WireGuard config"        "$NODE" test/wireguard-config.test.js
run "Tier 1  systemd escaping"        ./test/harness/escape.test.sh
run "         privileged helper"      ./test/helper.test.sh
run "         architecture"           ./test/architecture.test.sh
run "Tier 4  dependency matrix"       ./test/dependency.test.sh
run "         plugin validation"      omarchy plugin validate "$ROOT"
run "         qmllint"                qmllint -I /usr/lib/qt6/qml \
                                        -I "${OMARCHY_PATH:-/usr/share/omarchy}/shell" \
                                        Service.qml VpnIcon.qml Telemetry.qml \
                                        ProfileStore.qml Backends.qml \
                                        backends/openvpn/Backend.qml

# Panel.qml is excluded from qmllint on purpose: it cannot parse Quickshell's
# typed IPC functions (`function open(): void`) and dies with
# "Unexpected token `void`" on the shipped first-party plugins too.

if [[ $INTEGRATION -eq 1 ]]; then
  run "Tier 2  real tunnel"           ./test/harness/up.sh
else
  echo
  echo "═══ Tier 2  real tunnel"
  echo "─── SKIPPED (needs root) — run ./run-tests.sh --integration"
  skipped+=("Tier 2  real tunnel")
fi

echo
if [[ ${#skipped[@]} -gt 0 ]]; then
  echo "Skipped (did NOT run): ${skipped[*]}"
fi

if [[ ${#failed[@]} -eq 0 ]]; then
  if [[ ${#skipped[@]} -eq 0 ]]; then
    echo "All suites passed."
  else
    echo "All suites that ran passed — but ${#skipped[@]} did not run."
  fi
  exit 0
fi
echo "Failed: ${failed[*]}"
exit 1
