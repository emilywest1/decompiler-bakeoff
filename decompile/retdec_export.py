"""Convert RetDec's whole-program C output into the common per-function CSV.

RetDec precedes every function it emits with a comment of the form
    // Address range: 0x1234 - 0x1280
followed by the function definition. We take the entry address from that comment
and count parameters in the definition's signature.

Usage: retdec_export.py <binary> <retdec_output.c> <out.csv>
"""
import re
import sys

from elftools.elf.elffile import ELFFile

ADDR = re.compile(r"^// Address range: (0x[0-9a-fA-F]+) - ")
DEF = re.compile(r"^[A-Za-z_][\w\s\*]*?\b(\w+)\((.*)\)\s*\{\s*$")


def param_count(arglist):
    arglist = arglist.strip()
    if arglist in ("", "void"):
        return 0
    return len([a for a in arglist.split(",") if a.strip() != "..."])


def main(binary, c_path, csv_path):
    with open(binary, "rb") as f:
        elf = ELFFile(f)
        base = min(s["p_vaddr"] for s in elf.iter_segments() if s["p_type"] == "PT_LOAD")

    rows = []
    try:
        with open(c_path, errors="replace") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:     # RetDec failed or timed out: write an empty table
        lines = []

    i = 0
    while i < len(lines):
        m = ADDR.match(lines[i])
        if m and i + 1 < len(lines) and (d := DEF.match(lines[i + 1])):
            start = i + 1
            end = start
            while end < len(lines) and lines[end] != "}":
                end += 1
            rows.append((int(m.group(1), 16) - base, d.group(1), param_count(d.group(2)), end - start + 1))
            i = end
        i += 1

    with open(csv_path, "w") as out:
        out.write("entry_offset,name,param_count,decompiled_ok,c_lines\n")
        for off, name, params, n in rows:
            out.write(f"0x{off:x},{name},{params},1,{n}\n")


if __name__ == "__main__":
    main(*sys.argv[1:4])
