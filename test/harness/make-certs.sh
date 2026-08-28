#!/bin/bash
# Generates a throwaway CA, server and client for the integration harness, plus
# the server config and the client .ovpn that pairs with it.
#
# Needs no root, no network, and no easy-rsa — openssl alone, because easy-rsa
# is not in Omarchy's base and the test suite must not need a package the
# plugin itself does not.
#
# The generated client profile is deliberately the awkward shape: an `askpass`
# file under $HOME and an encrypted key, so the import path's ProtectHome
# rewriting is exercised for real rather than in a fixture.
set -euo pipefail

DIR="${1:?usage: make-certs.sh <output-dir> [server-ip]}"
SERVER_IP="${2:-10.77.0.1}"
PASSPHRASE="harness-passphrase"

mkdir -p "$DIR"
cd "$DIR"

conf() { printf '%s\n' "$@"; }

# A CA, a server cert, and a client cert whose key is encrypted — the encrypted
# key is what makes `askpass` meaningful.
openssl req -x509 -newkey rsa:2048 -keyout ca.key -out ca.crt -days 2 -nodes \
  -subj "/CN=connor.vpn-harness-ca" >/dev/null 2>&1

openssl req -newkey rsa:2048 -keyout server.key -out server.csr -nodes \
  -subj "/CN=harness-server" >/dev/null 2>&1
# `remote-cert-tls server` in the client profile checks BOTH extendedKeyUsage
# and keyUsage. A cert carrying only the EKU fails with "Certificate does not
# have key usage extension" / "VERIFY KU ERROR" — which looks like a trust
# problem and is actually a missing extension.
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 2 \
  -extfile <(printf 'extendedKeyUsage=serverAuth\nkeyUsage=digitalSignature,keyEncipherment\n') \
  >/dev/null 2>&1

openssl req -newkey rsa:2048 -keyout client.key -out client.csr \
  -passout "pass:$PASSPHRASE" \
  -subj "/CN=harness-client" >/dev/null 2>&1
# Matching extensions on the client, so the harness still works if the server
# config ever gains `remote-cert-tls client`.
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 2 \
  -extfile <(printf 'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature\n') \
  >/dev/null 2>&1

# No DH parameter file. Modern OpenSSL refuses DH keys under 2048 bits
# outright ("dh key too small"), and generating 2048-bit parameters is slow and
# variable — seconds to minutes — which is not something a test suite should
# spend. `dh none` uses ECDHE instead, which is what current OpenVPN prefers
# anyway.
openvpn --genkey secret ta.key >/dev/null 2>&1

printf '%s' "$PASSPHRASE" > askpass.txt
chmod 600 askpass.txt

conf \
  "dev tun" \
  "topology subnet" \
  "server 10.88.0.0 255.255.255.0" \
  "proto udp" \
  "port 1194" \
  "local $SERVER_IP" \
  "ca ca.crt" \
  "cert server.crt" \
  "key server.key" \
  "dh none" \
  "tls-auth ta.key 0" \
  "cipher AES-256-GCM" \
  "auth SHA256" \
  "keepalive 5 20" \
  "push \"dhcp-option DNS 10.88.0.1\"" \
  "verb 3" \
  > server.conf

# NOTE: no `redirect-gateway`. The harness must never take over the default
# route of the machine it is running on.

{
  conf \
    "client" \
    "dev tun" \
    "proto udp" \
    "remote $SERVER_IP 1194" \
    "resolv-retry 3" \
    "nobind" \
    "remote-cert-tls server" \
    "cipher AES-256-GCM" \
    "auth SHA256" \
    "verb 3" \
    "askpass $DIR/askpass.txt" \
    "tls-auth $DIR/ta.key 1"
  echo "<ca>"; cat ca.crt; echo "</ca>"
  echo "<cert>"; cat client.crt; echo "</cert>"
  echo "<key>"; cat client.key; echo "</key>"
} > client.ovpn

echo "$DIR/client.ovpn"
