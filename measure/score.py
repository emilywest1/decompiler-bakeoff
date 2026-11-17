"""Score every (program, optimisation level, decompiler) against source-level ground truth.

Ground truth comes from the UNSTRIPPED binary built from the pinned source:
  - a ground-truth function is a FUNC symbol in .text that has a DWARF
    DW_TAG_subprogram at the same address (i.e. compiled from the program's own
    source, not CRT glue). GCC clones (foo.isra.0, foo.cold, ...) are excluded.
  - its true arity is the number of DW_TAG_formal_parameter children in DWARF
    (None for variadic functions).
The decompilers only ever see the STRIPPED copy. Functions are matched by entry
offset from the image base, which strip does not change.

HIT RULE (each tool vs. the source, never tool vs. tool):
  A ground-truth function is a hit for a tool if the tool
    (1) identifies a function at the same entry offset,
    (2) decompiles it without error or timeout, and
    (3) recovers the same parameter count as the source.
  Check (3) is skipped for variadic functions.
  accuracy = hits / ground-truth functions
Every miss is attributed to exactly one cause: not_found, decomp_failed or wrong_arity.

File layout per optimisation level <opt> in OPT_LEVELS (O0, O2, Os):
  out/bin/<prog>-<opt>                     unstripped binary (ground truth)
  out/decomp/<tool>/<prog>-<opt>.csv       tool output for <prog>-<opt>.stripped
Only these exact paths are read: results from the old -O2-only layout
(out/bin/<prog>, out/decomp/<tool>/<prog>.csv) are ignored, so a failed build can
never be silently replaced by stale data.

Outputs:
  results/results.csv   one row per (program, opt_level, tool)        -- detail
  results/summary.csv   one row per (tool, opt_level), all programs    -- headline
"""
import csv
import os
import sys

from elftools.elf.elffile import ELFFile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get("OUT", os.path.join(ROOT, "out"))
RESULTS = os.environ.get("RESULTS", os.path.join(ROOT, "results"))
TOOLS = ["ghidra", "angr", "retdec"]
OPT_LEVELS = os.environ.get("OPT_LEVELS", "O0 O2 Os").split()


def ground_truth(path):
    """Return {entry_offset: (name, arity or None)} for source-level functions."""
    with open(path, "rb") as f:
        elf = ELFFile(f)
        base = min(s["p_vaddr"] for s in elf.iter_segments() if s["p_type"] == "PT_LOAD")
        text = elf.get_section_by_name(".text")
        lo, hi = text["sh_addr"], text["sh_addr"] + text["sh_size"]

        syms = {}
        for s in elf.get_section_by_name(".symtab").iter_symbols():
            if (s["st_info"]["type"] == "STT_FUNC" and s["st_size"] > 0
                    and lo <= s["st_value"] < hi and "." not in s.name):
                syms[s["st_value"]] = s.name

        arity = {}
        if elf.has_dwarf_info():
            dwarf = elf.get_dwarf_info()
            for cu in dwarf.iter_CUs():
                for die in cu.iter_DIEs():
                    if die.tag != "DW_TAG_subprogram" or "DW_AT_low_pc" not in die.attributes:
                        continue
                    kids = [c.tag for c in die.iter_children()]
                    variadic = "DW_TAG_unspecified_parameters" in kids
                    n = kids.count("DW_TAG_formal_parameter")
                    arity[die.attributes["DW_AT_low_pc"].value] = None if variadic else n

    return {addr - base: (name, arity[addr]) for addr, name in syms.items() if addr in arity}


def binary_path(prog, opt):
    p = os.path.join(OUT, "bin", f"{prog}-{opt}")
    return p if os.path.isfile(p) else None


def load_tool(tool, prog, opt):
    """Per-function rows for one tool, or (None, None) if the tool produced no output."""
    p = os.path.join(OUT, "decomp", tool, f"{prog}-{opt}.csv")
    if not os.path.isfile(p):
        return None, None
    with open(p) as f:
        return {int(r["entry_offset"], 16): r for r in csv.DictReader(f)}, p


