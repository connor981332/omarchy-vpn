#!/bin/bash
# Tier 2: the control plane and the telemetry plane against a real tunnel.
#
# No remote VPN server is needed and no credentials are involved: the harness
# generates a throwaway CA, runs an OpenVPN server inside a network namespace,
# and connects to it through the real `openvpn-client@.service` — the same unit,
# the same ProtectHome constraints, and the same kernel counters the widget
# reads in production.
#
# Every assertion about output format goes through the plugin's own parsers, so
# this is what catches a parser that drifts from what the kernel actually
# prints. That is the point of the tier — the unit tests can only check the
# parsers against strings someone typed.
#
# Needs root, taken once at the top rather than per-operation.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="vpnharness"
# Deliberately hyphenated. `systemd-escape` turns "-" into "\x2d", and the
# stock unit expands the RAW %i into a filename — so a name with a hyphen is
# exactly the case that catches an instance name being escaped when it must
# not be. A profile called "harness" would pass either way and prove nothing.
PROFILE="harness-test"
# A second profile, identical but for a hook that is not installed. It exists
# to prove the panel reports the daemon's reason and not systemd's boilerplate.
BAD_PROFILE="harness-badhook"
# A third, whose config asks for a username and password. It connects to a
# second server that actually checks them, so both the accept and the reject
# path are real rather than simulated.
AUTH_PROFILE="harness-auth"
# The WireGuard end. 10 characters, comfortably inside the 15 wg-quick allows,
# and the interface it creates takes this name exactly — which is the whole
# point of the deviceFor() seam.
WG_PROFILE="harness-wg"
WG_UNIT="wg-quick@${WG_PROFILE}.service"
WG_SRV_DEV="wgsrv"
# A subnet of its own, so nothing here can collide with the OpenVPN tunnel's.
WG_SRV_IP="10.88.1.1"
WG_CLIENT_IP="10.88.1.2"
WG_PORT="51820"
SERVER_IP="10.77.0.1"
HOST_IP="10.77.0.2"
UNIT="openvpn-client@${PROFILE}.service"

# Exit 77 means "skipped", not "passed" — run-tests.sh reports the two
# differently, because a tier that silently skips is worse than one that fails.
SKIP=77

# node is resolved BEFORE re-exec'ing under sudo and handed over explicitly.
# A version manager (mise, nvm, asdf) puts node under the user's home and on
# the user's PATH only, so root would not find it and the whole tier would
# skip itself on exactly the machines that have one.
NODE="${NODE:-}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  # Resolved by running a candidate, not by finding one on PATH: a version
  # manager's shim is executable and still fails at runtime, and the failure
  # arrives here as an empty string that some assertions would PASS on.
  NODE="$("$ROOT/test/find-node.sh" || true)"
  if [[ -z $NODE ]]; then
    echo "SKIP: no working node was found"
    exit $SKIP
  fi
  echo "# needs root for netns and systemctl; re-running under sudo"
  exec sudo -- "$0" --node "$NODE" "$@"
fi

# Unpack the node path handed over across sudo.
if [[ ${1-} == "--node" ]]; then
  NODE="${2-}"
  shift 2
fi

if [[ -z $NODE || ! -x $NODE ]]; then
  echo "SKIP: node was not found as root (got '${NODE:-none}')"
  exit $SKIP
fi

# And it must still run as root — a shim resolves against the *invoking* user's
# configuration, so surviving the sudo boundary is not a given.
if ! "$NODE" -e 'process.stdout.write("ok")' >/dev/null 2>&1; then
  echo "SKIP: node at $NODE does not run as root"
  "$NODE" -e 'process.stdout.write("ok")' 2>&1 | sed 's/^/# /'
  exit $SKIP
fi

for tool in openvpn ip openssl systemctl; do
  command -v "$tool" >/dev/null || { echo "SKIP: $tool is not installed"; exit $SKIP; }
done

echo "# node: $NODE"

WORK="$(mktemp -d /tmp/connor-vpn-harness.XXXXXX)"
SERVER_PID=""
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

