#!/bin/bash
# Prints the path of a node that actually RUNS, or exits 1.
#
# `command -v node` is not enough, and the difference is not academic — it cost
# a full integration run. A version manager puts a shim on PATH that is present
# and executable but resolves to nothing when no version is pinned for the
# current directory: it exits non-zero with a message on stderr and prints
# nothing on stdout. Every node call in the suite then yields an empty string,
# and the assertions that compare against "" PASS.
#
# A test that passes because its tooling is broken is worse than one that
# fails, so running the candidate is the check, not inspecting it.
set -uo pipefail

runs() {
  [[ -n ${1-} && -x $1 ]] && "$1" -e 'process.stdout.write("ok")' >/dev/null 2>&1
}

# An explicit NODE wins, then whatever is on PATH.
for candidate in "${NODE-}" "$(command -v node 2>/dev/null || true)"; do
  if runs "$candidate"; then echo "$candidate"; exit 0; fi
done

# Neither ran. Look past the shim at what the version manager actually
# installed — this is the case where PATH has a shim with no version pinned.
for candidate in "$HOME"/.local/share/mise/installs/node/*/bin/node \
                 "$HOME"/.nvm/versions/node/*/bin/node \
                 "$HOME"/.asdf/installs/nodejs/*/bin/node \
                 /usr/local/bin/node /usr/bin/node; do
  if runs "$candidate"; then echo "$candidate"; exit 0; fi
done

exit 1
