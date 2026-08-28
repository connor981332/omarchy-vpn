#!/bin/bash
# bin/install-profile is the only thing in this plugin that runs as root, and
# its caller is unprivileged and therefore untrusted. These are the checks that
# have to hold before it writes anything — all of them fire before the first
# privileged syscall, so the whole file runs as a normal user.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/bin/install-profile"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# Asserts the helper refuses, and refuses for the stated reason rather than by
# tripping over something later.
refuses() {
  local because="$1"; shift
  local output
  output="$("$HELPER" "$@" 2>&1)"
  local code=$?
  if [[ $code -eq 0 ]]; then
    echo "not ok - should have refused ($because): $*"
    fail=$((fail + 1))
  elif [[ $output != *"$because"* ]]; then
    echo "not ok - refused for the wrong reason ($because): $output"
    fail=$((fail + 1))
  else
    echo "ok - refuses $because"
    pass=$((pass + 1))
  fi
}

echo "# argument validation"
refuses "usage"            
refuses "unknown protocol" install badproto name "$TMP"
refuses "unknown protocol" list badproto
refuses "unknown protocol" remove badproto name

echo "# the name can never become a path"
refuses "invalid profile name" install openvpn "../../etc/passwd" "$TMP"
refuses "invalid profile name" install openvpn "/etc/shadow" "$TMP"
refuses "invalid profile name" install openvpn "a/b" "$TMP"
refuses "invalid profile name" install openvpn ".hidden" "$TMP"
refuses "invalid profile name" install openvpn "a b" "$TMP"
refuses "invalid profile name" install openvpn "a;rm -rf /" "$TMP"
refuses "too long"             install openvpn "$(printf 'x%.0s' {1..65})" "$TMP"
# An omitted name trips the usage check before the emptiness check; either
# way nothing is written, which is the property under test.
refuses "usage"                install openvpn "" "$TMP"
refuses "invalid profile name" remove openvpn "../../etc/passwd"

echo "# the destination is never caller-supplied"
# There is no argument that names a directory to write into — only a protocol
# token — so this is asserted by reading the interface rather than probing it.
if grep -qE '^\s*(dir|DEST)=.*\$[1-9]' "$HELPER"; then
  echo "not ok - a destination directory is taken from an argument"
  fail=$((fail + 1))
else
  echo "ok - destination comes from profile_dir(), not from argv"
  pass=$((pass + 1))
fi

echo "# staging directory vetting"
mkdir -p "$TMP/staging"
refuses "no work.conf" install openvpn work "$TMP/staging"

printf 'client\nremote a 1194\n' > "$TMP/staging/work.conf"
ln -s /etc/shadow "$TMP/staging/work.key"
refuses "symlink" install openvpn work "$TMP/staging"

rm -f "$TMP/staging/work.key"
mkdir -p "$TMP/staging/work.sub"
refuses "not a regular file" install openvpn work "$TMP/staging"

rmdir "$TMP/staging/work.sub"
touch "$TMP/staging/somebodyelse.conf"
refuses "does not belong to profile" install openvpn work "$TMP/staging"

rm -f "$TMP/staging/somebodyelse.conf"
refuses "does not exist" install openvpn work "$TMP/nonexistent"

ln -s "$TMP/staging" "$TMP/linked"
refuses "symlink" install openvpn work "$TMP/linked"

echo "# a missing profile directory is explained, not tripped over"
# PLAN.md asked whether /etc/openvpn/client exists right after a fresh
# `pacman -S openvpn`. It does: the openvpn package ships
# /usr/lib/tmpfiles.d/openvpn.conf, and pacman's 21-systemd-tmpfiles.hook runs
# `systemd-tmpfiles --create` post-transaction, after 20-systemd-sysusers.hook
# has made the openvpn user. So require_dir's fallback is only reached when
# someone has deleted the directory — and then it must say something useful
# rather than failing at the copy.
#
# /etc/wireguard exercises that path for real on a machine without
# wireguard-tools, with no root and nothing to clean up.
if [[ -d /etc/wireguard ]]; then
  echo "ok - SKIP: /etc/wireguard exists, so the missing-dir path cannot be exercised here"
  pass=$((pass + 1))
else
  mkdir -p "$TMP/wg"
  : > "$TMP/wg/demo.conf"
  refuses "is the wireguard package installed?" install wireguard demo "$TMP/wg"
fi

echo "# file mode"
# pkexec refuses a program that is group- or world-writable, so a bad umask at
# checkout time would make the whole privileged path unusable.
mode="$(stat -c '%a' "$HELPER")"
if [[ $mode == 755 || $mode == 700 || $mode == 750 ]]; then
  echo "ok - helper mode $mode is not group/world writable"
  pass=$((pass + 1))
else
  echo "not ok - helper mode $mode may be rejected by pkexec"
  fail=$((fail + 1))
fi

echo "1..$((pass + fail))"
echo "# pass $pass  fail $fail"
[[ $fail -eq 0 ]]