cleanup() {
  echo "# teardown"
  systemctl stop "$UNIT" >/dev/null 2>&1 || true
  [[ -n $SERVER_PID ]] && kill "$SERVER_PID" >/dev/null 2>&1
  "$ROOT/bin/install-profile" remove openvpn "$PROFILE" >/dev/null 2>&1 || true
  systemctl stop "openvpn-client@${BAD_PROFILE}.service" >/dev/null 2>&1 || true
  "$ROOT/bin/install-profile" remove openvpn "$BAD_PROFILE" >/dev/null 2>&1 || true
  systemctl stop "openvpn-client@${AUTH_PROFILE}.service" >/dev/null 2>&1 || true
  # Removes the profile AND its credential file, which is the behaviour the
  # section asserts — so a failed run leaves no secret behind either.
  "$ROOT/bin/install-profile" remove openvpn "$AUTH_PROFILE" >/dev/null 2>&1 || true
  systemctl stop "$WG_UNIT" >/dev/null 2>&1 || true
  "$ROOT/bin/install-profile" remove wireguard "$WG_PROFILE" >/dev/null 2>&1 || true
  ip netns exec "$NS" ip link del "$WG_SRV_DEV" >/dev/null 2>&1 || true
  ip netns pids "$NS" 2>/dev/null | xargs -r kill >/dev/null 2>&1
  ip netns del "$NS" >/dev/null 2>&1 || true
  ip link del veth-h >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# ------------------------------------------------------------------ namespace

echo "# namespace"
ip netns del "$NS" >/dev/null 2>&1 || true
ip link del veth-h >/dev/null 2>&1 || true

ip netns add "$NS"
ip link add veth-h type veth peer name veth-n
ip link set veth-n netns "$NS"
ip addr add "$HOST_IP/24" dev veth-h
ip link set veth-h up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip addr add "$SERVER_IP/24" dev veth-n
ip netns exec "$NS" ip link set veth-n up

ping -c1 -W2 "$SERVER_IP" >/dev/null 2>&1
check "the namespace is reachable at $SERVER_IP" $?

# ------------------------------------------------------------------ server

echo "# certificate authority and server"
"$ROOT/test/harness/make-certs.sh" "$WORK" "$SERVER_IP" >/dev/null 2>&1
check "generated a throwaway CA, server and client" $?

ip netns exec "$NS" openvpn --config "$WORK/server.conf" --cd "$WORK" \
  --log "$WORK/server.log" --daemon
sleep 3

# `ip netns exec` changes only the network namespace, not the PID namespace,
# so this would match any openvpn on the box. Narrow it to one started from
# our own working directory.
SERVER_PID="$(pgrep -f "openvpn --config $WORK/server.conf" | head -1 || true)"
[[ -n $SERVER_PID ]]
# On failure the server log is the only thing that explains why — without it
# this reads as "not ok" and nothing else, which is how the DH size problem
# stayed invisible.
check "the server is running inside the namespace" $? \
  "$(tail -20 "$WORK/server.log" 2>/dev/null || echo '(no server log was written)')"

if [[ -z $SERVER_PID ]]; then
  echo "# the client cannot connect without a server; skipping the rest"
  echo "1..$((pass + fail))"
  echo "# pass $pass  fail $fail"
  exit 1
fi

# ------------------------------------------------------------------ import

echo "# import through the real privileged path"
# The generated profile references an askpass file and a tls-auth key by
# absolute path — exactly what ProtectHome=true would break if import did not
# rewrite them.
PLAN_JSON="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const C = load("backends/openvpn/Config.js")
  const fs = require("fs")
  const src = process.argv[1]
  const plan = C.plan(fs.readFileSync(src, "utf8"),
                      { name: process.argv[2], sourceDir: src.replace(/\/[^/]+$/, "") })
  fs.writeFileSync(process.argv[3], plan.content)
  console.log(JSON.stringify({ assets: plan.assets, errors: plan.errors, endpoint: plan.endpoint }))
' "$WORK/client.ovpn" "$PROFILE" "$WORK/rewritten.conf")"

echo "$PLAN_JSON" | grep -q '"errors":\[\]'
check "the generated profile plans cleanly" $? "$PLAN_JSON"

grep -q "$WORK" "$WORK/rewritten.conf"
# grep succeeding means a source path survived, which is the bug.
check "no absolute source path survives the rewrite" $(( $? == 1 ? 0 : 1 )) \
  "$(grep -n "$WORK" "$WORK/rewritten.conf" 2>/dev/null)"

STAGING="${XDG_CACHE_HOME:-$HOME/.cache}/connor.vpn/staging/$PROFILE"
STAGE_ARGS=()
while IFS=$'\t' read -r source target; do
  [[ -n $source ]] && STAGE_ARGS+=(--asset "$source" "$target")
done < <(echo "$PLAN_JSON" | "$NODE" -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    JSON.parse(s).assets.forEach(a => console.log(a.source + "\t" + a.target))
  })')

"$ROOT/bin/stage-profile" "$STAGING" "$PROFILE.conf" "${STAGE_ARGS[@]}" \
  < "$WORK/rewritten.conf" >/dev/null
check "staged the profile and its side files" $?

"$ROOT/bin/install-profile" install openvpn "$PROFILE" "$STAGING" >/dev/null
check "installed it into the profile directory" $?

test -f "/etc/openvpn/client/$PROFILE.conf"
check "the config landed where the unit will look for it" $?

# The bug this catches: an escaped instance name makes %i expand to
# "harness\x2dtest.conf" while the file on disk is "harness-test.conf".
EXPANDED="$(systemctl show "$UNIT" -p ExecStart --value 2>/dev/null | grep -oE '[^ ]+\.conf' | head -1)"
[[ $EXPANDED == "$PROFILE.conf" ]]
check "the unit's %i expands to the file that was written (got '$EXPANDED')" $?

# ------------------------------------------------------------------ connect

echo "# control plane"
DEVICES_BEFORE="$(ip -j link)"

systemctl start "$UNIT"
check "systemctl start returned success" $?

for _ in $(seq 1 20); do
  [[ "$(systemctl is-active "$UNIT")" == "active" ]] && break
  sleep 1
