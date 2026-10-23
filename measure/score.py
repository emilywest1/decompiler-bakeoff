"""Score every (program, decompiler) pair against source-level ground truth.

Ground truth comes from the UNSTRIPPED binary built from the pinned source:
  - a ground-truth function is a FUNC symbol in .text that has a DWARF
    DW_TAG_subprogram at the same address (i.e. compiled from the program's own
    source, not CRT glue). GCC clones (foo.isra.0, foo.cold, ...) are excluded.
  - its true arity is the number of DW_TAG_formal_parameter children in DWARF.
The decompilers only ever see the STRIPPED copy. Functions are matched by entry
offset from the image base, which strip does not change.

Outputs:
  results/results.csv        one row per (program, tool)            -- primary metric
  results/disagreements.csv  one row per (program, tool pair)       -- D1 "hit" count
"""
import csv
import itertools
import os
import sys

from elftools.elf.elffile import ELFFile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get("OUT", os.path.join(ROOT, "out"))
RESULTS = os.path.join(ROOT, "results")
TOOLS = ["ghidra", "angr", "retdec"]


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


def load_tool(tool, prog):
    """Per-function rows from out/decomp/<tool>/<prog>.csv, or (None, None) if the tool produced none."""
    p = os.path.join(OUT, "decomp", tool, f"{prog}.csv")
    if not os.path.isfile(p):
        return None, None
    with open(p) as f:
        return {int(r["entry_offset"], 16): r for r in csv.DictReader(f)}, p


def main():
    os.makedirs(RESULTS, exist_ok=True)
    with open(os.path.join(ROOT, "programs.csv")) as f:
        programs = [r["name"] for r in csv.DictReader(f)]

    rows, dis_rows = [], []
    for prog in programs:
        binary = os.path.join(OUT, "bin", prog)
        gt = ground_truth(binary) if os.path.isfile(binary) else {}
        outputs = {}
        for tool in TOOLS:
            funcs, src = load_tool(tool, prog)
            outputs[tool] = funcs
            row = {"program": prog, "tool": tool, "gt_functions": len(gt),
                   "found": 0, "decompiled": 0, "arity_evaluable": 0, "arity_correct": 0,
                   "recall": 0.0, "arity_accuracy": 0.0,
                   "status": "no_binary" if not gt else ("tool_failed" if funcs is None else "ok"),
                   "source": os.path.relpath(src, ROOT) if src else ""}
            if gt and funcs is not None:
                for off, (_, true_arity) in gt.items():
                    r = funcs.get(off)
                    if r is None:
                        continue
                    row["found"] += 1
                    if r["decompiled_ok"] == "1":
                        row["decompiled"] += 1
                        if true_arity is not None:
                            row["arity_evaluable"] += 1
                            row["arity_correct"] += int(r["param_count"]) == true_arity
                row["recall"] = round(row["found"] / len(gt), 4)
                if row["arity_evaluable"]:
                    row["arity_accuracy"] = round(row["arity_correct"] / row["arity_evaluable"], 4)
            rows.append(row)

        # D1 "hit": both tools decompiled the function but disagree on its arity.
        # The ground truth then says which tool (if either) was right.
        for a, b in itertools.combinations(TOOLS, 2):
            fa, fb = outputs[a], outputs[b]
            d = {"program": prog, "tool_a": a, "tool_b": b, "compared": 0,
                 "hits": 0, "a_correct": 0, "b_correct": 0, "neither_correct": 0}
            if gt and fa is not None and fb is not None:
                for off, (_, true_arity) in gt.items():
                    ra, rb = fa.get(off), fb.get(off)
                    if not (ra and rb and ra["decompiled_ok"] == rb["decompiled_ok"] == "1"):
                        continue
                    d["compared"] += 1
                    pa, pb = int(ra["param_count"]), int(rb["param_count"])
                    if pa != pb:
                        d["hits"] += 1
                        if true_arity == pa:
                            d["a_correct"] += 1
                        elif true_arity == pb:
                            d["b_correct"] += 1
                        else:
                            d["neither_correct"] += 1
            dis_rows.append(d)

    for name, data in (("results.csv", rows), ("disagreements.csv", dis_rows)):
        with open(os.path.join(RESULTS, name), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(data[0]))
            w.writeheader()
            w.writerows(data)
    print(f"[score] wrote {len(rows)} rows to results/results.csv, "
          f"{len(dis_rows)} rows to results/disagreements.csv")


if __name__ == "__main__":
    sys.exit(main())
