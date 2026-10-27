# decompiler-bakeoff

CPT_S 428, Track C: Decompiler Bake-Off.
Team: Shane Ganz, Josiah Norton, Nathan Teh, Emily West.

Compiles 10 open-source C programs with **gcc 13.3.0 at `-O2 -g`**, strips them, runs
three decompilers on the stripped binaries, and scores each decompiler against the ground
truth of the unstripped build of the same pinned source.

## Run it

```bash
git clone https://github.com/emilywest1/decompiler-bakeoff
cd decompiler-bakeoff
docker build -t bakeoff .
mkdir -p out results
docker run --rm -v "$PWD/out:/bakeoff/out" -v "$PWD/results:/bakeoff/results" bakeoff
```

The output for each pair of de-compilers and programs is stored in `results/results.csv`  and
`results/disagreements.csv`.

To run only some programs, use `docker run ... bakeoff ./run_all.sh zlib lua`.

## Packages

- Ubuntu 24.04
- gcc 13.3.0
- OpenJDK 21
- Ghidra 12.1.3
- angr 10.0.5
- RetDec v5.0
- pyelftools 0.32
- libsdl2-mixer-dev

## Programs

See `programs.csv`

| Program | Ref | Commit | Binary analysed | What it is |
|---|---|---|---|---|
| linenoise | master | a473823d | linenoise-example | line-editing library (used by redis, MongoDB) |
| inih | r62 | 26254ee9 | ini_dump | INI file parser |
| tree | 2.3.2 | 1a41b51b | tree | Unix `tree` command |
| zlib | v1.3.2 | da607da7 | minigzip (static libz) | compression |
| cJSON | v1.7.19 | c859b25d | cJSON_test | JSON parser |
| xxHash | v0.8.4 | c87183a7 | xxhsum | non-cryptographic hashing |
| md4c | v0.6.0 | 7fc1815a | md2html | Markdown parser (used by Qt) |
| libdeflate | v1.26 | 92e6a0db | libdeflate-gzip | fast gzip/deflate |
| lz4 | v1.10.0 | ebb370ca | lz4 | compression (Linux kernel, ZFS) |
| Lua | master | 7579fc9d | lua | scripting language interpreter |

The D1 plan also included curl, John the Ripper, redis, Chocolate Doom, SQLite, Valkey,
OpenSSH and nginx. We replaced them with smaller programs because full decompilation of
those binaries took several hours per tool (redis, valkey and john each have about 7,000
functions). The replacements keep a mix of program types and a range of sizes, from tiny
(inih, linenoise) to small (lz4, Lua).

## Decompilers

| Tool | How it runs | Notes |
|---|---|---|
| Ghidra 12.1.3 | `analyzeHeadless` + `ExportDecomp.java` | per-function timeout `DECOMP_TIMEOUT` (default 60 s) |
| angr 10.0.5 | Python API (`CFGFast` + `Decompiler`) | per-function timeout `DECOMP_TIMEOUT`; slowest of the three on large binaries |
| RetDec v5.0 | `retdec-decompiler` CLI, whole binary at once | whole-binary timeout `RETDEC_TIMEOUT` (default 7200 s); unmaintained since 2022 |

Our D1 plan used IDA free and Binary Ninja 6.0, but our current Docker implementation required us to change decompilers.
IDA didn't work with Docker because it needed idalib, which only comes with IDA pro. Binary Ninja similarly needs paid license.
We chose to use retdec and angr as our second and third decompilers instead.

All three tools write the same per-function format to `out/decomp/<tool>/<program>.csv`:
`entry_offset,name,param_count,decompiled_ok,c_lines`. `entry_offset` is relative to the image
base, so the tools' different load addresses do not matter. If a tool fails on a whole
program, its row shows `status=tool_failed` with zeros, so the harness still produces all 30 rows.


## Layout

```
Dockerfile               pinned environment (gcc 13.3.0, Ghidra 12.1.3, RetDec v5.0, JDK 21, Python)
run_all.sh               build -> Ghidra -> angr -> RetDec -> score
programs.csv             name, repo, commit, binary
build/build_all.sh       clone at commit, compile -O2 -g, strip, record SHA-256
decompile/run_ghidra.sh  Ghidra analyzeHeadless + ghidra_scripts/ExportDecomp.java
decompile/run_angr.py    angr Decompiler analysis, one function at a time
decompile/run_retdec.sh  retdec-decompiler on the whole binary + retdec_export.py
measure/score.py         ground truth from DWARF, writes results/*.csv
```

## Metrics

**Ground truth.** A `.text` function symbol in the
unstripped binary that has a DWARF `DW_TAG_subprogram` at the same address. That means
it was compiled from the program's own source. GCC clones (`.isra`, `.constprop`,
`.cold`) are excluded. Its true arity is the number of DWARF formal parameters.
Variadic functions are excluded from arity scoring.

`results/results.csv` has one row per (program, tool):

| column | meaning |
|---|---|
| `gt_functions` | ground-truth functions |
| `found` | GT functions whose entry the tool also identified as a function |
| `decompiled` | of those, decompiled without error/timeout |
| `recall` | `found / gt_functions` |
| `arity_accuracy` | decompiled functions whose recovered parameter count equals the source's |
| `status` | `ok`, `tool_failed` (decompiler produced no output) or `no_binary` (build failed) |

**Hits (D1 rule).** A hit is a function that two decompilers both decompiled but whose
recovered signatures disagree. `results/disagreements.csv` counts hits per (program, tool
pair) and uses the source ground truth to say which tool was right. This connects the
D1 "hit" definition to the source-code ground truth.


```bash
(cd out/bin && sha256sum *.stripped) > checksums.txt
```

`build_all.sh` compares every later build against it and warns on any mismatch.