done
[[ "$(systemctl is-active "$UNIT")" == "active" ]]
check "the unit reached active" $? "$(journalctl -u "$UNIT" -n 15 --no-pager 2>&1)"

sleep 3
DEVICES_AFTER="$(ip -j link)"

# The plugin's own device detection, against real kernel output.
DEV="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const M = load("Model.js")
  const before = M.parseLinkDevices(process.argv[1])
  const after = M.parseLinkDevices(process.argv[2])
  process.stdout.write(M.newDevice(before, after, ["tun", "tap"]))
' "$DEVICES_BEFORE" "$DEVICES_AFTER")"

[[ -n $DEV ]]
check "Model.newDevice() found the tunnel device (got '${DEV:-none}')" $? \
  "$(printf 'client journal:\n%s\n\nserver log:\n%s\n' \
      "$(journalctl -u "$UNIT" -n 20 --no-pager 2>&1)" \
      "$(tail -20 "$WORK/server.log" 2>/dev/null)")"

# ------------------------------------------------------------------ telemetry

echo "# telemetry plane"
if [[ -n $DEV ]]; then
  test -r "/sys/class/net/$DEV/statistics/rx_bytes"
  check "the kernel byte counters are readable unprivileged" $?

  RX1="$(cat "/sys/class/net/$DEV/statistics/rx_bytes")"
  TX1="$(cat "/sys/class/net/$DEV/statistics/tx_bytes")"

  # Traffic that has to traverse the tunnel to be answered.
  ping -c4 -W2 -I "$DEV" 10.88.0.1 >/dev/null 2>&1
  sleep 1

  RX2="$(cat "/sys/class/net/$DEV/statistics/rx_bytes")"
  TX2="$(cat "/sys/class/net/$DEV/statistics/tx_bytes")"

  (( TX2 > TX1 ))
  check "tx_bytes moved ($TX1 -> $TX2)" $?
  (( RX2 > RX1 ))
  check "rx_bytes moved ($RX1 -> $RX2) — the tunnel actually carries traffic" $?

  # And the rate math over the real samples.
  cd "$ROOT" && "$NODE" -e '
    const {load} = require("./test/qmljs")
    const M = load("Model.js")
    const r = M.rate(Number(process.argv[1]), Number(process.argv[2]), 1000, 2000)
    process.exit(r > 0 ? 0 : 1)
  ' "$RX1" "$RX2"
  check "Model.rate() turns the real samples into a positive rate" $?

  ROUTES="$(ip -j route)"
  echo "$ROUTES" | grep -q "\"dev\":\"$DEV\""
  check "the route table carries the tunnel's routes" $?

  # The pushed DNS. resolvectl may not track the link at all, which is itself
  # a real answer the parser has to survive.
  DNS_OUT="$(resolvectl status "$DEV" 2>&1 || true)"
  cd "$ROOT" && "$NODE" -e '
    const {load} = require("./test/qmljs")
    const M = load("Model.js")
    const servers = M.parseResolvers(process.argv[1])
    console.log("#   resolvers parsed: " + JSON.stringify(servers))
  ' "$DNS_OUT"
  check "Model.parseResolvers() survives real resolvectl output" $?

  ADDRS="$(ip -j addr show dev "$DEV")"
  cd "$ROOT" && "$NODE" -e '
    const {load} = require("./test/qmljs")
    const M = load("Model.js")
    const a = M.parseAddresses(process.argv[1])
    console.log("#   addresses parsed: " + JSON.stringify(a))
    process.exit(a.length > 0 ? 0 : 1)
  ' "$ADDRS"
  check "Model.parseAddresses() found the tunnel address" $?
fi

# systemctl show, which is what the state poll actually runs.
SHOW="$(systemctl show "$UNIT" -p Id -p ActiveState -p ActiveEnterTimestampMonotonic)"
cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const M = load("Model.js")
  const blocks = M.parseShowBlocks(process.argv[1])
  const unit = process.argv[2]
  if (!blocks[unit]) { console.error("no block for " + unit); process.exit(1) }
  if (M.stateFromIsActive(blocks[unit].ActiveState) !== "up") process.exit(1)
  const uptime = M.parseUptimeSeconds(require("fs").readFileSync("/proc/uptime", "utf8"))
  const secs = M.activeSeconds(blocks[unit].ActiveEnterTimestampMonotonic, uptime)
  console.log("#   active for " + M.formatDuration(secs))
  process.exit(secs > 0 ? 0 : 1)
' "$SHOW" "$UNIT"
check "Model.parseShowBlocks() reads the real unit state and duration" $?

# ------------------------------------------------------------------ disconnect

echo "# teardown path"
systemctl stop "$UNIT"
check "systemctl stop returned success" $?
sleep 2

[[ "$(systemctl is-active "$UNIT")" != "active" ]]
check "the unit is no longer active" $?

if [[ -n $DEV ]]; then
  ip link show "$DEV" >/dev/null 2>&1
  check "the tunnel device is gone" $(( $? == 1 ? 0 : 1 ))
fi

