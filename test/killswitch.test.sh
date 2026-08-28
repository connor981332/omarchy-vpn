#!/bin/bash
# The kill switch, end to end, with no root at all.
#
# `unshare --user --map-root-user --net` gives a private network namespace with
# its own nftables ruleset, so the real rules can be applied to real interfaces
# and real packets counted — while the host's ruleset is never touched. That
# matters more here than anywhere else in this project: the thing under test
# takes machines off the network.
#
# Every assertion is about a packet, not about the text of a rule. A rule set
# that reads correctly and drops the tunnel's own handshake is exactly the
# failure this is here to catch.
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

if ! command -v nft >/dev/null 2>&1; then
  echo "# nft is missing, which should be impossible on Omarchy (ufw -> iptables -> nftables)"
  echo "1..0"
  exit 1
fi

if ! unshare --user --map-root-user --net --mount -- true 2>/dev/null; then
  echo "# unprivileged user namespaces are unavailable; cannot test without root"
  echo "1..0"
  exit 0
fi

# --------------------------------------------------------------------- inside
#
# Everything that needs a namespace runs in one shot and reports back as TAP,
# because entering the namespace per assertion would cost a fork each and lose
# the state between them.

echo "# rules, against real packets in a private namespace"

# Captured rather than streamed, so the inner TAP can be tallied. An inner
# `not ok` that only printed would leave this suite green — and a namespace
# that never started at all would look exactly like one where everything
# passed. Both are counted below, and the count itself is asserted.
INNER_OUT="$(mktemp)"
trap 'rm -f -- "$INNER_OUT"' EXIT

unshare --user --map-root-user --net --mount -- bash -s -- "$ROOT" > "$INNER_OUT" 2>&1 <<'INNER'
set -uo pipefail
ROOT="$1"
cd "$ROOT" || exit 1

say() { echo "$@"; }

mount -t tmpfs none /run 2>/dev/null

ip link set lo up
ip link add uplink type dummy && ip addr add 192.168.50.2/24 dev uplink && ip link set uplink up
ip link add tun0 type dummy && ip addr add 10.88.0.2/24 dev tun0 && ip link set tun0 up
ip route add default via 192.168.50.1 dev uplink
ip route add 10.77.0.1/32 via 192.168.50.1 dev uplink
# IPv6 too, and this is not decoration: without a v6 route the kernel refuses
# the ping before a packet exists, the OUTPUT hook never runs, and the leak
# assertion below passes without having tested anything.
ip -6 addr add 2001:db8::2/64 dev uplink
ip -6 route add default via 2001:db8::1 dev uplink

# The counter on a named rule, which is the only evidence that says what the
# kernel actually did with a packet.
counter_for() {
  nft list table inet connor_vpn_killswitch 2>/dev/null \
    | awk -v want="comment \"$1\"" '
        index($0, want) { for (i = 1; i < NF; i++) if ($i == "packets") { print $(i + 1); exit } }'
}

# Pure bash, so the suite depends on nothing that is not already guaranteed:
# no socat, no nc. The connection is never answered and does not need to be —
# the packet has already been through the OUTPUT hook by then.
udp_to() { (echo x > "/dev/udp/$1/$2") >/dev/null 2>&1; }

./bin/killswitch on tun0 10.77.0.1 1194 udp >/dev/null 2>&1
if [[ $? -eq 0 ]]; then say "ok - arming succeeds in a namespace"; else say "not ok - arming succeeds in a namespace"; fi

# --- the four things that must still work ---
before="$(counter_for blocked)"
ping -c1 -W1 192.168.50.1 >/dev/null 2>&1
lan="$(counter_for lan)"
[[ ${lan:-0} -gt 0 ]] && say "ok - the local network is still reachable" \
  || say "not ok - the local network is still reachable (lan counter ${lan:-unset})"

# Loopback. Nothing on the machine survives losing it, and the rule that
# permits it carries no counter of its own -- so without this the rule could
# be deleted outright and every other assertion here would still pass.
before="$(counter_for blocked)"
ping -c1 -W1 127.0.0.1 >/dev/null 2>&1
lo_ok=$?
after="$(counter_for blocked)"
[[ $lo_ok -eq 0 && ${after:-0} -eq ${before:-0} ]] \
  && say "ok - loopback is untouched" \
  || say "not ok - loopback is untouched (ping rc $lo_ok, blocked ${before} -> ${after})"

udp_to 10.77.0.1 1194
ep="$(counter_for endpoint)"
[[ ${ep:-0} -gt 0 ]] \
  && say "ok - the tunnel's own traffic to the endpoint is permitted" \
  || say "not ok - the tunnel's own traffic to the endpoint is permitted (endpoint counter ${ep:-unset})"

