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

# Guard against a stale compiled-package cache: elm 0.19.2 never re-verifies
# package content once a package's artifacts.dat exists, so a patched vendored
# source is silently ignored until its artifacts.dat is regenerated.  If any
# package src file is newer than that package's artifacts.dat, drop the stale
# artifacts.dat (and elm-stuff, which embeds the old package interfaces) so elm
# rebuilds it from source.
stale=0
for pkg in "$PWD/.elm-cache/0.19.2/packages"/*/*/*/; do
  [ -d "$pkg/src" ] || continue
  [ -f "$pkg/artifacts.dat" ] || continue
  if [ -n "$(find "$pkg/src" -type f -newer "$pkg/artifacts.dat" -print -quit 2>/dev/null)" ]; then
    echo "build.sh: stale artifacts.dat in ${pkg%/} (source newer) -> removing" >&2
    rm -f "$pkg/artifacts.dat"
    stale=1
  fi
done
if [ "$stale" = 1 ]; then
  rm -rf "$PWD/elm-stuff"
fi

ELM_HOME="$PWD/.elm-cache" "$ELM" make src/Main.elm --output=compiler.js