"$ROOT/bin/install-profile" remove openvpn "$PROFILE" >/dev/null
check "the profile was removed" $?

test -f "/etc/openvpn/client/$PROFILE.conf"
check "no config file is left behind" $(( $? == 1 ? 0 : 1 ))

# --------------------------------------------------------- why it failed

# The gap this closes: `systemctl start` prints only that the job failed, so
# the panel used to show systemd's boilerplate while the actual reason sat in
# the journal. A hook pointing at a path that is not installed is the most
# likely version of this a stranger will hit — the config parses and imports
# cleanly, and nothing objects until connect time.
echo "# a failed start explains itself"

BAD_UNIT="openvpn-client@${BAD_PROFILE}.service"
BAD_HOOK="/usr/lib/connor-vpn-harness-hook-that-is-not-installed"
BAD_STAGING="${XDG_CACHE_HOME:-$HOME/.cache}/connor.vpn/staging/$BAD_PROFILE"

# Planned again under its OWN name, not by reusing the first profile's staging
# arguments: install-profile refuses a staging directory holding a file named
# for a different profile, and the rewritten config points at those filenames.
BAD_PLAN_JSON="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const C = load("backends/openvpn/Config.js")
  const fs = require("fs")
  const src = process.argv[1]
  const plan = C.plan(fs.readFileSync(src, "utf8"),
                      { name: process.argv[2], sourceDir: src.replace(/\/[^/]+$/, "") })
  fs.writeFileSync(process.argv[3], plan.content)
  console.log(JSON.stringify({ assets: plan.assets }))
' "$WORK/client.ovpn" "$BAD_PROFILE" "$WORK/badhook-base.conf")"

BAD_STAGE_ARGS=()
while IFS=$'\t' read -r source target; do
  [[ -n $source ]] && BAD_STAGE_ARGS+=(--asset "$source" "$target")
done < <(echo "$BAD_PLAN_JSON" | "$NODE" -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    JSON.parse(s).assets.forEach(a => console.log(a.source + "\t" + a.target))
  })')

test -s "$WORK/badhook-base.conf"
check "the broken profile's config was actually written" $?

{ cat "$WORK/badhook-base.conf"; echo "script-security 2"; echo "up $BAD_HOOK"; } \
  > "$WORK/badhook.conf"

"$ROOT/bin/stage-profile" "$BAD_STAGING" "$BAD_PROFILE.conf" "${BAD_STAGE_ARGS[@]}" \
  --hook "$BAD_HOOK" < "$WORK/badhook.conf" > "$WORK/stage-badhook.out"
check "staged the profile with the bogus hook" $?

grep -q "^missing-hook: $BAD_HOOK\$" "$WORK/stage-badhook.out"
check "import notices the hook is not on this system" $? \
  "$(cat "$WORK/stage-badhook.out")"

"$ROOT/bin/install-profile" install openvpn "$BAD_PROFILE" "$BAD_STAGING" >/dev/null
check "installed the deliberately broken profile" $?

# The point of the whole section: this must fail, and it must fail for the
# reason we are about to go looking for.
systemctl start "$BAD_UNIT" > "$WORK/start.out" 2> "$WORK/start.err"
check "starting a profile with a missing hook fails" $(( $? != 0 ? 0 : 1 )) \
  "$(cat "$WORK/start.out" "$WORK/start.err")"

# What the panel used to show, and what it shows now, from the same two sources
# the widget itself reads.
SYSTEMD_SAYS="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const M = load("Model.js")
  const fs = require("fs")
  console.log(M.cleanError(fs.readFileSync(process.argv[1], "utf8")))
' "$WORK/start.err")"

journalctl -u "$BAD_UNIT" -n 40 --no-pager -o cat > "$WORK/journal.txt" 2>&1
check "the unit journal is readable" $?

PANEL_SAYS="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const M = load("Model.js")
  const fs = require("fs")
  console.log(M.journalError(fs.readFileSync(process.argv[1], "utf8")))
' "$WORK/journal.txt")"

echo "# systemd said:   $SYSTEMD_SAYS"
echo "# the panel says: $PANEL_SAYS"

[[ $PANEL_SAYS == *"$BAD_HOOK"* ]]
check "the panel names the missing file" $? \
  "got: $PANEL_SAYS"$'\n'"journal:"$'\n'"$(cat "$WORK/journal.txt")"

# And it is a real improvement, not the same boilerplate reformatted.
[[ $PANEL_SAYS != "$SYSTEMD_SAYS" && $PANEL_SAYS != *"Job for"* ]]
check "and not systemd's job-failed boilerplate" $? "got: $PANEL_SAYS"

"$ROOT/bin/install-profile" remove openvpn "$BAD_PROFILE" >/dev/null
check "the broken profile was removed" $?

# ------------------------------------------------------------ credentials

# Phase 3. A profile with `auth-user-pass` and no file is the shape almost
# every commercial provider ships, and it used to be refused at import: the
# directive means "prompt on the terminal" and the service has no terminal.
#
# This section runs the whole loop against a real server that actually checks
# the username and password, because the two halves that matter cannot be
# tested apart. A file with the right mode proves nothing if OpenVPN never
# reads it, and an AUTH_FAILED in the journal proves nothing if the panel
# still shows systemd's boilerplate over the top of it.
echo "# credentials"

