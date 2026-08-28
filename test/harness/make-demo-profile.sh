#!/bin/bash
#
# Generates a throwaway WireGuard profile for testing the UI path — the file
# chooser, the import warnings, the polkit prompt, and the panel row — none of
# which the Tier 2 harness touches, because it drives the parser and the
# helpers directly and never goes through QML.
#
# No server is needed, and that is not a compromise: WireGuard is
# connectionless. `wg-quick up` creates the interface, applies the config and
# returns success whether or not the peer exists, so everything the UI does is
# exercised for real. The one thing that stays zero is the traffic counter,
# which Tier 2 already proves against a genuine tunnel.
#
# Two deliberate choices keep this from touching your networking:
#
#   AllowedIPs is a private /24, never 0.0.0.0/0. A default route would send
#   this machine's traffic into a tunnel with nothing on the far end.
#
#   Endpoint is a literal address from TEST-NET-3 (RFC 5737), never a hostname.
#   The stock unit sets WG_ENDPOINT_RESOLUTION_RETRIES=infinity, so a name that
#   does not resolve makes the unit retry forever instead of starting.
#
# Usage:
#   make-demo-profile.sh [output-dir] [--dns]
#
#   --dns  adds a DNS line, which is what a commercial profile looks like and
#          what triggers the openresolv warning at import.

set -euo pipefail

OUT="${1:-$HOME}"
[[ ${1-} == --* ]] && OUT="$HOME"

WITH_DNS=0
for arg in "$@"; do
  [[ $arg == --dns ]] && WITH_DNS=1
done

command -v wg >/dev/null || { echo "wireguard-tools is not installed" >&2; exit 1; }
[[ -d $OUT ]] || { echo "no such directory: $OUT" >&2; exit 1; }

# The filename becomes the profile name, which becomes the interface name, so
# it has to fit in the 15 characters wg-quick allows.
NAME="wgdemo"
[[ $WITH_DNS -eq 1 ]] && NAME="wgdemodns"

FILE="$OUT/$NAME.conf"

umask 077
CLIENT_KEY="$(wg genkey)"
SERVER_KEY="$(wg genkey)"
SERVER_PUB="$(printf '%s' "$SERVER_KEY" | wg pubkey)"

{
  echo "[Interface]"
  echo "PrivateKey = $CLIENT_KEY"
  echo "Address = 10.99.0.2/24"
  [[ $WITH_DNS -eq 1 ]] && echo "DNS = 10.99.0.1"
  echo
  echo "[Peer]"
  echo "PublicKey = $SERVER_PUB"
  echo "AllowedIPs = 10.99.0.0/24"
  echo "Endpoint = 198.51.100.7:51820"
  echo "PersistentKeepalive = 25"
} > "$FILE"

chmod 600 "$FILE"
echo "$FILE"
