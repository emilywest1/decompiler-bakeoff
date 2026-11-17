#!/usr/bin/env bash
# Run RetDec on each stripped binary, at each optimisation level in $OPT_LEVELS
# (default: O0 O2 Os). RetDec decompiles the whole binary in one pass to
# $OUT/decomp/retdec/<name>-<opt>.c; retdec_export.py then turns that file into
# the common per-function CSV <name>-<opt>.csv used by score.py.
#
# Usage: decompile/run_retdec.sh [program ...]     (default: all built programs)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/out}
RETDEC_HOME=${RETDEC_HOME:-/opt/retdec}
TIMEOUT=${RETDEC_TIMEOUT:-7200}    # seconds per binary (RetDec has no per-function limit)
read -r -a OPTS <<< "${OPT_LEVELS:-O0 O2 Os}"
DEST=$OUT/decomp/retdec
mkdir -p "$DEST" "$OUT/logs"

want=("$@")
tail -n +2 "$ROOT/programs.csv" | while IFS=, read -r name _; do
    if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $name " ]]; then continue; fi
    for opt in "${OPTS[@]}"; do
        tag=$name-$opt
        bin=$OUT/bin/$tag.stripped
        if [ ! -f "$bin" ]; then echo "[retdec] $tag: no binary, skipping"; continue; fi
        echo "[retdec] $tag"
        rm -f "$DEST/$tag".*
        "$RETDEC_HOME/bin/retdec-decompiler" "$bin" -o "$DEST/$tag.c" \
            --timeout "$TIMEOUT" --cleanup -s > "$OUT/logs/retdec_$tag.log" 2>&1 \
            || echo "[retdec] $tag FAILED (see out/logs/retdec_$tag.log)"
        python3 "$ROOT/decompile/retdec_export.py" "$bin" "$DEST/$tag.c" "$DEST/$tag.csv"
    done
done
