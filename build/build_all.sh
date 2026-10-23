#!/usr/bin/env bash
# Clone every program in programs.csv at its pinned commit and compile it with
# gcc 13.3.0, -O2 -g. For each program this produces:
#   $OUT/bin/<name>           unstripped binary (ground truth: symbols + DWARF)
#   $OUT/bin/<name>.stripped  stripped copy (what the decompilers are given)
# and appends a row to $OUT/build_status.csv.
#
# Usage: build/build_all.sh [program ...]     (default: all programs)
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$ROOT/out}
WORK=${WORK:-$ROOT/work}
JOBS=${JOBS:-$(nproc)}
mkdir -p "$OUT/bin" "$OUT/logs" "$WORK"

# Refuse to build outside the pinned environment (scope stated in D1)
if [ "$(gcc -dumpfullversion 2>/dev/null)" != "13.3.0" ]; then
    echo "[build] ERROR: gcc $(gcc -dumpfullversion 2>/dev/null) found, gcc 13.3.0 required." >&2
    echo "[build] Run the harness inside the Docker image (see README)." >&2
    exit 1
fi

# Programs compiled with the same compiler and optimizations
export CC=gcc CXX=g++
export CFLAGS="-O2 -g"
export CXXFLAGS="-O2 -g"
export LDFLAGS=""

# Pull program repository version & commit
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



# Single-file projects are compiled directly so they get exactly $CFLAGS
# (their own Makefiles would use -Os / extra flags).
build_linenoise() { gcc $CFLAGS -o linenoise-example linenoise.c example.c && cp linenoise-example "$1"; }

build_inih()   { gcc $CFLAGS -o ini_dump ini.c examples/ini_dump.c && cp ini_dump "$1"; }

build_tree()   { make -j"$JOBS" tree && cp tree "$1"; }    # Makefile uses CFLAGS from the environment

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

# lz4's Makefile prepends -O3; our -O2 comes later on the command line and wins.
build_lz4()    { make -j"$JOBS" -C programs lz4 && cp programs/lz4 "$1"; }

build_lua()    { make -j"$JOBS" CC=gcc CFLAGS="-Wall -O2 -g -DLUA_USE_LINUX -DLUA_COMPAT_5_3" MYLIBS="" && cp lua "$1"; }

STATUS=$OUT/build_status.csv
[ -f "$STATUS" ] || echo "name,commit,status,binary_sha256,stripped_sha256,size_bytes" > "$STATUS"

want=("$@")
tail -n +2 "$ROOT/programs.csv" | while IFS=, read -r name repo commit ref binary; do
    if [ ${#want[@]} -gt 0 ] && [[ ! " ${want[*]} " =~ " $name " ]]; then continue; fi
    log=$OUT/logs/build_$name.log
    echo "[build] $name @ ${commit:0:12} (log: ${log#$ROOT/})"
    sed -i "/^$name,/d" "$STATUS"
    if fetch "$name" "$repo" "$commit" >"$log" 2>&1 \
       && (cd "$WORK/$name" && "build_$name" "$OUT/bin/$name") >>"$log" 2>&1; then
        strip --strip-all -o "$OUT/bin/$name.stripped" "$OUT/bin/$name"
        sha=$(sha256sum "$OUT/bin/$name" | cut -d' ' -f1)
        ssha=$(sha256sum "$OUT/bin/$name.stripped" | cut -d' ' -f1)
        echo "$name,$commit,ok,$sha,$ssha,$(stat -c%s "$OUT/bin/$name.stripped")" >> "$STATUS"
        echo "        ok"
    else
        echo "$name,$commit,FAILED,,," >> "$STATUS"
        echo "        FAILED -- last lines of $log:"; tail -n 15 "$log" | sed 's/^/        | /'
    fi
done

# Compare against the reference checksums committed in the repo (informational:
# a mismatch means the binary differs from the one the team analysed).
if [ -f "$ROOT/checksums.txt" ]; then
    echo "[build] checking stripped binaries against checksums.txt"
    (cd "$OUT/bin" && sha256sum -c --ignore-missing "$ROOT/checksums.txt") || \
        echo "[build] WARNING: some binaries differ from checksums.txt"
fi
