"""Run the angr decompiler on each stripped binary, at each optimisation level in
$OPT_LEVELS (default: O0 O2 Os), and export one row per function to
  $OUT/decomp/angr/<name>-<opt>.csv   (entry_offset,name,param_count,decompiled_ok,c_lines)
  $OUT/decomp/angr/<name>-<opt>.c     (all decompiled C, for later manual review)

Each binary is decompiled in its own Python process, so no angr state can carry over
from one binary to the next. (Every bad angr result we saw -- lz4 and lua, with nearly
all signatures recovered as (void) -- was on a binary decompiled after others in the
same process, while the same functions decompiled correctly in a fresh process.)

Usage: python3 decompile/run_angr.py [program ...]     (default: all built programs)
       python3 decompile/run_angr.py --one <binary> <out.csv> <out.c>   (internal)
"""
import csv
import logging
import os
import signal
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get("OUT", os.path.join(ROOT, "out"))
TIMEOUT = int(os.environ.get("DECOMP_TIMEOUT", "60"))   # seconds per function
OPT_LEVELS = os.environ.get("OPT_LEVELS", "O0 O2 Os").split()
DEST = os.path.join(OUT, "decomp", "angr")

logging.getLogger("angr").setLevel(logging.ERROR)


class Timeout(BaseException):
    # BaseException, not Exception: angr catches Exception internally in places,
    # which would swallow the alarm and let a "timed out" function carry on.
    pass


def _alarm(signum, frame):
    raise Timeout()


def decompile(path, csv_path, c_path):
    import angr      # imported only in the per-binary child process
    proj = angr.Project(path, auto_load_libs=False)
    cfg = proj.analyses.CFGFast(normalize=True, data_references=True)
    base = proj.loader.main_object.min_addr
    signal.signal(signal.SIGALRM, _alarm)

    with open(csv_path, "w") as out, open(c_path, "w") as src:
        out.write("entry_offset,name,param_count,decompiled_ok,c_lines\n")
        for f in sorted(cfg.kb.functions.values(), key=lambda f: f.addr):
            if f.is_plt or f.is_simprocedure or f.is_alignment or f.binary is not proj.loader.main_object:
                continue
            params, ok, lines = -1, 0, 0
            signal.alarm(TIMEOUT)
            try:
                dec = proj.analyses.Decompiler(f, cfg=cfg.model)
                if dec.codegen is not None and dec.codegen.text:
                    params = len(dec.codegen.cfunc.arg_list or [])
                    ok, lines = 1, dec.codegen.text.count("\n") + 1
                    src.write(f"// ==== 0x{f.addr - base:x} {f.name} ====\n{dec.codegen.text}\n")
            except (Exception, Timeout):   # error or timeout: the function counts as not decompiled
                pass
            finally:
                signal.alarm(0)
            out.write(f"0x{f.addr - base:x},{f.name},{params},{ok},{lines}\n")


def main():
    os.makedirs(DEST, exist_ok=True)
    with open(os.path.join(ROOT, "programs.csv")) as f:
        programs = [r["name"] for r in csv.DictReader(f)]
    for name in sys.argv[1:] or programs:
        for opt in OPT_LEVELS:
            tag = f"{name}-{opt}"
            binary = os.path.join(OUT, "bin", f"{tag}.stripped")
            if not os.path.isfile(binary):
                print(f"[angr] {tag}: no binary, skipping", flush=True)
                continue
            print(f"[angr] {tag}", flush=True)
            csv_path, c_path = os.path.join(DEST, f"{tag}.csv"), os.path.join(DEST, f"{tag}.c")
            rc = subprocess.run([sys.executable, os.path.abspath(__file__), "--one",
                                 binary, csv_path, c_path]).returncode
            if rc != 0:
                # Remove the partial CSV so score.py reports tool_failed, not a truncated run.
                print(f"[angr] {tag} FAILED (exit code {rc})", flush=True)
                for p in (csv_path, c_path):
                    if os.path.exists(p):
                        os.remove(p)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--one"]:
        decompile(*sys.argv[2:5])
    else:
        main()
