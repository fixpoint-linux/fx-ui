#!/usr/bin/env bash
# selfhost-audit.sh — M13 ground-truth audit of the selfhost group.
#
# Compiles every file of the M13 selfhost group (elm-compiler/selfhost/
# manifest.json: the compiler's own frontend + the vendored parse closure +
# NativeMain) with the CURRENT stock-built compiler (node elm-compiler/run.js
# --batch), ONE FILE PER GROUP, plus one FINAL WHOLE-GROUP pass, and tabulates
# per-file, per-class outcomes:
#
#   parse-error / unknown-name / type-error / lowering-error
#
# The classes (and why the audit must keep them apart):
#   * parse-error    — the compiler can't even READ the file (missing
#                      frontend syntax). Fix = parser/AST surface work.
#   * unknown-name   — syntax parses, the name doesn't resolve (no alias-table
#                      row / global). Fix = Prelude/core-libs (Char/String...)
#                      shims + alias tables.
#   * type-error     — the REAL HM typechecker (Type/Infer.elm) rejects
#                      idiomatic Elm (no typeclasses, row-record limits...).
#                      Fix = typechecker waves.  EXPECTED here and wanted:
#                      this is ground truth, not noise.
#   * lowering-error — resolution/typecheck OK, Zinc emission lacks the
#                      construct (pattern-compiler gaps, forbidden decls).
#
# Cost control: every node process pays the fixed corpus pass (~6s), so the
# per-file pass runs as CHUNKED batched invocations (AUDIT_CHUNK groups per
# node process; Main compiles all of that chunk's groups in one run, corpus
# paid once per chunk).  Main reports ONE error per group (first failure
# wins), so each per-file row is the FIRST error in that file.  M14 iterates:
# fix, re-run this script, watch failure rows drop.
#
# Usage: tools/selfhost-audit.sh    (writes tools/selfhost-audit.txt)
#
# Exit 0 if the audit ran (failures inside it are EXPECTED — it is M14's
# worklist); 2 on tooling problems (missing compiler.js, bad manifest, node).

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CDIR="$ROOT/elm-compiler"
MANIFEST="$CDIR/selfhost/manifest.json"
OUTTXT="$ROOT/tools/selfhost-audit.txt"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CHUNK=${AUDIT_CHUNK:-16} # groups per batched node process

command -v node >/dev/null 2>&1 || { echo "node not found" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq not found" >&2; exit 2; }
[ -f "$CDIR/compiler.js" ] || {
  echo "elm-compiler/compiler.js missing (run elm-compiler/build.sh on a host with stock elm)" >&2
  exit 2
}
[ -f "$MANIFEST" ] || { echo "manifest missing: $MANIFEST" >&2; exit 2; }

# ---------------- read the manifest (repo-root-relative paths) ----------------
cd "$ROOT" || exit 2
mapfile -t SOURCES < <(jq -r '.groups[0].sources[]' "$MANIFEST")
N=${#SOURCES[@]}
[ "$N" -gt 0 ] || { echo "manifest has no sources" >&2; exit 2; }
while IFS= read -r f; do
  [ -f "$f" ] || { echo "manifest source missing on disk: $f" >&2; exit 2; }
done < <(printf '%s\n' "${SOURCES[@]}")

# ---------------- classify a run.js err payload ----------------
classify() {
  # $1 = group output payload ("err <msg>"); echoes the audit CLASS
  local msg="${1#err }"
  case "$msg" in
  "parse failed") echo "parse-error" ;;
  # "unknown name" arrives from BOTH the lowerer (bare) and the typechecker
  # (ranged: "type error at r:c: unknown name: ...") — it is the NAMES WE
  # DON'T KNOW class either way (fix = shims/tables, not checker work)
  *unknown\ name:*) echo "unknown-name" ;;
  "type error at "*) echo "type-error" ;;
  # everything else is emitted by the LOWERING pass (Lower/Module|Expr|
  # Pattern|Resolve): "port/infix declarations are not supported", "M1b
  # supports only variable patterns...", "unsupported operator...",
  # "duplicate top-level definition...", alias-arity messages
  *) echo "lowering-error" ;;
  esac
}

detail_of() {
  # payload -> one folded line (message sans "err "; type errors keep row:col)
  printf '%s' "${1#err }" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//'
}

loc_of() {
  # payload -> "row:col" for type errors, else empty
  printf '%s' "${1#err }" | grep -oE 'type error at [0-9]+:[0-9]+' |
    grep -oE '[0-9]+:[0-9]+' | head -1
}