AUTH_UNIT="openvpn-client@${AUTH_PROFILE}.service"
AUTH_FILE="/etc/openvpn/client/${AUTH_PROFILE}.auth"
AUTH_USER="harness-user"
AUTH_PASS="harness-pass"
AUTH_PORT="1195"

# A second server rather than a change to the first: the existing one is green
# and every assertion above depends on it, so the credential test must not be
# able to break it.
cat > "$WORK/verify.sh" <<'VERIFY'
#!/bin/bash
# OpenVPN writes the two lines to a temp file and passes its path. Exit 0
# accepts the client.
[[ "$(sed -n 1p "$1")" == "harness-user" && "$(sed -n 2p "$1")" == "harness-pass" ]]
VERIFY
chmod 0755 "$WORK/verify.sh"

sed -e "s/^port 1194\$/port $AUTH_PORT/" \
    -e "s#^server 10\.88\.0\.0#server 10.88.2.0#" \
    "$WORK/server.conf" > "$WORK/server-auth.conf"
{
  echo "script-security 2"
  echo "auth-user-pass-verify $WORK/verify.sh via-file"
} >> "$WORK/server-auth.conf"

ip netns exec "$NS" openvpn --config "$WORK/server-auth.conf" --cd "$WORK" \
  --log "$WORK/server-auth.log" --daemon
sleep 3

AUTH_SERVER_PID="$(pgrep -f "openvpn --config $WORK/server-auth.conf" | head -1 || true)"
[[ -n $AUTH_SERVER_PID ]]
check "a server that checks a username and password is running" $? \
  "$(tail -20 "$WORK/server-auth.log" 2>/dev/null || echo '(no log was written)')"

if [[ -n $AUTH_SERVER_PID ]]; then

# The client profile: the generated one, pointed at the second server, with a
# bare `auth-user-pass` added. That directive is the whole subject of the test.
sed -e "s/ $SERVER_IP 1194\$/ $SERVER_IP $AUTH_PORT/" "$WORK/client.ovpn" \
  > "$WORK/client-auth.ovpn"
echo "auth-user-pass" >> "$WORK/client-auth.ovpn"

AUTH_PLAN_JSON="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const C = load("backends/openvpn/Config.js")
  const fs = require("fs")
  const src = process.argv[1]
  const plan = C.plan(fs.readFileSync(src, "utf8"),
                      { name: process.argv[2], sourceDir: src.replace(/\/[^/]+$/, "") })
  fs.writeFileSync(process.argv[3], plan.content)
  console.log(JSON.stringify({ assets: plan.assets, needsCredentials: plan.needsCredentials }))
' "$WORK/client-auth.ovpn" "$AUTH_PROFILE" "$WORK/auth-base.conf")"

echo "$AUTH_PLAN_JSON" | grep -q '"needsCredentials":true'
check "import notices the profile will need a username and password" $? "$AUTH_PLAN_JSON"

# The filename the config now points at has to be the one the helper writes.
# This is the seam the architecture test can only check by string comparison;
# here both ends are real.
grep -q "^auth-user-pass ${AUTH_PROFILE}.auth\$" "$WORK/auth-base.conf"
check "the rewritten config points at the credential file the helper writes" $? \
  "$(grep -n auth-user-pass "$WORK/auth-base.conf")"

AUTH_STAGING="${XDG_CACHE_HOME:-$HOME/.cache}/connor.vpn/staging/$AUTH_PROFILE"
AUTH_STAGE_ARGS=()
while IFS=$'\t' read -r source target; do
  [[ -n $source ]] && AUTH_STAGE_ARGS+=(--asset "$source" "$target")
done < <(echo "$AUTH_PLAN_JSON" | "$NODE" -e '
  let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
    JSON.parse(s).assets.forEach(a => console.log(a.source + "\t" + a.target))
  })')

"$ROOT/bin/stage-profile" "$AUTH_STAGING" "$AUTH_PROFILE.conf" "${AUTH_STAGE_ARGS[@]}" \
  < "$WORK/auth-base.conf" >/dev/null
check "staged the credential profile" $?

"$ROOT/bin/install-profile" install openvpn "$AUTH_PROFILE" "$AUTH_STAGING" >/dev/null
check "installed the credential profile" $?

# Starting before any credentials exist. The config names a file that is not
# there, which is the state every such profile sits in between import and the
# first save — so it must say so in words rather than quoting a path.
systemctl start "$AUTH_UNIT" >/dev/null 2>&1
check "a profile with no saved credentials will not start" $(( $? != 0 ? 0 : 1 ))

journalctl -u "$AUTH_UNIT" -n 40 --no-pager -o cat > "$WORK/journal-nocreds.txt" 2>&1
NOCREDS_SAYS="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const M = load("Model.js")
  const fs = require("fs")
  console.log(M.journalError(fs.readFileSync(process.argv[1], "utf8")))
