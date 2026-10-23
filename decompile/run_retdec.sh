#!/usr/bin/env bash
# Run RetDec on each stripped binary. RetDec decompiles the whole binary in one
# pass to $OUT/decomp/retdec/<name>.c; retdec_export.py then turns that file into
# the common per-function CSV used by score.py.
#
# Usage: decompile/run_retdec.sh [program ...]     (default: all built programs)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/out}
RETDEC_HOME=${RETDEC_HOME:-/opt/retdec}
TIMEOUT=${RETDEC_TIMEOUT:-7200}    # seconds per binary (RetDec has no per-function limit)
DEST=$OUT/decomp/retdec
mkdir -p "$DEST" "$OUT/logs"

want=("$@")
tail -n +2 "$ROOT/programs.csv" | while IFS=, read -r name _; do
    if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $name " ]]; then continue; fi
    bin=$OUT/bin/$name.stripped
    if [ ! -f "$bin" ]; then echo "[retdec] $name: no binary, skipping"; continue; fi
    echo "[retdec] $name"
    rm -f "$DEST/$name".*
    "$RETDEC_HOME/bin/retdec-decompiler" "$bin" -o "$DEST/$name.c" \
        --timeout "$TIMEOUT" --cleanup -s > "$OUT/logs/retdec_$name.log" 2>&1 \
        || echo "[retdec] $name FAILED (see out/logs/retdec_$name.log)"
    python3 "$ROOT/decompile/retdec_export.py" "$bin" "$DEST/$name.c" "$DEST/$name.csv"
done
