#!/usr/bin/env bash
# Run Ghidra headless on each stripped binary and export one row per function to
#   $OUT/decomp/ghidra/<name>.csv   (entry_offset,name,param_count,decompiled_ok,c_lines)
#   $OUT/decomp/ghidra/<name>.c     (all decompiled C, for later manual review)
#
# Usage: decompile/run_ghidra.sh [program ...]     (default: all built programs)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/out}
GHIDRA_HOME=${GHIDRA_HOME:-/opt/ghidra}
TIMEOUT=${DECOMP_TIMEOUT:-60}      # seconds per function
DEST=$OUT/decomp/ghidra
mkdir -p "$DEST" "$OUT/logs"

want=("$@")
tail -n +2 "$ROOT/programs.csv" | while IFS=, read -r name _; do
    if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $name " ]]; then continue; fi
    bin=$OUT/bin/$name.stripped
    if [ ! -f "$bin" ]; then echo "[ghidra] $name: no binary, skipping"; continue; fi
    echo "[ghidra] $name"
    proj=$(mktemp -d)
    "$GHIDRA_HOME/support/analyzeHeadless" "$proj" bakeoff \
        -import "$bin" -overwrite \
        -scriptPath "$ROOT/decompile/ghidra_scripts" \
        -postScript ExportDecomp.java "$DEST/$name.csv" "$DEST/$name.c" "$TIMEOUT" \
        -deleteProject > "$OUT/logs/ghidra_$name.log" 2>&1 \
        || echo "[ghidra] $name FAILED (see out/logs/ghidra_$name.log)"
    rm -rf "$proj"
done
