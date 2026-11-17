#!/usr/bin/env bash
# Run Ghidra headless on each stripped binary, at each optimisation level in
# $OPT_LEVELS (default: O0 O2 Os), and export one row per function to
#   $OUT/decomp/ghidra/<name>-<opt>.csv   (entry_offset,name,param_count,decompiled_ok,c_lines)
#   $OUT/decomp/ghidra/<name>-<opt>.c     (all decompiled C, for later manual review)
#
# Usage: decompile/run_ghidra.sh [program ...]     (default: all built programs)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/out}
GHIDRA_HOME=${GHIDRA_HOME:-/opt/ghidra}
TIMEOUT=${DECOMP_TIMEOUT:-60}      # seconds per function
read -r -a OPTS <<< "${OPT_LEVELS:-O0 O2 Os}"
DEST=$OUT/decomp/ghidra
mkdir -p "$DEST" "$OUT/logs"

want=("$@")
tail -n +2 "$ROOT/programs.csv" | while IFS=, read -r name _; do
    if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $name " ]]; then continue; fi
    for opt in "${OPTS[@]}"; do
        tag=$name-$opt
        bin=$OUT/bin/$tag.stripped
        if [ ! -f "$bin" ]; then echo "[ghidra] $tag: no binary, skipping"; continue; fi
        echo "[ghidra] $tag"
        rm -f "$DEST/$tag.csv" "$DEST/$tag.c"     # a failed run must not leave stale results
        proj=$(mktemp -d)
        "$GHIDRA_HOME/support/analyzeHeadless" "$proj" bakeoff \
            -import "$bin" -overwrite \
            -scriptPath "$ROOT/decompile/ghidra_scripts" \
            -postScript ExportDecomp.java "$DEST/$tag.csv" "$DEST/$tag.c" "$TIMEOUT" \
            -deleteProject > "$OUT/logs/ghidra_$tag.log" 2>&1 \
            || echo "[ghidra] $tag FAILED (see out/logs/ghidra_$tag.log)"
        rm -rf "$proj"
        # Ghidra's launcher writes files with mode 640; make them readable outside Docker.
        chmod 644 "$DEST/$tag.csv" "$DEST/$tag.c" 2>/dev/null
    done
done
