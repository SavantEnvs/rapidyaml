#!/usr/bin/env bash
#
# mayhem/test.sh — run rapidyaml's (ryml) own functional oracle, built by
# mayhem/build.sh with the project's NORMAL (non-sanitized) flags. Three
# independent legs, all unconditional (a missing binary/marker/value is a
# FAILURE, never a skip):
#
#   (A) ~77 gtest binaries under mayhem-build/oracle/test/ (the project's own
#       `test/test_*.cpp`), ~48,000 EXPECT_/ASSERT_ cases. Each is invoked
#       DIRECTLY (never through ctest) and we parse the gtest binary's OWN
#       "[==========] N tests from M test suites ran." / "[  PASSED  ] N
#       tests." summary text — NOT its exit code. This matters: `ctest`/
#       `meson test` judge purely by child exit code, and a binary that is
#       `_exit(0)`'d by the verify-repo sabotage shim before it prints a
#       single character LOOKS like a passing test to an exit-code-only
#       runner (proven empirically on pkgconf — 32/32 "OK" under sabotage).
#       Here, a neutered binary produces NO summary line at all, which we
#       treat as an unconditional FAIL for that binary — so sabotage cannot
#       hide behind gtest's own exit code either.
#   (B) 3 of the project's own deliberate-error unit binaries
#       (ryml-test-error-{basic,parse,visit}), each a known-answer test in
#       its own right: call the library with a fixed bad input (null tree /
#       malformed YAML / invalid node) and assert the EXACT resulting error
#       text upstream's own error formatter produces. Neutering the binary
#       means no text at all -> the grep fails.
#   (C) mayhem/kat/kat.cpp (see that file) — parses a fixed YAML document
#       and prints `KAT_<NAME>=<value>` lines for a scalar lookup, a
#       sequence length, an anchor/alias resolution, and a round-trip
#       emission. Run directly from bash (whitelisted by the sabotage shim)
#       and matched with `grep -qxF` against the exact expected line.
#
# Together (A)+(B)+(C) assert real computed VALUES through binaries the
# sabotage shim can neuter, not merely "the process exited 0" — the anti-
# reward-hacking property SPEC §6.3 requires. This script only RUNS things;
# mayhem/build.sh already built every binary referenced here.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

ORACLE_BUILD_DIR="$SRC/mayhem-build/oracle"
TESTDIR="$ORACLE_BUILD_DIR/test"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -d "$TESTDIR" ]; then
  echo "FATAL: $TESTDIR is missing — mayhem/build.sh should have built the oracle test suite" >&2
  emit_ctrf "ryml-oracle" 0 1
  exit $?
fi

total_all=0
passed_all=0
failed_all=0
nbins=0

# ── (A) the gtest suite — every ryml-test-* binary except the argv-driven
#    quickstart samples (not gtest binaries) and the error-* family (handled
#    separately in (B) below with their own known-answer text). ────────────
gtest_bins="$(cd "$TESTDIR" && find . -maxdepth 1 -type f -name 'ryml-test-*' -perm -u+x \
              | sed 's#^\./##' | grep -vE 'quickstart|^ryml-test-error-')"
if [ -z "$gtest_bins" ]; then
  echo "FATAL: no ryml-test-* gtest binaries found in $TESTDIR" >&2
  emit_ctrf "ryml-oracle" 0 1
  exit $?
fi
while IFS= read -r bin; do
  [ -n "$bin" ] || continue
  nbins=$((nbins + 1))
  out="$("$TESTDIR/$bin" 2>&1)"
  ran_line="$(printf '%s\n' "$out" | grep -E '^\[==========\] [0-9]+ tests? from [0-9]+ test suites? ran\.' | head -1)"
  if [ -z "$ran_line" ]; then
    echo "ORACLE FAIL: $bin produced no gtest completion marker (neutered, crashed, or hung?)" >&2
    failed_all=$((failed_all + 1))
    continue
  fi
  passed_line="$(printf '%s\n' "$out" | grep -E '^\[  PASSED  \] [0-9]+ tests?\.' | head -1)"
  total="$(printf '%s' "$ran_line" | grep -oE '[0-9]+' | head -1)"
  passed="$(printf '%s' "$passed_line" | grep -oE '[0-9]+' | head -1)"
  : "${total:=0}" "${passed:=0}"
  if [ "$total" -eq 0 ]; then
    echo "ORACLE FAIL: $bin ran 0 tests (empty suite is suspicious, treating as a failure)" >&2
    failed_all=$((failed_all + 1))
    continue
  fi
  failed=$((total - passed))
  total_all=$((total_all + total))
  passed_all=$((passed_all + passed))
  failed_all=$((failed_all + failed))
done <<<"$gtest_bins"
echo "gtest suite: $nbins binaries, $total_all cases, $passed_all passed, $((total_all - passed_all)) failed"

# ── (B) the 3 deliberate-error known-answer binaries: fixed bad input ->
#    upstream's own exact error text. ───────────────────────────────────────
check_error_bin() {
  local bin="$1" expect="$2"
  local out
  if [ ! -x "$TESTDIR/$bin" ]; then
    echo "ORACLE FAIL: $bin missing (should have been built)" >&2
    failed_all=$((failed_all + 1)); total_all=$((total_all + 1))
    return
  fi
  out="$("$TESTDIR/$bin" 2>&1 || true)"
  total_all=$((total_all + 1))
  if printf '%s\n' "$out" | grep -qF "$expect"; then
    passed_all=$((passed_all + 1))
  else
    echo "ORACLE FAIL: $bin did not print the expected error text: $expect" >&2
    failed_all=$((failed_all + 1))
  fi
}
check_error_bin ryml-test-error-basic "ERROR: [basic] null tree"
check_error_bin ryml-test-error-parse "ERROR: [parse]"
check_error_bin ryml-test-error-visit "ERROR: [visit] invalid node"

# ── (C) the direct KAT probe — exact computed values, matched with grep -qxF
#    (whole-line, fixed string) so sabotage cannot partially match. ────────
check_kat() {
  local line="$1"
  total_all=$((total_all + 1))
  if printf '%s\n' "$KAT_OUT" | grep -qxF "$line"; then
    passed_all=$((passed_all + 1))
  else
    echo "ORACLE FAIL: KAT probe did not print expected line: $line" >&2
    failed_all=$((failed_all + 1))
  fi
}
if [ ! -x /mayhem/kat ]; then
  echo "FATAL: /mayhem/kat is missing — mayhem/build.sh should have built it" >&2
  KAT_OUT=""
else
  KAT_OUT="$(/mayhem/kat 2>&1 || true)"
fi
check_kat 'KAT_SCALAR=hello world'
check_kat 'KAT_SEQLEN=3'
check_kat 'KAT_ALIAS=pinned-42'
check_kat 'KAT_EMIT=top: hello worldseq: [10,20,30]nested:  a: pinned-42  b: pinned-42  c: 7'

emit_ctrf "ryml-oracle(gtest+error-kat+direct-kat)" "$passed_all" "$failed_all"