def score(gt, funcs):
    """Apply the hit rule to one tool's output for one binary."""
    c = dict.fromkeys(["found", "decompiled", "arity_evaluable", "arity_correct",
                       "hits", "not_found", "decomp_failed", "wrong_arity"], 0)
    for off, (_, true_arity) in gt.items():
        r = funcs.get(off)
        if r is None:
            c["not_found"] += 1
            continue
        c["found"] += 1
        if r["decompiled_ok"] != "1":
            c["decomp_failed"] += 1
            continue
        c["decompiled"] += 1
        if true_arity is None:                      # variadic: check (3) skipped
            c["hits"] += 1
            continue
        c["arity_evaluable"] += 1
        if int(r["param_count"]) == true_arity:
            c["arity_correct"] += 1
            c["hits"] += 1
        else:
            c["wrong_arity"] += 1
    return c


def ratio(a, b):
    return round(a / b, 4) if b else 0.0


def main():
    os.makedirs(RESULTS, exist_ok=True)
    with open(os.path.join(ROOT, "programs.csv")) as f:
        programs = [r["name"] for r in csv.DictReader(f)]

    counts = ["found", "decompiled", "arity_evaluable", "arity_correct",
              "hits", "not_found", "decomp_failed", "wrong_arity"]
    rows = []
    for opt in OPT_LEVELS:
        for prog in programs:
            binary = binary_path(prog, opt)
            gt = ground_truth(binary) if binary else {}
            for tool in TOOLS:
                funcs, src = load_tool(tool, prog, opt)
                row = {"program": prog, "opt_level": opt, "tool": tool,
                       "gt_functions": len(gt), **dict.fromkeys(counts, 0)}
                if not gt:
                    row["status"] = "no_binary"
                elif funcs is None:
                    # Tool produced nothing: every source function is a miss.
                    row["status"] = "tool_failed"
                    row["not_found"] = len(gt)
                else:
                    row["status"] = "ok"
                    row.update(score(gt, funcs))
                row["recall"] = ratio(row["found"], len(gt))
                row["arity_accuracy"] = ratio(row["arity_correct"], row["arity_evaluable"])
                row["accuracy"] = ratio(row["hits"], len(gt))
                row["source"] = os.path.relpath(src, ROOT) if src else ""
                rows.append(row)

    # Headline: pool all programs per (tool, opt). Programs that were not built at this
    # level are left out; programs where the tool failed count as all misses.
    summary = []
    for tool in TOOLS:
        for opt in OPT_LEVELS:
            rs = [r for r in rows if r["tool"] == tool and r["opt_level"] == opt
                  and r["status"] != "no_binary"]
            gt_total = sum(r["gt_functions"] for r in rs)
            s = {"tool": tool, "opt_level": opt, "programs_scored": len(rs),
                 "tools_failed": sum(r["status"] == "tool_failed" for r in rs),
                 "gt_functions": gt_total}
            for k in ("hits", "not_found", "decomp_failed", "wrong_arity"):
                s[k] = sum(r[k] for r in rs)
            # Blank (not 0.0) when nothing was built at this level, so it can't be misread.
            s["accuracy"] = ratio(s["hits"], gt_total) if rs else ""
            # Unweighted mean over programs, so the largest program does not dominate.
            s["mean_program_accuracy"] = (round(sum(r["accuracy"] for r in rs) / len(rs), 4)
                                          if rs else "")
            summary.append(s)

    for name, data in (("results.csv", rows), ("summary.csv", summary)):
        with open(os.path.join(RESULTS, name), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(data[0]))
            w.writeheader()
            w.writerows(data)

    print(f"[score] wrote {len(rows)} rows to results.csv, {len(summary)} rows to summary.csv")
    print("[score] accuracy (hits / source functions), all programs pooled:")
    print("        " + "tool".ljust(8) + "".join(f"-{o}".rjust(10) for o in OPT_LEVELS))
    for tool in TOOLS:
        cells = []
        for opt in OPT_LEVELS:
            s = next(x for x in summary if x["tool"] == tool and x["opt_level"] == opt)
            cells.append(f"{s['accuracy']:.1%}" if s["programs_scored"] else "n/a")
        print("        " + tool.ljust(8) + "".join(c.rjust(10) for c in cells))


if __name__ == "__main__":
    sys.exit(main())