# ================ PHASE 1: per-file groups, chunk-batched ================
# One group PER FILE, including the file's TRANSITIVE SELFHOST-SIBLING DEPS:
# a lone file cannot resolve names from its vendored/frontend siblings (the
# corpus side only knows the corpus modules), which would misreport every
# sibling reference as an unknown name.  Check.topo re-orders each group into
# dependency order, so the FIRST error a group reports belongs to the deepest
# failing member; at tabulation we annotate rows whose message equals a
# dependency's row as INHERITED (the file itself may be clean).
: >"$TMP/groups.jsonl"
python3 - "$MANIFEST" "$TMP" "$CHUNK" <<'PYEOF'
import json, re, sys
from pathlib import Path

manifest, tmp, chunk = sys.argv[1], sys.argv[2], int(sys.argv[3])
sources = json.load(open(manifest))["groups"][0]["sources"]

def module_of(rel):
    # repo-root-relative path -> Elm module name
    p = rel
    for prefix in ("elm-compiler/selfhost/vendor/", "elm-compiler/selfhost/",
                   "elm-compiler/src/"):
        if p.startswith(prefix):
            p = p[len(prefix):]
            break
    else:
        raise SystemExit("manifest source outside known roots: " + rel)
    return p[:-4].replace("/", ".")

IMPORT = re.compile(r"^import\s+([A-Z][A-Za-z0-9_.]*)", re.M)
mod_of = {rel: module_of(rel) for rel in sources}
file_of = {mod_of[rel]: rel for rel in sources}

imports = {}
for rel in sources:
    text = Path(rel).read_text()
    imports[mod_of[rel]] = [m for m in IMPORT.findall(text) if m in file_of]

groups = []
for idx, rel in enumerate(sources):
    root = mod_of[rel]
    closure, stack = set(), [root]
    while stack:
        m = stack.pop()
        for dep in imports.get(m, []):
            if dep not in closure and dep != root:
                closure.add(dep)
                stack.append(dep)
    members = [file_of[d]
               for d in sorted(closure, key=lambda m: sources.index(file_of[m]))]
    # audited file first in the LIST (Check re-toposorts for checking order)
    groups.append({"i": idx, "file": rel, "deps": members,
                   "sources": [rel] + members})

for g in groups:
    print(json.dumps(g))
open(tmp + "/groups_meta.json", "w").write(json.dumps(groups))

# chunk manifests: AUDIT_CHUNK groups per node process
for c, start in enumerate(range(0, len(groups), chunk)):
    part = groups[start:start + chunk]
    man = {"groups": [{"sources": g["sources"],
                       "output": "%s/one_%d.csexp" % (tmp, g["i"])}
                      for g in part]}
    json.dump(man, open("%s/chunk_%02d.json" % (tmp, c), "w"))
PYEOF
chunk_fail=0
for chunk in "$TMP"/chunk_*.json; do
  # run.js exits nonzero only on TOOLING failure (bad manifest, timeout);
  # per-group compile failures still write "err ..." payloads and exit 0.
  if ! node "$CDIR/run.js" --batch "$chunk" 2>"$TMP/node.err" >/dev/null; then
    chunk_fail=$((chunk_fail + 1))
    echo "audit: chunk tooling failure: $(tail -c 200 "$TMP/node.err" | tr '\n' ' ')" >&2
  fi
done

# ---------------- tabulate ----------------
total_ok=0 total_parse=0 total_unknown=0 total_type=0 total_lower=0 total_tool=0
: >"$TMP/rows.tsv"

# Map every file to (cls, loc, det); iterate SOURCES in manifest order.
declare -A R_CLS R_LOC R_DET
i=0
for src in "${SOURCES[@]}"; do
  out="$TMP/one_$i.csexp"
  i=$((i + 1))
  payload="$(cat "$out" 2>/dev/null || true)"
  if [ -z "$payload" ]; then
    R_CLS[$src]="TOOLING-FAIL"
    R_DET[$src]="(no output produced by run.js for this group)"
    total_tool=$((total_tool + 1))
    continue
  fi
  case "$payload" in
  err\ *)
    R_CLS[$src]="$(classify "$payload")"
    R_LOC[$src]="$(loc_of "$payload")"
    R_DET[$src]="$(detail_of "$payload")"
    ;;
  *)
    R_CLS[$src]="OK"
    total_ok=$((total_ok + 1))
    ;;
  esac
done