' "$WORK/journal-nocreds.txt")"
echo "# the panel says: $NOCREDS_SAYS"
[[ $NOCREDS_SAYS == *"have not been saved yet"* ]]
check "the panel explains that credentials are missing" $? \
  "got: $NOCREDS_SAYS"$'\n'"journal:"$'\n'"$(cat "$WORK/journal-nocreds.txt")"

# The secret goes in on stdin, exactly as Service.qml sends it.
printf '%s\n%s\n' "$AUTH_USER" "wrong-password" \
  | "$ROOT/bin/install-profile" set-credentials openvpn "$AUTH_PROFILE" >/dev/null
check "the helper stored credentials read from stdin" $?

AUTH_STAT="$(stat -c '%U:%G:%a' "$AUTH_FILE" 2>/dev/null || echo missing)"
[[ $AUTH_STAT == "openvpn:network:600" ]]
check "the credential file is 0600 and owned like the profile (got '$AUTH_STAT')" $?

# Two lines and nothing else — OpenVPN's own format, so there is no encoding
# to audit and no parser of ours between the file and the daemon.
[[ "$(wc -l < "$AUTH_FILE")" == "2" ]]
check "the credential file is exactly two lines" $? "$(wc -l < "$AUTH_FILE")"

# Unprivileged readability is the entire security argument for choosing this
# over the session keyring, so it is asserted rather than assumed.
if [[ -n ${SUDO_USER-} ]]; then
  sudo -u "$SUDO_USER" cat "$AUTH_FILE" >/dev/null 2>&1
  check "the credential file is unreadable by the user's own processes" \
    $(( $? != 0 ? 0 : 1 ))
else
  echo "ok - SKIP: no SUDO_USER, cannot test unprivileged readability"
  pass=$((pass + 1))
fi

# A wrong password, through a server that actually checks it.
systemctl start "$AUTH_UNIT" >/dev/null 2>&1
check "a wrong password does not connect" $(( $? != 0 ? 0 : 1 ))

journalctl -u "$AUTH_UNIT" -n 40 --no-pager -o cat > "$WORK/journal-auth.txt" 2>&1
AUTH_SAYS="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const M = load("Model.js")
  const fs = require("fs")
  console.log(M.journalError(fs.readFileSync(process.argv[1], "utf8")))
' "$WORK/journal-auth.txt")"
echo "# the panel says: $AUTH_SAYS"

# The requirement in PLAN.md, verbatim: failed auth must surface as "wrong
# username or password", not as a unit error. `AUTH: Received control message:
# AUTH_FAILED` is the daemon's own words and they do not say that.
[[ $AUTH_SAYS == *"rejected the username or password"* ]]
check "the panel says the credentials were rejected, not that a job failed" $? \
  "got: $AUTH_SAYS"$'\n'"journal:"$'\n'"$(cat "$WORK/journal-auth.txt")"

# Correcting them must overwrite in place, not append or leave the old file.
printf '%s\n%s\n' "$AUTH_USER" "$AUTH_PASS" \
  | "$ROOT/bin/install-profile" set-credentials openvpn "$AUTH_PROFILE" >/dev/null
check "credentials can be replaced" $?
[[ "$(wc -l < "$AUTH_FILE")" == "2" ]]
check "replacing them overwrites rather than appends" $? "$(wc -l < "$AUTH_FILE")"

systemctl start "$AUTH_UNIT" >/dev/null 2>&1
check "the right password connects" $? \
  "$(journalctl -u "$AUTH_UNIT" -n 25 --no-pager -o cat 2>&1)"

systemctl is-active --quiet "$AUTH_UNIT"
check "the credential tunnel reached active" $?

# "reconnects later without prompting again" — the file is on disk and the
# daemon reads it itself, so a restart with no UI involved must work.
systemctl restart "$AUTH_UNIT" >/dev/null 2>&1
sleep 3
systemctl is-active --quiet "$AUTH_UNIT"
check "it reconnects from the stored file with nothing to prompt" $? \
  "$(journalctl -u "$AUTH_UNIT" -n 25 --no-pager -o cat 2>&1)"

systemctl stop "$AUTH_UNIT" >/dev/null 2>&1

"$ROOT/bin/install-profile" clear-credentials openvpn "$AUTH_PROFILE" >/dev/null
check "credentials can be cleared" $?
test -f "$AUTH_FILE"
check "clearing removes the file" $(( $? == 1 ? 0 : 1 ))

# Deleting a profile must delete its credentials. It happens because the
# credential file falls under the `$name.*` glob remove already walks — this is
# the assertion that would notice if that stopped being true.
printf '%s\n%s\n' "$AUTH_USER" "$AUTH_PASS" \
  | "$ROOT/bin/install-profile" set-credentials openvpn "$AUTH_PROFILE" >/dev/null
"$ROOT/bin/install-profile" remove openvpn "$AUTH_PROFILE" >/dev/null
check "the credential profile was removed" $?
test -f "$AUTH_FILE"
check "deleting the profile deleted its credentials" $(( $? == 1 ? 0 : 1 ))

kill "$AUTH_SERVER_PID" >/dev/null 2>&1 || true

fi

# ============================================================== WireGuard

