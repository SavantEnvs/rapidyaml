# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile for rapidyaml (ryml) — C++ libFuzzer harnesses over
# upstream's own test/test_fuzz/*.cpp, plus a real gtest oracle.
#
# WHY the extra ext/ layer below (SPEC §6.2 items 8/9, §6.5 air-gap):
#   rapidyaml's OWN vendored c4core (ext/c4core.src, ext/c4core.dev) needs
#   NOTHING extra — it is plain files in the repo, not a submodule, so the
#   sanitized fuzz-library build below is already network-free.
#   The ORACLE build is a different story: rapidyaml's CMake test setup
#   (`c4_setup_testing(GTEST)` + `ext/testbm.cmake`) fetches THREE small
#   companion repos at CMake-CONFIGURE time via `ExternalProject`/git clone —
#   googletest, and biojppm/c4fs + biojppm/c4log (the latter two each carry
#   their OWN git submodule on a *different* c4core copy, which is never
#   actually built — only two source files are lifted out of each repo).
#   `c4Project.cmake`'s `_c4_find_cached_proj()` looks for a pre-populated
#   directory at `$C4_EXTERN_DIR/<name>` BEFORE attempting any clone, so we
#   pre-clone all three, once, HERE (this is the online build-time layer —
#   the content then rides into the image like any other file) at a fixed,
#   $HOME-independent path, and export C4_EXTERN_DIR so both the first
#   (online) build AND the air-gapped PATCH re-run resolve them from disk
#   with zero network I/O.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# Pin the oracle-only companion repos by COMMIT (c4fs/c4log; upstream's own
# CMake pins them to the *moving* `master` branch, which we don't want) and
# googletest by its released tag. None of these touch the fuzz build.
ARG GTEST_TAG=v1.17.0
ARG C4FS_COMMIT=d9ddb0dd1f19a1c34124817ad3757f2eab810ab0
ARG C4LOG_COMMIT=23e9bdba1edca287042b45d6ae6c8ea0fb1ad211

ENV C4_EXTERN_DIR=/opt/toolchains/cpp/extern

USER root
RUN install -d -m 0755 "$C4_EXTERN_DIR" \
 && git clone --quiet --depth 1 --branch "$GTEST_TAG" \
      https://github.com/google/googletest.git "$C4_EXTERN_DIR/gtest-1.17.0" \
 && git clone --quiet https://github.com/biojppm/c4fs "$C4_EXTERN_DIR/c4fs" \
 && git -C "$C4_EXTERN_DIR/c4fs" checkout --quiet "$C4FS_COMMIT" \
 && git clone --quiet https://github.com/biojppm/c4log "$C4_EXTERN_DIR/c4log" \
 && git -C "$C4_EXTERN_DIR/c4log" checkout --quiet "$C4LOG_COMMIT" \
 && chown -R 2000:2000 "$C4_EXTERN_DIR"

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
