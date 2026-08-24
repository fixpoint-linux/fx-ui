#!/usr/bin/env bash
# M0 bootstrap: compile the elm-compiler (stil4m/elm-syntax 7.3.9) offline
# against the repo-local ELM_HOME cache, producing compiler.js (a Node-loadable
# CommonJS module with the Elm runtime for run.js).
#
# NOTE on offline builds: elm 0.19.2 still fetches the all-packages registry
# (package.elm-lang.org/all-packages) to validate dependency constraints even
# when the full package cache is present.  With a working network (host) this
# succeeds.  In a DNS-less sandbox it fails with a ConnectionFailure — in that
# case run this on the host.  The .elm-cache/registry.dat is kept fresh so a
# host run needs no re-download of the packages themselves.
set -euo pipefail
cd "$(dirname "$0")"

# Locate the elm 0.19.2 binary: prefer one already on PATH; else the shen repo's
# node_modules copy (which ships the platform binary); else a repo-local copy.
# shen is a SIBLING of fx-ui (both under /mnt/workspace or /workspace).
if command -v elm >/dev/null 2>&1; then
  ELM="elm"
elif [ -x "$(dirname "$0")/../../shen/node_modules/.bin/elm" ]; then
  ELM="$(dirname "$0")/../../shen/node_modules/.bin/elm"
elif [ -x /workspace/shen/node_modules/.bin/elm ]; then
  ELM="/workspace/shen/node_modules/.bin/elm"
elif [ -x /mnt/workspace/shen/node_modules/.bin/elm ]; then
  ELM="/mnt/workspace/shen/node_modules/.bin/elm"
else
  echo "build.sh: no elm binary found (tried PATH, ../../shen/node_modules, /workspace/shen/node_modules, /mnt/workspace/shen/node_modules)" >&2
  exit 1
fi

ELM_HOME="$PWD/.elm-cache" "$ELM" make src/Main.elm --output=compiler.js
