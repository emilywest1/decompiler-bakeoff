"""Run the angr decompiler on each stripped binary, at each optimisation level in
$OPT_LEVELS (default: O0 O2 Os), and export one row per function to
  $OUT/decomp/angr/<name>-<opt>.csv   (entry_offset,name,param_count,decompiled_ok,c_lines)
  $OUT/decomp/angr/<name>-<opt>.c     (all decompiled C, for later manual review)

Usage: python3 decompile/run_angr.py [program ...]     (default: all built programs)
"""
import csv
import logging
import os
import signal
import sys

import angr

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
    proj = angr.Project(path, auto_load_libs=False)
    cfg = proj.analyses.CFGFast(normalize=True, data_references=True)
    base = proj.loader.main_object.min_addr
    signal.signal(signal.SIGALRM, _alarm)
    preset = 0

    with open(csv_path, "w") as out, open(c_path, "w") as src:
        out.write("entry_offset,name,param_count,decompiled_ok,c_lines\n")
        for f in sorted(cfg.kb.functions.values(), key=lambda f: f.addr):
            if f.is_plt or f.is_simprocedure or f.is_alignment or f.binary is not proj.loader.main_object:
                continue
            params, ok, lines = -1, 0, 0
            # Decompiling earlier functions in this loop can leave a 0-argument prototype
            # on later ones, and the Decompiler then reuses it instead of recovering the
            # signature (lua: all 921 functions came out as (void)). Decompiled on its own
            # straight after CFGFast, the same function gets the right arity. Reset to that
            # state so every function's signature comes from its own analysis.
            if f.prototype is not None:
                preset += 1
            # (is_prototype_guessed is a read-only property in angr 10.0.5, so it is not set here.)
            f.prototype, f.calling_convention = None, None
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
    print(f"[angr]   {preset} functions already had a prototype from earlier decompilations (reset)",
          flush=True)


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
            try:
                decompile(binary, csv_path, c_path)
            except Exception as e:
                # Remove the partial CSV so score.py reports tool_failed, not a truncated run.
                print(f"[angr] {tag} FAILED: {e!r}", flush=True)
                for p in (csv_path, c_path):
                    if os.path.exists(p):
                        os.remove(p)


if __name__ == "__main__":
    main()
