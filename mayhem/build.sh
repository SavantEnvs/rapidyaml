#!/usr/bin/env bash
#
# mayhem/build.sh — build rapidyaml's (ryml) fuzz harnesses + standalone
# reproducers, plus the real gtest oracle + a direct KAT probe used by
# mayhem/test.sh.
#
# Targets built (one Mayhemfile each), all straight from upstream's OWN
# fuzz sources at test/test_fuzz/ (unmodified — we only COMPILE them here,
# never edit them):
#   /mayhem/yaml_tree  — fuzztest_yaml_tree: parse_in_arena + resolve + emit  (test_fuzz_yaml_tree.cpp)
#   /mayhem/json_tree  — fuzztest_json_tree: parse_json_in_arena + emit      (test_fuzz_json_tree.cpp)
#   /mayhem/yaml_ints  — fuzztest_yaml_ints: low-level in-place ParseEngine<EventHandlerInts>
#                        event parser (test_fuzz_yaml_ints.cpp) — a different memory model
#                        (fixed arena, in-place mutation) than the Tree API above.
#   /mayhem/srlz       — fuzztest_serialize: scalar_deserialize/scalar_serialize round-trips
#                        over every arithmetic type + std::string (test_fuzz_srlz.cpp) — a
#                        wholly different code region (number parsing/formatting), no Tree at all.
# (test_fuzz_json_ints.cpp is intentionally NOT ported: it exercises the exact same
#  ParseEngine<EventHandlerInts> engine as yaml_ints, just with the JSON lexer path, so it adds
#  little beyond yaml_tree/json_tree/yaml_ints/srlz already covering tree+event+scalar surfaces.
#  test_fuzz_main.cpp is upstream's own non-libFuzzer directory-walking driver — reproducer
#  plumbing, not a Mayhem target; we use $LIB_FUZZING_ENGINE/$STANDALONE_FUZZ_MAIN instead, both
#  of which take bytes only from the fuzzer/argv file with no relative-path file I/O of their own.)
#
# SUBMODULES / AIR-GAP (SPEC §6.5): rapidyaml itself vendors c4core as plain files under
# ext/c4core.src + ext/c4core.dev (upstream removed the git-submodule form years ago — there is
# no .gitmodules in this repo), so the SANITIZED FUZZ build below needs no network at all, ever.
# The ORACLE build is what actually reaches the network at CMake-configure time (googletest,
# c4fs, c4log) — handled by pre-cloning those into $C4_EXTERN_DIR in mayhem/Dockerfile; see the
# comment there. This script only *consumes* that pre-populated cache (offline-safe by construction:
# $C4_EXTERN_DIR is a fixed path baked into the image, independent of $HOME).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# ─────────────────────────────────────────────────────────────────────────
# 1) Sanitized ryml+c4core library — instruments the LIBRARY, not just the
#    harness TU. `-fsanitize=fuzzer-no-link` is appended UNCONDITIONALLY
#    (even when $SANITIZER_FLAGS is empty) so SanCov coverage is always
#    present; without it the harness builds/fuzz-smokes fine locally but
#    records 0 edges in Mayhem because the fuzzed code has no coverage.
#    RYML_BUILD_TESTS/RYML_EXTRA_*/RYML_BUILD_TOOLS are all OFF here: they
#    are what pulls in the network-fetching ext/testbm.cmake (see the
#    oracle build below, which handles that via $C4_EXTERN_DIR instead).
# ─────────────────────────────────────────────────────────────────────────
FUZZ_BUILD_DIR="$SRC/mayhem-build/fuzz"
cmake -S "$SRC" -B "$FUZZ_BUILD_DIR" -G "Unix Makefiles" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link" \
  -DRYML_BUILD_TESTS=OFF -DRYML_BUILD_TOOLS=OFF -DRYML_BUILD_BENCHMARKS=OFF \
  -DRYML_EXTRA_INTS=OFF -DRYML_EXTRA_INTS_UTILS=OFF -DRYML_EXTRA_INTS_TESTSUITE=OFF -DRYML_EXTRA_ALL=OFF \
  -DRYML_INSTALL=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build "$FUZZ_BUILD_DIR" --target ryml -j"$MAYHEM_JOBS"
RYML_FUZZ_LIB="$FUZZ_BUILD_DIR/libryml.a"

# EventHandlerInts (src_extra) is needed only by the yaml_ints harness. It is
# NOT wired through the RYML_EXTRA_INTS CMake option on purpose (that option
# also drags in ext/testbm.cmake's c4fs/c4log network fetch, which the fuzz
# build has no business needing) — just compile the one .cpp directly with
# the same sanitized+coverage flags as the library.
INC="-I $SRC/src -I $SRC/ext/c4core.src -I $SRC/src_extra -I $SRC/test"
$CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $INC \
  -c "$SRC/src_extra/c4/yml/extra/event_handler_ints.cpp" \
  -o "$FUZZ_BUILD_DIR/event_handler_ints.o"

