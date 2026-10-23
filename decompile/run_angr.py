"""Run the angr decompiler on each stripped binary and export one row per function to
  $OUT/decomp/angr/<name>.csv   (entry_offset,name,param_count,decompiled_ok,c_lines)
  $OUT/decomp/angr/<name>.c     (all decompiled C, for later manual review)

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
DEST = os.path.join(OUT, "decomp", "angr")

logging.getLogger("angr").setLevel(logging.ERROR)


class Timeout(Exception):
    pass


def _alarm(signum, frame):
    raise Timeout()


def decompile(path, csv_path, c_path):
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
            except Exception:          # includes Timeout: the function counts as not decompiled
                pass
            finally:
                signal.alarm(0)
            out.write(f"0x{f.addr - base:x},{f.name},{params},{ok},{lines}\n")


def main():
    os.makedirs(DEST, exist_ok=True)
    with open(os.path.join(ROOT, "programs.csv")) as f:
        programs = [r["name"] for r in csv.DictReader(f)]
    for name in sys.argv[1:] or programs:
        binary = os.path.join(OUT, "bin", f"{name}.stripped")
        if not os.path.isfile(binary):
            print(f"[angr] {name}: no binary, skipping", flush=True)
            continue
        print(f"[angr] {name}", flush=True)
        try:
            decompile(binary, os.path.join(DEST, f"{name}.csv"), os.path.join(DEST, f"{name}.c"))
        except Exception as e:
            print(f"[angr] {name} FAILED: {e!r}", flush=True)


if __name__ == "__main__":
    main()