# The second backend, through the same privileged path and the same parsers.
# What this really tests is the abstraction: if adding a protocol needed more
# than the one predicted seam, it shows up here as special-casing.
#
# SAFETY: AllowedIPs is the tunnel subnet only, never 0.0.0.0/0. A default
# route would make wg-quick install fwmark rules and take over this machine's
# traffic for the length of the test.
echo "# WireGuard"

if ! command -v wg >/dev/null || ! command -v wg-quick >/dev/null; then
  echo "ok - SKIP: wireguard-tools is not installed"
  pass=$((pass + 1))
else

umask 077
wg genkey > "$WORK/wg-server.key"
wg pubkey < "$WORK/wg-server.key" > "$WORK/wg-server.pub"
wg genkey > "$WORK/wg-client.key"
wg pubkey < "$WORK/wg-client.key" > "$WORK/wg-client.pub"
test -s "$WORK/wg-server.pub" && test -s "$WORK/wg-client.pub"
check "generated a throwaway WireGuard keypair for each end" $?

# The far end, built with raw `wg`/`ip` rather than wg-quick: inside the
# namespace we want no DNS or route machinery, only a peer to talk to.
ip netns exec "$NS" ip link add "$WG_SRV_DEV" type wireguard
ip netns exec "$NS" wg set "$WG_SRV_DEV" \
  listen-port "$WG_PORT" \
  private-key "$WORK/wg-server.key" \
  peer "$(cat "$WORK/wg-client.pub")" allowed-ips "$WG_CLIENT_IP/32"
ip netns exec "$NS" ip addr add "$WG_SRV_IP/24" dev "$WG_SRV_DEV"
ip netns exec "$NS" ip link set "$WG_SRV_DEV" up
ip netns exec "$NS" wg show "$WG_SRV_DEV" >/dev/null 2>&1
check "the WireGuard peer is listening inside the namespace" $?

cat > "$WORK/wg-client.conf" <<WGEOF
[Interface]
PrivateKey = $(cat "$WORK/wg-client.key")
Address = $WG_CLIENT_IP/24

[Peer]
PublicKey = $(cat "$WORK/wg-server.pub")
AllowedIPs = 10.88.1.0/24
Endpoint = $SERVER_IP:$WG_PORT
PersistentKeepalive = 25
WGEOF

# Through the plugin's own parser, not a hand-written file: this is what the
# widget would produce from a profile the user picked.
WG_PLAN_JSON="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const C = load("backends/wireguard/Config.js")
  const fs = require("fs")
  const plan = C.plan(fs.readFileSync(process.argv[1], "utf8"), { name: process.argv[2] })
  fs.writeFileSync(process.argv[3], plan.content)
  console.log(JSON.stringify({ errors: plan.errors, warnings: plan.warnings,
                               endpoint: plan.endpoint, assets: plan.assets.length }))
' "$WORK/wg-client.conf" "$WG_PROFILE" "$WORK/wg-rewritten.conf")"

echo "$WG_PLAN_JSON" | grep -q '"errors":\[\]'
check "the generated WireGuard profile plans cleanly" $? "$WG_PLAN_JSON"

echo "$WG_PLAN_JSON" | grep -q "\"endpoint\":\"$SERVER_IP:$WG_PORT\""
check "the endpoint is read out of [Peer]" $? "$WG_PLAN_JSON"

# The claim that makes this import path simpler than the other one.
echo "$WG_PLAN_JSON" | grep -q '"assets":0'
check "a self-contained profile needs no side files" $? "$WG_PLAN_JSON"

test -s "$WORK/wg-rewritten.conf"
check "the WireGuard config was actually written" $?

WG_STAGING="${XDG_CACHE_HOME:-$HOME/.cache}/connor.vpn/staging/$WG_PROFILE"
"$ROOT/bin/stage-profile" "$WG_STAGING" "$WG_PROFILE.conf" \
  < "$WORK/wg-rewritten.conf" >/dev/null
check "staged the WireGuard profile" $?

"$ROOT/bin/install-profile" install wireguard "$WG_PROFILE" "$WG_STAGING" >/dev/null
check "installed it into /etc/wireguard through the privileged helper" $?

# 0700 root:root, shipped by the package itself. If this ever reads otherwise,
# the helper's profile_owner() table is wrong.
WG_DIR_MODE="$(stat -c '%a %U:%G' /etc/wireguard)"
[[ $WG_DIR_MODE == "700 root:root" ]]
check "/etc/wireguard is 0700 root:root (got '$WG_DIR_MODE')" $?

# --------------------------------------------------------------- the seam

WG_DEVICES_BEFORE="$(ip -j link)"

systemctl start "$WG_UNIT"
check "systemctl start returned success" $? \
  "$(journalctl -u "$WG_UNIT" -n 20 --no-pager -o cat 2>&1)"

for _ in $(seq 1 15); do
  [[ "$(systemctl is-active "$WG_UNIT")" == "active" ]] && break
  sleep 1
done
[[ "$(systemctl is-active "$WG_UNIT")" == "active" ]]
check "the unit reached active" $? "$(journalctl -u "$WG_UNIT" -n 20 --no-pager -o cat 2>&1)"