# $STANDALONE_FUZZ_MAIN is a C file; compile once as C (a C++ harness would
# otherwise mangle its LLVMFuzzerTestOneInput reference) and reuse per target.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD_DIR/standalone_main.o"

# build_harness <target-name> <upstream test_fuzz .cpp> [extra objs...]
build_harness() {
  local name="$1" src="$2"; shift 2
  local extra_objs=("$@")
  echo "=== building /mayhem/$name (fuzzer) ==="
  $CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS $INC $LIB_FUZZING_ENGINE \
      "$src" "${extra_objs[@]}" "$RYML_FUZZ_LIB" -o "/mayhem/$name"
  echo "=== building /mayhem/$name-standalone (reproducer) ==="
  $CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
      "$src" "${extra_objs[@]}" "$FUZZ_BUILD_DIR/standalone_main.o" "$RYML_FUZZ_LIB" \
      -o "/mayhem/$name-standalone"
}

build_harness yaml_tree "$SRC/test/test_fuzz/test_fuzz_yaml_tree.cpp"
build_harness json_tree "$SRC/test/test_fuzz/test_fuzz_json_tree.cpp"
build_harness srlz      "$SRC/test/test_fuzz/test_fuzz_srlz.cpp"
build_harness yaml_ints "$SRC/test/test_fuzz/test_fuzz_yaml_ints.cpp" "$FUZZ_BUILD_DIR/event_handler_ints.o"

# Ship the per-target libFuzzer dictionaries the Mayhemfiles reference —
# a referenced-but-absent dict makes libFuzzer exit 1 at 0 edges.
cp -f "$SRC/mayhem/yaml_tree/yaml_tree.dict" /mayhem/yaml_tree.dict
cp -f "$SRC/mayhem/json_tree/json_tree.dict" /mayhem/json_tree.dict
cp -f "$SRC/mayhem/yaml_ints/yaml_ints.dict" /mayhem/yaml_ints.dict

# ─────────────────────────────────────────────────────────────────────────
# 2) The ORACLE: a separate, CLEAN, NON-sanitized build of upstream's own
#    gtest suite (~60 binaries, ~9900 EXPECT_/ASSERT_ macros — see the
#    per-file group registration in test/CMakeLists.txt), built with the
#    project's NORMAL flags so it stays an honest functional oracle.
#    RYML_TEST_SUITE / RYML_FUZZ_TEST / RYML_FUZZ_DRIVERS are OFF: those
#    pull in yaml-test-suite / rapidyaml-data via a SEPARATE CMake-time git
#    clone (pinned to a literal date tag that moves every sync) that is
#    unrelated to c4fs/c4log/gtest and out of scope for our purpose — we
#    already get a large, real, upstream-authored assertion suite without it.
# ─────────────────────────────────────────────────────────────────────────
ORACLE_BUILD_DIR="$SRC/mayhem-build/oracle"
cmake -S "$SRC" -B "$ORACLE_BUILD_DIR" -G "Unix Makefiles" \
  -DCMAKE_CXX_COMPILER="$CXX" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_STANDARD=17 \
  -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" \
  -DRYML_BUILD_TESTS=ON \
  -DRYML_TEST_SUITE=OFF -DRYML_FUZZ_TEST=OFF -DRYML_FUZZ_DRIVERS=OFF \
  -DRYML_INSTALL=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build "$ORACLE_BUILD_DIR" -j"$MAYHEM_JOBS"

# ─────────────────────────────────────────────────────────────────────────
# 3) The direct KAT probe (mayhem/test.sh's anti-sabotage backstop — see the
#    header comment in mayhem/kat/kat.cpp). NORMAL flags, links against the
#    already-built CLEAN libryml.a from the oracle build above (no need to
#    recompile ryml a third time). Must be dynamically linked so the
#    verify-repo LD_PRELOAD sabotage shim can actually neuter it — assert
#    that so a toolchain change can't silently weaken the oracle.
# ─────────────────────────────────────────────────────────────────────────
$CXX -std=c++17 -O2 -I "$SRC/src" -I "$SRC/ext/c4core.src" \
    "$SRC/mayhem/kat/kat.cpp" "$ORACLE_BUILD_DIR/libryml.a" -o /mayhem/kat
if ! file /mayhem/kat | grep -q 'dynamically linked'; then
  echo "FATAL: /mayhem/kat is not dynamically linked — the sabotage check could not" >&2
  echo "       neuter it, which would make mayhem/test.sh a reward-hackable oracle." >&2
  file /mayhem/kat >&2
  exit 1
fi

echo "build.sh complete:"
ls -la /mayhem/yaml_tree /mayhem/json_tree /mayhem/yaml_ints /mayhem/srlz /mayhem/kat \
       /mayhem/yaml_tree-standalone /mayhem/json_tree-standalone /mayhem/yaml_ints-standalone /mayhem/srlz-standalone
