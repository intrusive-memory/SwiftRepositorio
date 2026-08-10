#!/usr/bin/env bash
#
# versions.sh — the single source of truth for every pinned upstream version.
#
# Sourced by build-xcframework.sh and verify-no-spawn.sh. Nothing else in this
# package may hard-code a version number; bump it here and nowhere else.
#
# Pinning strategy, per project, using the strongest pin that project offers:
#
#   libgit2 — git tag PLUS the exact commit SHA the tag resolves to. GitHub's
#     AUTO-GENERATED source archives are not byte-stable over time (git-archive
#     output has changed across git versions), so a checksum over one of those
#     would be a pin that rots. A commit SHA cannot rot: the build clones the tag
#     and then asserts `git rev-parse HEAD` equals the SHA below.
#
#   libssh2 / OpenSSL — the official RELEASE TARBALL plus its sha256. Those are
#     uploaded release assets rather than generated archives, so they are
#     immutable and a checksum over them is the strongest pin available. Tag and
#     commit are recorded as provenance only.
#
# shellcheck shell=bash
# shellcheck disable=SC2034  # every value here is consumed by the scripts that source this file

# ---------------------------------------------------------------------------
# Recipe revision
#
# Bump whenever the *recipe* changes — a configure flag, a patch, a header
# layout — even when no upstream version moves. Each slice's install prefix is
# stamped with this, so a build/ tree left over from an older recipe is rebuilt
# instead of reused. Reusing an install produced by an unknown recipe is exactly
# the bug class this guards against.
#
#   1  initial
#   2  libssh2 switched from git tag to release tarball (the tag carries a
#      "1.11.1_DEV" version string); hermetic find_library paths; host-path
#      assertion
# ---------------------------------------------------------------------------
RECIPE_REVISION="2"

# ---------------------------------------------------------------------------
# libgit2 — GPLv2 with a linking exception
# ---------------------------------------------------------------------------
LIBGIT2_VERSION="1.9.6"
LIBGIT2_REPO="https://github.com/libgit2/libgit2.git"
LIBGIT2_TAG="v1.9.6"
# `git rev-parse v1.9.6^{commit}` — verified 2026-08-10 via the GitHub API.
LIBGIT2_COMMIT="26055f5af74ab1cf636d272e8a34315496d3f06f"

# ---------------------------------------------------------------------------
# libssh2 — BSD-3-Clause
#
# The floor is 1.11.0, NOT 1.9/1.10. RFC 8332 rsa-sha2-256/512 signing merged
# on 2022-01-06 (libssh2 PR #626); 1.10.0 shipped 2021-08-29, i.e. BEFORE that
# merge. GitHub has refused SHA-1 ssh-rsa signatures since 2022, so a 1.10
# build fails to authenticate an RSA key with an error that looks like a bad
# key rather than a bad algorithm. 1.11.1 (2024-10-16) is the current release.
#
# THE TARBALL, NOT THE TAG — and this one is not a style preference.
#
# libssh2 tags the release commit BEFORE stripping the in-development suffix
# from the header. At tag `libssh2-1.11.1` (commit a312b43…, confirmed by
# `git describe`), `include/libssh2.h` reads:
#
#     #define LIBSSH2_VERSION      "1.11.1_DEV"
#     #define LIBSSH2_VERSION_NUM  0x010b01
#
# The numeric macro is right; the string is not. libssh2's CMake parses that
# string, so a tag-based build produces `Version: 1.11.1_DEV` in libssh2.pc and
# — the part that actually matters — makes `libssh2_version()` return
# "1.11.1_DEV" at runtime. Sortie 1b's exit criterion is a runtime assertion
# that the LINKED libssh2 is >= 1.11.0, and that assertion must not need to
# special-case a suffix.
#
# The release tarball (their `maketgz` rewrites the header) carries a clean
# "1.11.1", and it also ships the complete CMake build. Patching the version
# string in a tag-based tree was the alternative and was rejected: editing a
# library's self-reported version is precisely how a build starts lying about
# itself, which is the failure mode this whole package is built to avoid.
# ---------------------------------------------------------------------------
LIBSSH2_VERSION="1.11.1"
LIBSSH2_TARBALL_URL="https://github.com/libssh2/libssh2/releases/download/libssh2-1.11.1/libssh2-1.11.1.tar.gz"
# libssh2 publishes no .sha256 asset — only a detached .asc. This checksum was
# computed on 2026-08-10 from the official GitHub release asset, whose signature
# (libssh2-1.11.1.tar.gz.asc, made 2024-10-16) is by RSA key
# 27EDEAF22F3ABCEB50DB9A125CC908FDB71E12C2 — the libssh2/curl release key. The
# asset is an uploaded file, not a generated archive, so it is immutable.
LIBSSH2_TARBALL_SHA256="d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7"
# Provenance only — the build uses the tarball above, not git.
LIBSSH2_REPO="https://github.com/libssh2/libssh2.git"
LIBSSH2_TAG="libssh2-1.11.1"
LIBSSH2_COMMIT="a312b43325e3383c865a87bb1d26cb52e3292641"
# Hard floor asserted by the build and by the runtime test in Sortie 1b.
LIBSSH2_MINIMUM_VERSION="1.11.0"

# ---------------------------------------------------------------------------
# OpenSSL 3.x — Apache-2.0
#
# 3.5.x is the current LTS line, which is the right trade for a dependency
# whose CVE treadmill this package now owns.
# ---------------------------------------------------------------------------
OPENSSL_VERSION="3.5.7"
OPENSSL_TARBALL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
# From the release's own openssl-3.5.7.tar.gz.sha256 asset. Verified 2026-08-10.
OPENSSL_TARBALL_SHA256="a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8"
# Provenance only — the build uses the tarball above, not git.
OPENSSL_TAG="openssl-3.5.7"
OPENSSL_COMMIT="8cf17aaeb4599f8af87fefd810b5b5fee90fe69e"

# ---------------------------------------------------------------------------
# Apple deployment floors — must match Package.swift's `platforms:`
# ---------------------------------------------------------------------------
MACOS_DEPLOYMENT_TARGET="26.0"
IOS_DEPLOYMENT_TARGET="26.0"

# ---------------------------------------------------------------------------
# Product identity
# ---------------------------------------------------------------------------
XCFRAMEWORK_NAME="Clibgit2"
# The single merged static archive inside each slice: libgit2 + libssh2 +
# libssl + libcrypto, in that order.
MERGED_LIBRARY_NAME="libClibgit2.a"
