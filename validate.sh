#!/bin/bash
# Fast feedback loop for this plugin: does it validate, lint, and answer IPC?
# For the test suite, use ./run-tests.sh.
set -uo pipefail

PLUGIN_ID="connor.vpn"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_DIR="${OMARCHY_PATH:-/usr/share/omarchy}/shell"

echo "== manifest"
omarchy plugin validate "$PLUGIN_DIR" || exit 1

# qmllint cannot parse Quickshell's typed IPC functions (`function open(): void`)
# — it dies with "Unexpected token `void`" on the first-party plugins too. So
# lint the files that have no IpcHandler and skip Panel.qml rather than reading
# its exit code as a real failure.
echo "== qmllint (Panel.qml skipped: see comment)"
qmllint -I /usr/lib/qt6/qml -I "$SHELL_DIR" \
  "$PLUGIN_DIR/Service.qml" \
  "$PLUGIN_DIR/VpnIcon.qml" \
  "$PLUGIN_DIR/Telemetry.qml" \
  "$PLUGIN_DIR/ProfileStore.qml" \
  "$PLUGIN_DIR/Backends.qml" \
  "$PLUGIN_DIR/backends/openvpn/Backend.qml"

echo "== discovery"
omarchy plugin list --json | jq --arg id "$PLUGIN_ID" '.[] | select(.id == $id)'

# `omarchy plugin list` reports active:false even when the widget is mounted;
# the IPC call below is the real health check. If it says "Function not found",
# the shell is still running an older copy — restart it.
echo "== live IPC"
omarchy-shell "$PLUGIN_ID" state | jq . 2>/dev/null || omarchy-shell "$PLUGIN_ID" state
