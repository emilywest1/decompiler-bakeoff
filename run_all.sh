#!/usr/bin/env bash
# The one command the grader runs (inside the Docker image):
#   1. build all programs at their pinned commits
#   2. run Ghidra, angr and RetDec on every stripped binary
#   3. score every (program, decompiler) pair -> results/results.csv
export DECOMP_TIMEOUT=${DECOMP_TIMEOUT:-10}
set -euo pipefail
cd "$(dirname "$0")"

build/build_all.sh "$@"
decompile/run_ghidra.sh "$@"
python3 decompile/run_angr.py "$@"
decompile/run_retdec.sh "$@"
python3 measure/score.py
echo "[done] results in results/results.csv and results/disagreements.csv"
