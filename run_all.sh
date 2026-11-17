#!/usr/bin/env bash
#   1. build all programs at their pinned commits, at -O0, -O2 and -Os (override with OPT_LEVELS)
#   2. run Ghidra, angr and RetDec on every stripped binary
#   3. score every (program, opt level, decompiler) -> results/results.csv, results/summary.csv
export DECOMP_TIMEOUT=${DECOMP_TIMEOUT:-60}   # seconds per function (Ghidra, angr)
set -euo pipefail
cd "$(dirname "$0")"

build/build_all.sh "$@"
decompile/run_ghidra.sh "$@"
python3 decompile/run_angr.py "$@"
decompile/run_retdec.sh "$@"
python3 measure/score.py
echo "[done] results in results/results.csv and results/summary.csv"
