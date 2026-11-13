#!/bin/bash
# Build the Strata Duo engine (strata_ds4 with the TLS link) from a fresh checkout. No Homebrew, no sudo.
#
#   duo/build.sh [OUT_DIR]          TLS build into OUT_DIR (default: build-duo in the checkout)
#   duo/build.sh --testhooks OUT_DIR  the TLS build with the slot tests' fault injection compiled in (tests only)
#   duo/build.sh --plain [OUT_DIR]  upstream's default build (no TLS: --duo-certs is refused; default OUT_DIR build-duo-plain)
#   duo/build.sh --deps-only        fetch and build the dependencies, then stop
#
# What it does, in order:
#   1. checks the Xcode Command Line Tools (clang++, /usr/bin/python3)
#   2. cmake and ninja: the ones on PATH, else pinned versions from pip into a Python venv it creates
#   3. Apple's metal-cpp headers (zip, SHA-256 pinned) and llama.cpp at the pinned commit -> third_party/
#   4. OpenSSL 3, static, into a local prefix (tarball SHA-256 pinned); or STRATA_DUO_OPENSSL_ROOT=<prefix> to use yours
#   5. cmake + ninja, target strata_ds4
#
# Build into a new OUT_DIR while a pair is running: the script refuses to overwrite a strata_ds4 that a process is
# executing. Then point BUILD in duo.conf at the new directory and run `duo.sh restart`.
#
# Environment: STRATA_DUO_DEPS (default <checkout>/.duo-deps: the venv, the OpenSSL sources and prefix),
#   STRATA_DUO_OPENSSL_ROOT (an existing static OpenSSL 3 prefix: include/openssl/ssl.h, lib/libssl.a, lib/libcrypto.a),
#   JOBS (parallel compile jobs for OpenSSL; default: all cores).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
TP="$ROOT/third_party"
DEPS=${STRATA_DUO_DEPS:-"$ROOT/.duo-deps"}
VENV="$DEPS/venv"

# Pinned dependencies (the versions the measured engine was built with).
LLAMA_COMMIT=3cf03257f219afbe7334045ff7c6a06ac68c627d
METAL_CPP_ZIP=metal-cpp_26.zip
METAL_CPP_URL=https://developer.apple.com/metal/cpp/files/$METAL_CPP_ZIP
METAL_CPP_SHA=4df3c078b9aadcb516212e9cb03004cbc5ce9a3e9c068fa3144d021db585a3a4
OPENSSL_V=openssl-3.5.9
OPENSSL_URL=https://github.com/openssl/openssl/releases/download/$OPENSSL_V/$OPENSSL_V.tar.gz
OPENSSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a   # the release's published .tar.gz.sha256
CMAKE_PIN=4.4.3
NINJA_PIN=1.13.2

TLS=1; DEPS_ONLY=0; HOOKS=0; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plain) TLS=0 ;;
    --deps-only) DEPS_ONLY=1 ;;
    --testhooks) HOOKS=1 ;;   # (fault injection for duo/tests/slots_test.py: never a build to serve with)
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "build.sh: unknown option $1" >&2; exit 2 ;;
    *) [ -z "$OUT" ] || { echo "build.sh: one output directory only" >&2; exit 2; }; OUT=$1 ;;
  esac
  shift