# The assumption deviceFor() encodes, checked against the kernel rather than
# against wg-quick's documentation.
ip link show "$WG_PROFILE" >/dev/null 2>&1
check "wg-quick named the interface after the profile, as deviceFor() assumes" $?

# And the reason that seam has to exist: prefix discovery cannot find this
# device, so without deviceFor() the widget would have no device at all.
# The empty answer this asserts is also what a node that failed to run
# returns, so the marker makes the two distinguishable — without it this
# assertion passes on a broken toolchain, which is how it reported success
# while nothing had been tested at all.
WG_DISCOVERED="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const M = load("Model.js")
  const before = JSON.parse(process.argv[1]).map(l => l.ifname)
  const after = JSON.parse(process.argv[2]).map(l => l.ifname)
  console.log("ran:" + M.newDevice(before, after, []))
' "$WG_DEVICES_BEFORE" "$(ip -j link)")"
[[ $WG_DISCOVERED == "ran:" ]]
check "prefix discovery finds nothing, so the seam is load-bearing" $? \
  "expected 'ran:', got '$WG_DISCOVERED'"

# ---------------------------------------------------------- telemetry plane

WG_RX1="$(cat "/sys/class/net/$WG_PROFILE/statistics/rx_bytes")"
WG_TX1="$(cat "/sys/class/net/$WG_PROFILE/statistics/tx_bytes")"
ping -c 3 -W 2 "$WG_SRV_IP" >/dev/null 2>&1
check "traffic flows through the WireGuard tunnel" $? "$(wg show "$WG_PROFILE" 2>&1)"
sleep 1
WG_RX2="$(cat "/sys/class/net/$WG_PROFILE/statistics/rx_bytes")"
WG_TX2="$(cat "/sys/class/net/$WG_PROFILE/statistics/tx_bytes")"

[[ $WG_TX2 -gt $WG_TX1 && $WG_RX2 -gt $WG_RX1 ]]
check "byte counters moved (rx $WG_RX1 -> $WG_RX2, tx $WG_TX1 -> $WG_TX2)" $?

# The same unprivileged kernel telemetry as the other backend, running the
# identical code — which is the claim the protocol-agnostic plane rests on.
WG_PARSED="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const M = load("Model.js")
  console.log(JSON.stringify(M.parseAddresses(process.argv[1], process.argv[2])))
' "$(ip -j addr show "$WG_PROFILE")" "$WG_PROFILE")"
echo "#   addresses parsed: $WG_PARSED"
[[ $WG_PARSED == *"$WG_CLIENT_IP/24"* ]]
check "Model.parseAddresses() reads a real WireGuard device" $? "got: $WG_PARSED"

# It must NOT be the default route. If this ever reports true, the test has
# taken over the host's traffic and the AllowedIPs above are wrong.
WG_DEFAULT="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const M = load("Model.js")
  console.log(String(M.defaultRouteVia(process.argv[1], process.argv[2])))
' "$(ip -j route)" "$WG_PROFILE")"
[[ $WG_DEFAULT == "false" ]]
check "a split-tunnel profile is correctly not the default route" $? \
  "defaultRouteVia said '$WG_DEFAULT'"

# A profile that pushes no DNS must read as no resolvers, not as an error.
WG_DNS="$(cd "$ROOT" && "$NODE" -e '
  const {load} = require("./test/qmljs")
  const M = load("Model.js")
  console.log(JSON.stringify(M.parseResolvers(process.argv[1], process.argv[2])))
' "$(resolvectl status "$WG_PROFILE" 2>/dev/null || true)" "$WG_PROFILE")"
echo "#   resolvers parsed: $WG_DNS"
[[ $WG_DNS == "[]" ]]
check "a profile with no DNS reports no resolvers rather than failing" $? "got: $WG_DNS"

# Pins the Phase 2 decision to drop last-handshake age. If this ever starts
# succeeding, the stat has become available and the decision can be revisited.
if [[ -n ${SUDO_USER-} ]]; then
  sudo -u "$SUDO_USER" wg show "$WG_PROFILE" >/dev/null 2>&1
  check "wg show still needs root, so handshake age stays unavailable" \
    $(( $? != 0 ? 0 : 1 ))
else
  echo "ok - SKIP: no SUDO_USER, cannot test wg show unprivileged"
  pass=$((pass + 1))
fi

# ---------------------------------------------------------------- teardown

systemctl stop "$WG_UNIT"
check "systemctl stop returned success" $?
sleep 1

ip link show "$WG_PROFILE" >/dev/null 2>&1
check "the WireGuard device is gone" $(( $? == 1 ? 0 : 1 ))

"$ROOT/bin/install-profile" remove wireguard "$WG_PROFILE" >/dev/null
check "the WireGuard profile was removed" $?

test -f "/etc/wireguard/$WG_PROFILE.conf"
check "no WireGuard config is left behind" $(( $? == 1 ? 0 : 1 ))

fi

echo "1..$((pass + fail))"
echo "# pass $pass  fail $fail"
[[ $fail -eq 0 ]]