# Inherited-error annotation: for file F with deps D, if F's row is OK or the
# message EQUALS a dep's message, the failure is (or may be) the dep's.
while IFS=$'\t' read -r idx file deps; do
  cls="${R_CLS[$file]:-}"
  [ -n "$cls" ] || continue
  msg="${R_DET[$file]:-}"
  inherited=""
  if [ "$cls" != "OK" ] && [ "$cls" != "TOOLING-FAIL" ] && [ -n "$deps" ]; then
    IFS=';' read -ra DEPS <<<"$deps"
    for d in "${DEPS[@]}"; do
      if [ -n "${R_DET[$d]:-}" ] && [ "${R_DET[$d]}" = "$msg" ]; then
        inherited="$d"
        break
      fi
    done
  fi
  tag="$cls"
  [ -z "$inherited" ] || tag="$cls (INHERITED from $inherited)"
  printf '%s\t%s\t%s\t%s\n' "$tag" "$file" "${R_LOC[$file]:-}" "$msg" >>"$TMP/rows.tsv"
  case "$cls" in
  parse-error) total_parse=$((total_parse + 1)) ;;
  unknown-name) total_unknown=$((total_unknown + 1)) ;;
  type-error) total_type=$((total_type + 1)) ;;
  lowering-error) total_lower=$((total_lower + 1)) ;;
  esac
done < <(python3 -c '
import json, sys
meta = json.load(open(sys.argv[1]))
for g in meta:
    print("%d\t%s\t%s" % (g["i"], g["file"], ";".join(g["deps"])))
' "$TMP/groups_meta.json")

# ================ PHASE 2: whole-group pass ================
# All sources as ONE group — the true self-compile shape (corpus paid once;
# cross-module resolution live).  Its FIRST error is the deepest blocker.
jq --arg out "$TMP/group.csexp" '.groups[0].output = $out' "$MANIFEST" >"$TMP/group.json"
if ! node "$CDIR/run.js" --batch "$TMP/group.json" 2>"$TMP/g.err" >/dev/null; then
  chunk_fail=$((chunk_fail + 1))
fi
payload="$(cat "$TMP/group.csexp" 2>/dev/null || true)"
if [ -n "$payload" ]; then
  # A successful whole-group compile writes the bundle (leading "("), NOT an
  # "err " payload.  `classify` only understands failure payloads, and its
  # substring probes would false-positive on the compiler's OWN embedded
  # error-message STRING LITERALS inside a successful bundle — so the success
  # case is detected here, exactly like the per-file tabulation's `*)` -> OK.
  case "$payload" in
  err\ *)
    group_result="$(classify "$payload")"
    group_detail="$(detail_of "$payload")"
    ;;
  *)
    group_result="OK"
    group_detail=""
    ;;
  esac
else
  group_result="TOOLING-FAIL"
  group_detail="$(tail -c 300 "$TMP/g.err" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g')"
fi

# ================ PHASE 3: report ================
{
  echo "# selfhost-audit.txt — M13 ground-truth audit of the selfhost group"
  echo "# Generated by tools/selfhost-audit.sh.  THIS FILE IS M14'S WORKLIST:"
  echo "# fix rows wave-by-wave (parse -> unknown-name -> type -> lowering),"
  echo "# re-run the script, watch failure rows drop."
  echo "#"
  echo "# Group:    $N sources = 14 compiler frontend (src/{Lower,Type,Zinc})"
  echo "#           + 38 vendored parse-closure files (Json codecs pruned; see"
  echo "#           elm-compiler/selfhost/PRUNING.md) + NativeMain skeleton"
  echo "# Corpus:   src/Prelude.elm + src/Runtime.elm + core-libs/* (fixed side,"
  echo "#           NOT audited — always compiled as the corpus)"
  echo "# Compiler: node elm-compiler/run.js --batch (stock-built compiler.js)"
  echo "# Date:     $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "#"
  echo "# Columns: <RESULT>\t<file>\t<row:col>\t<message>"
  echo "# RESULT classes: OK | parse-error | unknown-name | type-error |"
  echo "#                 lowering-error | TOOLING-FAIL"
  echo "# Per-file rows show the FIRST error only (Main reports one per group)."
  echo "#"
  cat "$TMP/rows.tsv"
  echo "#"
  echo "# ===== whole-group pass (all $N sources as one group) ====="
  printf 'WHOLE-GROUP\t%s\t\t%s\n' "$group_result" "$group_detail"
  echo "#"
  echo "# ===== summary ====="
  echo "# files:          $N"
  echo "# ok:             $total_ok"
  echo "# parse-error:    $total_parse"
  echo "# unknown-name:   $total_unknown"
  echo "# type-error:     $total_type"
  echo "# lowering-error: $total_lower"
  echo "# tooling-fail:   $total_tool"
} >"$OUTTXT"

echo "wrote $OUTTXT ($N files: $total_ok ok, $total_parse parse, $total_unknown unknown, $total_type type, $total_lower lowering, $total_tool tooling; whole-group: $group_result)"
[ "$chunk_fail" -eq 0 ] || echo "audit: NOTE $chunk_fail chunk(s) hit node-level tooling failure (see TOOLING-FAIL rows)" >&2
exit 0
