#!/usr/bin/env bash
# Clone every program in programs.csv at its pinned commit and compile it with
# gcc 13.3.0 at each optimisation level in $OPT_LEVELS (default: O0 O2 Os), always
# with -g. For each program and level <opt> this produces:
#   $OUT/bin/<name>-<opt>           unstripped binary (ground truth: symbols + DWARF)
#   $OUT/bin/<name>-<opt>.stripped  stripped copy (what the decompilers are given)
# and a row in $OUT/build_status.csv.
#
# -g does not change the generated code, so the stripped copy is exactly what a
# release build at that level would be. After each build the DWARF producer strings
# are checked to confirm every compilation unit really used the requested -O level
# (a project's own Makefile could otherwise silently override it).
#
# Usage: build/build_all.sh [program ...]     (default: all programs)
#        OPT_LEVELS="O0" build/build_all.sh lua
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/out}
WORK=${WORK:-$ROOT/work}
JOBS=${JOBS:-$(nproc)}
read -r -a OPTS <<< "${OPT_LEVELS:-O0 O2 Os}"
mkdir -p "$OUT/bin" "$OUT/logs" "$WORK"

# Refuse to build outside the pinned environment (scope stated in D1)
if [ "$(gcc -dumpfullversion 2>/dev/null)" != "13.3.0" ]; then
    echo "[build] ERROR: gcc $(gcc -dumpfullversion 2>/dev/null) found, gcc 13.3.0 required." >&2
    echo "[build] Run the harness inside the Docker image (see README)." >&2
    exit 1
fi

export CC=gcc CXX=g++
export LDFLAGS=""

# Pull program repository version & commit (a reused checkout is reset to pristine,
# so every optimisation level starts from a clean tree).
fetch() {
    local dir=$WORK/$1
    if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD)" = "$3" ]; then
        git -C "$dir" clean -fdxq && git -C "$dir" checkout -q -- .
        return
    fi
    rm -rf "$dir" && mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" fetch -q --depth 1 "$2" "$3"
    git -C "$dir" checkout -q FETCH_HEAD
}

# Each build_<name> runs inside the checkout with CFLAGS="-<opt> -g" exported and
# copies the finished binary to $1. How each project is made to honour CFLAGS:
#   linenoise, inih, cjson  compiled directly with $CFLAGS (their Makefiles use their own flags)
#   tree, xxhash            Makefile uses CFLAGS ?= ..., so the environment value wins
#   zlib                    ./configure only defaults to -O3 when CFLAGS is unset
#   md4c, libdeflate        CMAKE_BUILD_TYPE=None, so no Release -O2 is appended
#   lz4                     Makefile prepends -O3; our level comes later and gcc uses the last -O
#   lua                     makefile hard-codes -O2, so CFLAGS is overridden on the command line
build_linenoise() { gcc $CFLAGS -o linenoise-example linenoise.c example.c && cp linenoise-example "$1"; }

build_inih()   { gcc $CFLAGS -o ini_dump ini.c examples/ini_dump.c && cp ini_dump "$1"; }

build_tree()   { make -j"$JOBS" tree && cp tree "$1"; }

build_zlib()   { ./configure --static && make -j"$JOBS" minigzip && cp minigzip "$1"; }

build_cjson()  { gcc $CFLAGS -o cJSON_test cJSON.c test.c -lm && cp cJSON_test "$1"; }

# DISPATCH=0: one generic code path instead of separate AVX2/AVX-512 copies.
build_xxhash() { make -j"$JOBS" xxhsum DISPATCH=0 && cp xxhsum "$1"; }

build_md4c() {
    cmake -S . -B b -DCMAKE_BUILD_TYPE=None -DCMAKE_C_FLAGS="$CFLAGS" -DBUILD_SHARED_LIBS=OFF \
    && cmake --build b -j"$JOBS" --target md2html && cp b/md2html/md2html "$1"
}

build_libdeflate() {
    cmake -S . -B b -DCMAKE_BUILD_TYPE=None -DCMAKE_C_FLAGS="$CFLAGS" \
        -DLIBDEFLATE_BUILD_SHARED_LIB=OFF -DLIBDEFLATE_USE_SHARED_LIB=OFF \
    && cmake --build b -j"$JOBS" --target libdeflate-gzip && cp b/programs/libdeflate-gzip "$1"
}

build_lz4()    { make -j"$JOBS" -C programs lz4 && cp programs/lz4 "$1"; }

build_lua()    { make -j"$JOBS" CC=gcc CFLAGS="-Wall $CFLAGS -DLUA_USE_LINUX -DLUA_COMPAT_5_3" MYLIBS="" && cp lua "$1"; }

# Print "ok" if every C compilation unit's last -O flag is -$2, otherwise the
# offending flags. gcc records its command-line switches in DW_AT_producer.
check_opt() {
    local seen
    seen=$(readelf --debug-dump=info "$1" 2>/dev/null | grep 'DW_AT_producer' | grep 'GNU C' \
           | while read -r line; do
                 tr ' ' '\n' <<< "$line" | grep -E '^-O[0-9sgz]?$' | tail -n 1
             done | sort -u | tr '\n' ' ')
    seen=${seen% }
    if [ "$seen" = "-$2" ]; then echo ok; else echo "mismatch(${seen:-none})"; fi
}

STATUS=$OUT/build_status.csv
HEADER="name,opt_level,commit,status,opt_check,binary_sha256,stripped_sha256,size_bytes"
# Start a new status file if it is missing or has the old (pre-opt-level) header.
[ -f "$STATUS" ] && [ "$(head -n 1 "$STATUS")" = "$HEADER" ] || echo "$HEADER" > "$STATUS"

want=("$@")
tail -n +2 "$ROOT/programs.csv" | while IFS=, read -r name repo commit ref binary; do
    if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $name " ]]; then continue; fi
    for opt in "${OPTS[@]}"; do
        export CFLAGS="-$opt -g" CXXFLAGS="-$opt -g"
        out=$OUT/bin/$name-$opt
        log=$OUT/logs/build_$name-$opt.log
        echo "[build] $name -$opt @ ${commit:0:12} (log: ${log#$ROOT/})"
        sed -i "/^$name,$opt,/d" "$STATUS"
        if fetch "$name" "$repo" "$commit" >"$log" 2>&1 \
           && (cd "$WORK/$name" && "build_$name" "$out") >>"$log" 2>&1; then
            strip --strip-all -o "$out.stripped" "$out"
            chk=$(check_opt "$out" "$opt")
            sha=$(sha256sum "$out" | cut -d' ' -f1)
            ssha=$(sha256sum "$out.stripped" | cut -d' ' -f1)
            echo "$name,$opt,$commit,ok,$chk,$sha,$ssha,$(stat -c%s "$out.stripped")" >> "$STATUS"
            if [ "$chk" = ok ]; then echo "        ok"
            else echo "        ok, but WARNING: optimisation flags $chk, expected -$opt"; fi
        else
            echo "$name,$opt,$commit,FAILED,,,," >> "$STATUS"
            echo "        FAILED -- last lines of $log:"; tail -n 15 "$log" | sed 's/^/        | /'
        fi
    done
done

# Compare against the reference checksums committed in the repo (informational:
# a mismatch means the binary differs from the one the team analysed).
if [ -f "$ROOT/checksums.txt" ]; then
    echo "[build] checking stripped binaries against checksums.txt"
    (cd "$OUT/bin" && sha256sum -c --ignore-missing "$ROOT/checksums.txt") || \
        echo "[build] WARNING: some binaries differ from checksums.txt"
fi
