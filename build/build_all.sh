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



build_zlib()   { ./configure --static && make -j"$JOBS" minigzip && cp minigzip "$1"; }

build_curl() {
    cmake -S . -B b -DCMAKE_BUILD_TYPE=None -DCMAKE_C_FLAGS="$CFLAGS" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON -DBUILD_CURL_EXE=ON \
        -DBUILD_TESTING=OFF -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF \
        -DCURL_USE_OPENSSL=ON -DCURL_ZLIB=ON -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF \
        -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF \
        -DCURL_DISABLE_LDAP=ON -DUSE_LIBRTMP=OFF \
    && cmake --build b -j"$JOBS" --target curl && cp b/src/curl "$1"
}

build_john() {
    cd src && ./configure --disable-native-tests --disable-openmp --disable-opencl \
    && make -sj"$JOBS" && cp ../run/john "$1"
}

build_redis()  { make -j"$JOBS" MALLOC=libc BUILD_TLS=no OPTIMIZATION=-O2 CFLAGS="-g" redis-server && cp src/redis-server "$1"; }
build_valkey() { make -j"$JOBS" MALLOC=libc BUILD_TLS=no OPTIMIZATION=-O2 CFLAGS="-g" valkey-server && cp src/valkey-server "$1"; }

build_chocolate-doom() { autoreconf -fi && ./configure && make -j"$JOBS" && cp src/chocolate-doom "$1"; }

build_sqlite() { ./configure --disable-tcl && make -j"$JOBS" sqlite3 && cp sqlite3 "$1"; }

build_lua()    { make -j"$JOBS" CC=gcc CFLAGS="-Wall -O2 -g -DLUA_USE_LINUX -DLUA_COMPAT_5_3" MYLIBS="" && cp lua "$1"; }

build_openssh() { autoreconf -fi && ./configure --without-zlib-version-check && make -j"$JOBS" ssh && cp ssh "$1"; }

build_nginx()  { auto/configure --with-cc-opt="$CFLAGS" && make -j"$JOBS" && cp objs/nginx "$1"; }

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
