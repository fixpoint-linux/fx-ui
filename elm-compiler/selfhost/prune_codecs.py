#!/usr/bin/env python3
"""M13 codec prune: strip Json encode/decode codecs from the vendored
stil4m/elm-syntax parse closure (elm-compiler/selfhost/vendor).

The compiler's parse->typecheck->lower path never serializes the AST, so every
`encode`/`decoder` in Elm/Syntax/** (and Elm.RawFile) is DEAD for self-hosting.
Removing them (a) prunes the elm/json dependency surface and (b) deletes the
bulk of the lines the self-compile would otherwise have to typecheck.

Surgery per file (whole-file transform, then one atomic write):
  1. drop `import Json.Decode ...` / `import Json.Encode ...` /
     `import Elm.Json.Util ...`
  2. drop `encode`/`decoder` entries from the exposing list and `@docs` rows;
     drop `## Serialization` doc headers
  3. drop top-level definitions whose name starts with encode/decode
     (signature + body + attached doc comment)
  4. usage sweep: drop blocks that are now unreferenced AND reference codec
     machinery (e.g. Range.fromList); never touches parse-path helpers

Idempotent.  --check verifies without writing.
"""

import re
import sys
from pathlib import Path

VENDOR = Path(__file__).resolve().parent / "vendor"

SIG = re.compile(r"^([a-z][A-Za-z0-9_]*)\s*:")
IMPORT_DROP = re.compile(r"^import (Json\.Decode|Json\.Encode|Elm\.Json\.Util)\b")
CODEC_NAME = re.compile(r"\b(encode|decoder|decodeTyped|encodeTyped)\b")
CODEC_DEF = re.compile(r"\b(JD|JE)\b|\bDecoder\b|\bValue\b|decodeTyped|encodeTyped")


def is_codec_name(name):
    return bool(
        re.match(r"encode|decode", name)
        or "Decoder" in name
        or "Encoder" in name
    )
DOCS_LINE = re.compile(r"^(\s*,?\s*@docs )(.*?)\s*$")
DOC_BLOCK = re.compile(r"^\{-\|")


def top_blocks(lines):
    """(name, start, end) for every top-level definition: signature line up
    to (exclusive) the next top-level signature."""
    sigs = [i for i, ln in enumerate(lines) if SIG.match(ln)]
    out = []
    for k, i in enumerate(sigs):
        end = sigs[k + 1] if k + 1 < len(sigs) else len(lines)
        out.append((SIG.match(lines[i]).group(1), i, end))
    return out


def extend_to_doc(lines, start):
    """Pull an immediately-preceding {-|-} doc comment (and its blank line)
    into the removal range so we don't leave orphaned doc comments.  The
    comment's LAST line ends with "-}" — scan back to the line containing
    "{-|".  If there is no doc comment there, return start unchanged."""
    i = start
    while i > 0 and lines[i - 1].strip() == "":
        i -= 1
    if i > 0 and lines[i - 1].rstrip().endswith("-}"):
        j = i - 1
        while j > 0 and "{-|" not in lines[j]:
            j -= 1
        if "{-|" in lines[j]:
            if j > 0 and lines[j - 1].strip() == "":
                j -= 1
            return j
    return start


def prune_text(text):
    lines = text.split("\n")
    changed = False

    # 1. codec imports
    kept = [ln for ln in lines if not IMPORT_DROP.match(ln)]
    if len(kept) != len(lines):
        changed = True
    lines = kept

    # 2. exposing list: remove codec entries; drop a line left empty.
    # Track the list with PAREN BALANCE (not a bare ')' — exposing rows like
    # `Expression(..)` contain parens of their own).
    out = []
    depth = 0
    in_exposing = False
    for ln in lines:
        if ln.startswith("module "):
            in_exposing = True
            out.append(ln)
            continue
        if in_exposing:
            line_depth = ln.count("(") - ln.count(")")
            if re.search(r"\b\w*(encode|decode|Decoder|Encoder)\w*", ln):
                # token-level removal: drop every exposing entry that is a
                # codec (encode*/decode*/*Decoder*/*Encoder*)
                indent = re.match(r"\s*", ln).group(0)
                trailing = ")" if ln.rstrip().endswith(")") else ""
                toks = [t.strip() for t in ln.strip().rstrip(")").split(",")]
                toks = [t for t in toks if t and not is_codec_name(t)]
                new = None if not toks else indent + ", ".join(toks) + (" )" if trailing else "")
                changed = True
                out.append(new)
            else:
                out.append(ln)
            depth += line_depth
            if depth <= 0:
                in_exposing = False
            continue
        m = DOCS_LINE.match(ln)
        if m and re.search(r"\b\w*(encode|decode|Decoder|Encoder)\w*", m.group(2)):
            names = [n.strip() for n in m.group(2).split(",")]
            names = [n for n in names if n and not is_codec_name(n)]
            if names:
                out.append(m.group(1) + ", ".join(names))
            else:
                out.append(None)
            changed = True
            continue
        if ln.strip() == "## Serialization" or ln.strip() == "-- Serialization":
            out.append(None)
            changed = True
            continue
        out.append(ln)
    lines = [ln for ln in out if ln is not None]

    # 3+4. drop codec defs, then usage-sweep orphaned codec-only helpers
    while True:
        blks = top_blocks(lines)
        codec_defs = {
            i for name, i, end in blks if is_codec_name(name)
        }
        if codec_defs:
            changed = True
        else:
            # sweep: block never referenced outside itself and mentions codecs
            for name, i, end in blks:
                if is_codec_name(name):
                    continue
                chunk = "\n".join(lines[i:end])
                if not CODEC_DEF.search(chunk):
                    continue
                rest = lines[:i] + lines[end:]
                if not re.search(r"\b%s\b" % re.escape(name), "\n".join(rest)):
                    codec_defs.add(i)
        if not codec_defs:
            break
        drop = set()
        for i in codec_defs:
            end = next((e for nm, s, e in blks if s == i), len(lines))
            drop.update(range(extend_to_doc(lines, i), end))
        lines = [ln for i, ln in enumerate(lines) if i not in drop]

    # collapse blank runs left by removals (keep elm-format's 2 blank lines)
    text2 = "\n".join(lines)
    text2 = re.sub(r"\n{4,}", "\n\n\n", text2)
    return text2, changed


def main():
    check = "--check" in sys.argv
    touched = []
    for f in sorted(VENDOR.rglob("*.elm")):
        new, changed = prune_text(f.read_text())
        if not changed:
            continue
        if not check:
            f.write_text(new)
        touched.append(str(f.relative_to(VENDOR)))
    print("\n".join(touched) if touched else "(nothing to prune)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
