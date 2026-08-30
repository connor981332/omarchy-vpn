#!/bin/bash
# Pins Model.escapeUnitName() against the real systemd-escape binary.
#
# Getting this wrong does not fail loudly — it starts the wrong unit, or a unit
# that does not exist — so the escaper is checked against the authority rather
# than against a table someone typed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! command -v systemd-escape >/dev/null; then
  echo "SKIP: systemd-escape not on PATH"
  exit 0
fi

# Resolved by RUNNING a candidate, never by finding one. A bare `node` here is
# the version-manager shim: present, executable, and exiting non-zero with an
# empty stdout when no version is pinned. The loop below then reads zero lines,
# compares nothing, and reports that all 15 names matched — which is what it
# did until this was fixed.
NODE="${NODE:-$("$ROOT/test/find-node.sh" || true)}"
if [[ -z $NODE ]]; then
  echo "not ok - no working node to run the escaper with"
  exit 1
fi

NAMES=(
  "plain"
  "work:vpn"
  "my vpn"
  "a/b"
  ".hidden"
  "ok-name_1.2"
  "a@b"
  'a\b'
  "ünïcode"
  "a.b"
  "UPPER_case-99"
  "tab	sep"
  "trailing "
  "%percent%"
  "quote'and\"dq"
)

fail=0
compared=0
while IFS=$'\x1f' read -r name ours; do
  theirs="$(systemd-escape -- "$name")"
  compared=$((compared + 1))
  if [[ $ours != "$theirs" ]]; then
    printf 'not ok - %-16s ours=%-24s systemd=%s\n' "$name" "$ours" "$theirs"
    fail=1
  else
    printf 'ok - %-16s -> %s\n' "$name" "$ours"
  fi
done < <("$NODE" "$ROOT/test/escape-pin.js" "${NAMES[@]}")

# The count is itself an assertion. Every comparison here passes by matching,
# so a run that produced no comparisons at all is indistinguishable from a
# clean one unless the number is checked.
if [[ $compared -ne ${#NAMES[@]} ]]; then
  echo "not ok - ran: compared $compared names, expected ${#NAMES[@]}"
  fail=1
fi

if [[ $fail -eq 0 ]]; then
  echo "ok - ran: all ${#NAMES[@]} names compared against systemd-escape"
else
  echo "# escaping DIVERGES from systemd-escape, or did not run"
fi
exit $fail