ping -c1 -W1 10.88.0.9 >/dev/null 2>&1
after_tun="$(counter_for blocked)"
[[ ${after_tun:-0} -eq ${before:-0} ]] \
  && say "ok - traffic inside the tunnel is not touched" \
  || say "not ok - traffic inside the tunnel is not touched (blocked went ${before} -> ${after_tun})"

# --- the things that must not ---
before="$(counter_for blocked)"
ping -c1 -W1 1.1.1.1 >/dev/null 2>&1
after="$(counter_for blocked)"
[[ ${after:-0} -gt ${before:-0} ]] \
  && say "ok - a packet to the internet outside the tunnel is blocked" \
  || say "not ok - a packet to the internet outside the tunnel is blocked (blocked ${before} -> ${after})"

# The LAN pass would otherwise re-open DNS to the router, and every query with
# it. This is the rule whose ORDER is the whole point.
udp_to 192.168.50.1 53
dns="$(counter_for dns)"
[[ ${dns:-0} -gt 0 ]] \
  && say "ok - DNS to the local router is dropped, not waved through by the LAN rule" \
  || say "not ok - DNS to the local router is dropped (dns counter ${dns:-unset})"

# IPv6 is the classic way a kill switch leaks: an ip-family table would let
# every v6 packet past without appearing to.
before="$(counter_for blocked)"
ping -c1 -W1 2606:4700:4700::1111 >/dev/null 2>&1
after="$(counter_for blocked)"
[[ ${after:-0} -gt ${before:-0} ]] \
  && say "ok - IPv6 does not leak past an inet-family table" \
  || say "not ok - IPv6 does not leak past an inet-family table (blocked ${before} -> ${after})"

# --- the full-tunnel shape ---
#
# Everything above ran with the default route on the physical interface, which
# is the split-tunnel case. A real profile pushes redirect-gateway and the
# default route becomes the tunnel — and then the endpoint rule is the only
# thing keeping the tunnel's own packets alive. If it does not hold here, the
# switch deadlocks the connection it is protecting.
ip route del default via 192.168.50.1 dev uplink
ip route add default dev tun0
before="$(counter_for endpoint)"
udp_to 10.77.0.1 1194
after="$(counter_for endpoint)"
[[ ${after:-0} -gt ${before:-0} ]] \
  && say "ok - with the default route in the tunnel, the endpoint is still reachable" \
  || say "not ok - with the default route in the tunnel, the endpoint is still reachable (endpoint ${before} -> ${after})"
ip route del default dev tun0
ip route add default via 192.168.50.1 dev uplink

# --- coexistence ---
#
# ufw is in Omarchy's base packages and Omarchy configures it, so ours is never
# the only table. `accept` in another table means "carry on to the next base
# chain", not "allow"; only `drop` is final. Our verdict therefore does not
# depend on priority or on load order.
nft -f - >/dev/null 2>&1 <<OTHER
table ip other_owner {
  chain out { type filter hook output priority filter; policy accept;
    ip daddr 1.1.1.1 counter accept comment "other-owner"
  }
}
OTHER
before="$(counter_for blocked)"
ping -c1 -W1 1.1.1.1 >/dev/null 2>&1
after="$(counter_for blocked)"
[[ ${after:-0} -gt ${before:-0} ]] \
  && say "ok - another table's explicit accept does not override our drop" \
  || say "not ok - another table's explicit accept does not override our drop"

./bin/killswitch off >/dev/null 2>&1
nft list table ip other_owner >/dev/null 2>&1 \
  && say "ok - disarming leaves the other owner's table intact" \
  || say "not ok - disarming leaves the other owner's table intact"

# --- connectivity comes back ---
before_lan_rules="$(nft list ruleset 2>/dev/null | grep -c connor_vpn_killswitch)"
[[ ${before_lan_rules:-1} -eq 0 ]] \
  && say "ok - disarming removes every rule we added" \
  || say "not ok - disarming removes every rule we added"

# --- the marker ---
./bin/killswitch on tun0 10.77.0.1 1194 udp >/dev/null 2>&1
mode="$(stat -c '%a' /run/connor-vpn/killswitch 2>/dev/null || echo missing)"
[[ $mode == "644" ]] \
  && say "ok - the marker is world-readable, so the widget can read it unprivileged" \
  || say "not ok - the marker is world-readable (mode '$mode')"

grep -q '^armed=1$' /run/connor-vpn/killswitch 2>/dev/null \
  && say "ok - the marker says it is armed" || say "not ok - the marker says it is armed"

