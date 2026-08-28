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
while IFS=$'\x1f' read -r name ours; do
  theirs="$(systemd-escape -- "$name")"
  if [[ $ours != "$theirs" ]]; then
    printf 'not ok - %-16s ours=%-24s systemd=%s\n' "$name" "$ours" "$theirs"
    fail=1
  else
    printf 'ok - %-16s -> %s\n' "$name" "$ours"
  fi
done < <(node "$ROOT/test/escape-pin.js" "${NAMES[@]}")

if [[ $fail -eq 0 ]]; then
  echo "# escaping matches systemd-escape for ${#NAMES[@]} names"
else
  echo "# escaping DIVERGES from systemd-escape"
fi
exit $fail