done
if [ -z "$OUT" ]; then [ "$TLS" = 1 ] && OUT=build-duo || OUT=build-duo-plain; fi
case "$OUT" in /*) ;; *) OUT="$ROOT/$OUT" ;; esac

say() { printf '== %s\n' "$*"; }
die() { printf 'build.sh: %s\n' "$*" >&2; exit 1; }

# ---- 1. the platform and the compiler
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || die "this builds on an Apple Silicon Mac only (found $(uname -s) $(uname -m))"
xcode-select -p >/dev/null 2>&1 || die "the Xcode Command Line Tools are missing: run  xcode-select --install"
command -v clang++ >/dev/null || die "clang++ not found: run  xcode-select --install"
[ -x /usr/bin/python3 ] || die "/usr/bin/python3 not found: run  xcode-select --install"
case "$ROOT" in *[[:space:]]*) die "the checkout's path contains a space ($ROOT): CMake and OpenSSL's build do not handle that; clone into a path without spaces" ;; esac

# ---- a build must never replace a binary that is running
if [ "$DEPS_ONLY" = 0 ] && [ -x "$OUT/strata_ds4" ]; then
  target=$(cd "$OUT" && pwd -P)/strata_ds4
  for pid in $(pgrep -x strata_ds4 2>/dev/null || true); do
    exe=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    if [ "$exe" = "$target" ]; then
      die "$target is running (pid $pid): build into another directory, e.g.  duo/build.sh build-duo-next  (then set BUILD in duo.conf and run duo.sh restart)"
    fi
  done
fi

mkdir -p "$DEPS" "$TP"

# ---- 2. cmake and ninja
CMAKE=$(command -v cmake || true); NINJA=$(command -v ninja || true)
if [ -z "$CMAKE" ] || [ -z "$NINJA" ]; then
  if [ ! -x "$VENV/bin/cmake" ] || [ ! -x "$VENV/bin/ninja" ]; then
    say "cmake/ninja not on PATH: installing cmake $CMAKE_PIN and ninja $NINJA_PIN into $VENV"
    [ -x "$VENV/bin/python" ] || /usr/bin/python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip -q install --disable-pip-version-check "cmake==$CMAKE_PIN" "ninja==$NINJA_PIN"
  fi
  CMAKE="$VENV/bin/cmake"; NINJA="$VENV/bin/ninja"
  export PATH="$VENV/bin:$PATH"
fi
say "tools: $("$CMAKE" --version | head -1), ninja $("$NINJA" --version), $(clang++ --version | head -1)"

# ---- 3. metal-cpp and llama.cpp (ggml)
fetch() {   # URL FILE: download with resume into FILE
  curl -fsSL --retry 3 -C - -o "$2.part" "$1" && mv "$2.part" "$2"
}
if [ ! -f "$TP/metal-cpp/Metal/Metal.hpp" ]; then
  say "fetching Apple's metal-cpp headers"
  [ -f "$TP/$METAL_CPP_ZIP" ] || fetch "$METAL_CPP_URL" "$TP/$METAL_CPP_ZIP"
  echo "$METAL_CPP_SHA  $TP/$METAL_CPP_ZIP" | shasum -a 256 -c - || die "$METAL_CPP_ZIP does not have the pinned SHA-256: delete it and run again"
  rm -rf "$TP/_metal_cpp"; mkdir "$TP/_metal_cpp"; unzip -q "$TP/$METAL_CPP_ZIP" -d "$TP/_metal_cpp"
  rm -rf "$TP/metal-cpp"; mv "$TP/_metal_cpp/metal-cpp" "$TP/metal-cpp"; rm -rf "$TP/_metal_cpp"
fi
if [ ! -f "$TP/llama.cpp/ggml/CMakeLists.txt" ]; then
  say "fetching llama.cpp at $LLAMA_COMMIT"
  [ -f "$TP/llama.zip" ] || fetch "https://github.com/ggml-org/llama.cpp/archive/$LLAMA_COMMIT.zip" "$TP/llama.zip"
  rm -rf "$TP/_unpack"; mkdir "$TP/_unpack"; unzip -q "$TP/llama.zip" -d "$TP/_unpack"
  [ -f "$TP/_unpack/llama.cpp-$LLAMA_COMMIT/ggml/CMakeLists.txt" ] || die "llama.zip is not the pinned commit's archive: delete $TP/llama.zip and run again"
  rm -rf "$TP/llama.cpp"; mv "$TP/_unpack/llama.cpp-$LLAMA_COMMIT" "$TP/llama.cpp"; rm -rf "$TP/_unpack"
fi

# ---- 4. OpenSSL 3 (static): macOS ships LibreSSL without headers, so it is built here
SSL=""
if [ "$TLS" = 1 ]; then
  ssl_ok() { [ -f "$1/include/openssl/ssl.h" ] && [ -f "$1/lib/libssl.a" ] && [ -f "$1/lib/libcrypto.a" ]; }
  if [ -n "${STRATA_DUO_OPENSSL_ROOT:-}" ]; then
    ssl_ok "$STRATA_DUO_OPENSSL_ROOT" || die "STRATA_DUO_OPENSSL_ROOT=$STRATA_DUO_OPENSSL_ROOT has no include/openssl/ssl.h, lib/libssl.a and lib/libcrypto.a"
    SSL=$STRATA_DUO_OPENSSL_ROOT
  else
    SSL="$DEPS/openssl"
    if ! ssl_ok "$SSL" || [ ! -x "$SSL/bin/openssl" ]; then
      case "$DEPS" in *[[:space:]]*) die "STRATA_DUO_DEPS contains a space ($DEPS): OpenSSL's build does not handle that" ;; esac
      say "building $OPENSSL_V (static) into $SSL"
      mkdir -p "$DEPS/src"
      [ -f "$DEPS/src/$OPENSSL_V.tar.gz" ] || fetch "$OPENSSL_URL" "$DEPS/src/$OPENSSL_V.tar.gz"
      echo "$OPENSSL_SHA  $DEPS/src/$OPENSSL_V.tar.gz" | shasum -a 256 -c - || die "$OPENSSL_V.tar.gz does not have the published SHA-256: delete it and run again"
      rm -rf "$DEPS/src/$OPENSSL_V"; tar xzf "$DEPS/src/$OPENSSL_V.tar.gz" -C "$DEPS/src"
      ( cd "$DEPS/src/$OPENSSL_V"
        ./Configure darwin64-arm64-cc no-shared no-tests no-docs --prefix="$SSL" --openssldir="$SSL/ssl" > ../configure.log 2>&1 || { tail -20 ../configure.log; exit 1; }
        make -j"${JOBS:-$(sysctl -n hw.ncpu)}" > ../make.log 2>&1 || { tail -30 ../make.log; exit 1; }
        make install_sw > ../install.log 2>&1 || { tail -20 ../install.log; exit 1; } )
    fi
  fi
  say "OpenSSL: $("$SSL/bin/openssl" version 2>/dev/null || echo "(no openssl program in $SSL/bin; libraries only)") in $SSL"
fi
if [ "$DEPS_ONLY" = 1 ]; then say "dependencies ready"; exit 0; fi

# ---- 5. the engine
mkdir -p "$OUT"
ARGS=(-S "$ROOT/metal" -B "$OUT" -G Ninja -DCMAKE_BUILD_TYPE=Release "-DCMAKE_MAKE_PROGRAM=$NINJA"
      "-DMETAL_CPP_DIR=$TP/metal-cpp" "-DSTRATA_GGML_DIR=$TP/llama.cpp")
if [ "$TLS" = 1 ]; then ARGS+=(-DSTRATA_DUO_TLS=ON "-DSTRATA_DUO_OPENSSL_ROOT=$SSL"); else ARGS+=(-DSTRATA_DUO_TLS=OFF); fi
if [ "$HOOKS" = 1 ]; then ARGS+=(-DSTRATA_DUO_TESTHOOKS=ON); else ARGS+=(-DSTRATA_DUO_TESTHOOKS=OFF); fi
say "configuring $OUT"
"$CMAKE" "${ARGS[@]}" > "$OUT/duo-cmake.log" 2>&1 || { tail -25 "$OUT/duo-cmake.log"; die "cmake failed (full log: $OUT/duo-cmake.log)"; }
grep -E "Strata Duo" "$OUT/duo-cmake.log" || echo "-- Strata Duo: TLS link OFF (plain build)"
say "compiling strata_ds4"
"$NINJA" -C "$OUT" strata_ds4 > "$OUT/duo-build.log" 2>&1 || { grep -E "error|FAILED" "$OUT/duo-build.log" | head -30; die "the build failed (full log: $OUT/duo-build.log)"; }
[ -x "$OUT/strata_ds4" ] || die "no strata_ds4 in $OUT after the build (log: $OUT/duo-build.log)"
ls -l "$OUT/strata_ds4"
"$OUT/strata_ds4" --version
say "done: $OUT/strata_ds4 ($([ "$TLS" = 1 ] && echo "TLS link" || echo "plain link only"))"