# The marker is a mirror, and a mirror that outlives what it reflects is worse
# than none: the panel would claim a protection that is not there.
nft delete table inet connor_vpn_killswitch >/dev/null 2>&1
./bin/killswitch status >/dev/null 2>&1
[[ ! -f /run/connor-vpn/killswitch ]] \
  && say "ok - status repairs a marker whose table has gone" \
  || say "not ok - status repairs a marker whose table has gone"

./bin/killswitch off >/dev/null 2>&1
INNER

cat "$INNER_OUT"

# No `|| echo 0` here: `grep -c` already prints 0 when it matches nothing, and
# it exits 1 while doing so — so the fallback appended a SECOND zero and every
# arithmetic expression below died on "0\n0". It only happened when the inner
# assertions all passed, which is exactly when nobody looks.
inner_ok="$(grep -c '^ok - ' "$INNER_OUT" 2>/dev/null)"
inner_bad="$(grep -c '^not ok - ' "$INNER_OUT" 2>/dev/null)"
pass=$((pass + inner_ok))
fail=$((fail + inner_bad))

# `command -v node` does not mean node runs, and a namespace that exits early
# does not mean its assertions passed. The count is the marker that says the
# body actually executed.
EXPECTED_INNER=15
if [[ $((inner_ok + inner_bad)) -eq $EXPECTED_INNER ]]; then
  check "ran: all $EXPECTED_INNER namespace assertions executed" 0
else
  check "ran: all $EXPECTED_INNER namespace assertions executed" 1 \
    "only $((inner_ok + inner_bad)) reported — the namespace exited early"
fi

echo "# argument validation — the caller is unprivileged and untrusted"

# These never reach nft, so they need no namespace: they must be refused before
# anything is built. Run without privilege on purpose — a refusal that only
# happens as root is not a refusal.
refuses() {
  local name="$1"; shift
  local out
  out="$("$ROOT/bin/killswitch" "$@" 2>&1)"
  if [[ $? -ne 0 ]] && grep -qi "$name" <<< "$out"; then
    check "refuses $name" 0
  else
    check "refuses $name" 1 "$out"
  fi
}

refuses "usage"
refuses "usage" on
refuses "usage" on tun0
refuses "usage" on tun0 10.0.0.1
refuses "invalid device name" on "../etc" 10.0.0.1 1194 udp
refuses "invalid device name" on 'tun0;nft' 10.0.0.1 1194 udp
refuses "device name too long" on aaaaaaaaaaaaaaaaaaaa 10.0.0.1 1194 udp
refuses "invalid port" on tun0 10.0.0.1 "1194; rm -rf /" udp
refuses "port out of range" on tun0 10.0.0.1 99999 udp
refuses "invalid protocol" on tun0 10.0.0.1 1194 icmp
refuses "invalid endpoint" on tun0 '$(id)' 1194 udp
# Empty is caught one step earlier, by the usage check — asserted where it
# actually happens rather than where it reads best.
refuses "usage" on tun0 "" 1194 udp

echo "# a name that could rewrite the rule set is refused before nft sees it"
# The values are interpolated into an nft script, so validation is the whole
# security boundary here — the same argument as install-profile's name check.
if grep -q 'validate_device\|validate_port\|validate_proto\|validate_endpoint' bin/killswitch; then
  check "every argument has a validator" 0
else
  check "every argument has a validator" 1
fi

# An endpoint that resolves to nothing would produce an empty set, and an empty
# set silently blocks the tunnel the switch is supposed to protect.
out="$("$ROOT/bin/killswitch" on tun0 zz-definitely-not-a-host.invalid 1194 udp 2>&1)"
if [[ $? -ne 0 ]] && grep -qi "could not resolve" <<< "$out"; then
  check "refuses an endpoint that resolves to nothing" 0
else
  check "refuses an endpoint that resolves to nothing" 1 "$out"
fi

echo "# the recovery path is documented where someone offline can find it"
# A kill switch that can only be turned off from a GUI you cannot reach is a
# trap. This is the one piece of documentation that is load-bearing.
if grep -q 'bin/killswitch off' README.md; then
  check "README documents the terminal recovery command" 0
else
  check "README documents the terminal recovery command" 1
fi

if grep -q 'bin/killswitch off' Panel.qml; then
  check "the panel shows the recovery command when nothing is connected" 0
else
  check "the panel shows the recovery command when nothing is connected" 1
fi

echo "1..$((pass + fail))"
echo "# pass $pass  fail $fail"
[[ $fail -eq 0 ]]
