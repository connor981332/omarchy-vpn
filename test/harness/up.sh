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
  NODE="$(command -v node || true)"
  if [[ -z $NODE ]]; then
    echo "SKIP: node is not installed"
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

{ cat "$WORK/rewritten.conf"; echo "script-security 2"; echo "up $BAD_HOOK"; } \
  > "$WORK/badhook.conf"

"$ROOT/bin/stage-profile" "$BAD_STAGING" "$BAD_PROFILE.conf" "${STAGE_ARGS[@]}" \
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

echo "1..$((pass + fail))"
echo "# pass $pass  fail $fail"
[[ $fail -eq 0 ]]
