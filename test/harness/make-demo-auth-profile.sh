#!/bin/bash
#
# Generates a throwaway OpenVPN profile whose config asks for a username and
# password, for testing the credential UI — the two fields, the polkit prompt
# behind Save, the "saved" state, and Remove. The Tier 2 harness drives the
# privileged helper directly and never goes through QML, so none of that is
# covered there.
#
# What this CANNOT show you is a successful connection. There is no server:
# the endpoint is a literal TEST-NET-3 address (RFC 5737) that nothing answers,
# chosen so the profile cannot reach anything real and cannot be mistaken for
# a working one. Starting it will fail on the endpoint, which is expected —
# Tier 2 is where the credentials are checked by a server that actually
# checks them.
#
# The certificates are dummy blocks, not a CA. Import parses the profile and
# rewrites it; it does not validate the PEM, and neither does anything else
# until openvpn itself reads it.
#
# Usage:
#   make-demo-auth-profile.sh [output-dir]

set -euo pipefail

OUT="${1:-$HOME}"
[[ -d $OUT ]] || { echo "no such directory: $OUT" >&2; exit 1; }

NAME="ovpndemoauth"
FILE="$OUT/$NAME.ovpn"

{
  echo "client"
  echo "dev tun"
  echo "proto udp"
  # TEST-NET-3, and a literal address rather than a hostname so nothing here
  # depends on DNS resolving.
  echo "remote 203.0.113.9 1194"
  echo "resolv-retry infinite"
  echo "nobind"
  echo "remote-cert-tls server"
  echo "verb 3"
  # The line this whole file exists for. No argument means "prompt on the
  # terminal", which the service does not have — so import rewrites it to
  # point at the credential file and the panel offers the two fields.
  echo "auth-user-pass"
  echo "<ca>"
  echo "-----BEGIN CERTIFICATE-----"
  echo "ZGVtbyBvbmx5IC0gbm90IGEgcmVhbCBjZXJ0aWZpY2F0ZQ=="
  echo "-----END CERTIFICATE-----"
  echo "</ca>"
  echo "<cert>"
  echo "-----BEGIN CERTIFICATE-----"
  echo "ZGVtbyBvbmx5IC0gbm90IGEgcmVhbCBjZXJ0aWZpY2F0ZQ=="
  echo "-----END CERTIFICATE-----"
  echo "</cert>"
  echo "<key>"
  echo "-----BEGIN PRIVATE KEY-----"
  echo "ZGVtbyBvbmx5IC0gbm90IGEgcmVhbCBrZXk="
  echo "-----END PRIVATE KEY-----"
  echo "</key>"
} > "$FILE"

chmod 0600 "$FILE"

echo "Wrote $FILE"
echo
echo "Import it with ＋ next to OpenVPN. The row will show a note asking for a"
echo "username and password. Anything will do — nothing checks them, because"
echo "there is no server at 203.0.113.9."
echo
echo "Delete the profile from the panel when you are done (x on the row), which"
echo "also deletes the credential file."
