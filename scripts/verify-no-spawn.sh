#!/usr/bin/env bash
#
# verify-no-spawn.sh — prove the built library cannot shell out, and cannot
# trip Apple's non-public-symbol scanner.
#
# Wired as `make verify-no-spawn` (that Makefile target is Sortie 1b's task; the
# script is the contract and can be run directly today).
#
# Four independent assertions, each one a thing that has actually gone wrong in
# a shipping libgit2 build:
#
#   A. No process-spawn symbols. libgit2 1.8+ ships an SSH transport that
#      fork()s and execve()s /usr/bin/ssh. The iOS sandbox blocks fork at the
#      syscall and ships no ssh binary, so enabling it produces a library that
#      builds, links, and then fails silently at runtime — the worst available
#      failure mode. Note that upstream compiles src/util/unix/process.c
#      UNCONDITIONALLY (src/util/CMakeLists.txt globs unix/*.c), so a stock
#      build has these symbols in the archive whether or not the transport is
#      enabled. build-xcframework.sh guards that translation unit; --allow-
#      unreferenced-process relaxes this check to "present but provably dead"
#      for anyone building stock upstream.
#
#   B. No ucontext symbols. _getcontext/_makecontext/_setcontext come from
#      OpenSSL's crypto/async/arch/async_posix.c and are the documented cause of
#      ITMS-90338 "Non-public API usage" at upload validation (openssl#2545,
#      openssl#7318). `no-async` at configure time removes them. This assertion
#      is the only part of the ITMS-90338 story that can be checked locally; the
#      App Store Connect upload is the real proof.
#
#   C. The expected symbols ARE there. A build that silently lost SSH, or
#      linked a libssh2 without memory credentials, would sail through checks A
#      and B. Absence of the bad thing is not presence of the good thing.
#
#   D. The feature header says what we asked for. Cheap, and catches a typo'd
#      -D flag that CMake accepted and ignored.
#
# Usage:
#   scripts/verify-no-spawn.sh                        # verify artifacts/
#   scripts/verify-no-spawn.sh --allow-unreferenced-process
#   scripts/verify-no-spawn.sh path/to/libFoo.a ...   # verify explicit archives
#
# Exits 0 only if every assertion holds for every slice examined.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=scripts/versions.sh
source "${SCRIPT_DIR}/versions.sh"

XCFRAMEWORK="${PKG_ROOT}/artifacts/${XCFRAMEWORK_NAME}.xcframework"

ALLOW_UNREFERENCED_PROCESS=0
EXPLICIT_TARGETS=()
for arg in "$@"; do
	case "$arg" in
		--allow-unreferenced-process) ALLOW_UNREFERENCED_PROCESS=1 ;;
		-h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
		-*) echo "error: unknown flag '$arg'" >&2; exit 2 ;;
		*) EXPLICIT_TARGETS+=("$arg") ;;
	esac
done

FAILURES=0
CHECKED=0

red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
head1() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
item()  { printf '    %s\n' "$*"; }

fail() {
	red "    FAIL: $*"
	FAILURES=$((FAILURES + 1))
}

# --- A. forbidden process-spawn symbols -----------------------------------
# Matched against the symbol name only, anchored, so _forkpty or
# _posix_spawn_file_actions_init do not produce a false positive on a name we
# did not mean to ban. vfork and the exec* family are included because they are
# the same capability by another name.
SPAWN_SYMBOLS='^(_fork|_vfork|_execve|_execv|_execvp|_execvP|_execl|_execle|_execlp|_posix_spawn|_posix_spawnp)$'

# --- B. forbidden ucontext symbols (ITMS-90338) ---------------------------
UCONTEXT_SYMBOLS='^(_getcontext|_makecontext|_setcontext|_swapcontext)$'

# --- C. required symbols --------------------------------------------------
# libssh2_userauth_publickey_frommemory is the one that matters most: without
# it libgit2 sets no GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS and every private key
# must come off disk, which defeats keeping key material in the Keychain.
REQUIRED_SYMBOLS=(
	_git_libgit2_init
	_git_libgit2_features
	_git_libgit2_version
	_libssh2_init
	_libssh2_version
	_libssh2_userauth_publickey_frommemory
	_libssh2_session_hostkey
	_EVP_PKEY_new
	_SSL_CTX_new
)

# symbol_table <archive> -> "member<TAB>U|D<TAB>symbol" lines
#
# `nm -m` is the required tool here (it is what distinguishes an undefined
# reference from a definition unambiguously). Its lines look like:
#
#   0000000000000f10 (__TEXT,__text) external _git_libgit2_init
#   0000000000000000 (__TEXT,__text) private external _libssh2_init
#                    (undefined) external _fork
#
# so the symbol is always the field immediately after `external`. Parsing by
# $NF would break on the `(from libSystem)` suffix nm appends in some contexts.
# Archive members are announced on their own line, which we carry forward so a
# failure can name the object file that introduced the symbol. Two spellings
# exist in the wild: a bare `member.o:` and a qualified
# `path/to/lib.a(member.o):`; both are handled.
symbol_table() {
	local lib="$1"
	nm -m -arch all "${lib}" 2>/dev/null | awk '
		/^[^ \t].*\.o\)?:$/ {
			member = $0
			sub(/:$/, "", member)
			if (member ~ /\(/) {
				sub(/.*\(/, "", member)
				sub(/\)$/, "", member)
			}
			next
		}
		{
			sym = ""
			for (i = 1; i < NF; i++) {
				if ($i == "external") { sym = $(i + 1); break }
			}
			if (sym == "") next
			if ($0 ~ /\(undefined\)/) print member "\tU\t" sym
			else print member "\tD\t" sym
		}
	'
}

check_archive() {
	local label="$1" lib="$2"
	CHECKED=$((CHECKED + 1))

	head1 "${label}"
	item "$(lipo -info "${lib}" 2>&1 | sed 's/.*: //' | sed 's/^/arch: /')"

	local table
	table="$(symbol_table "${lib}")"
	if [ -z "${table}" ]; then
		fail "nm produced no symbols for ${lib} — not a static archive?"
		return
	fi

	# ---- A ----
	local spawn_hits
	spawn_hits="$(printf '%s\n' "${table}" | awk -F'\t' -v re="${SPAWN_SYMBOLS}" '$3 ~ re { print $1 "  " $2 "  " $3 }' | sort -u)"
	if [ -z "${spawn_hits}" ]; then
		green "    OK  A: no fork/exec/posix_spawn symbols"
	elif [ "${ALLOW_UNREFERENCED_PROCESS}" = "1" ]; then
		# Relaxed mode: tolerate them ONLY in libgit2's process translation unit,
		# and only while nothing anywhere references git_process_start — i.e.
		# while the archive member is provably dead and the linker will drop it.
		local offenders
		offenders="$(printf '%s\n' "${spawn_hits}" | awk '{ print $1 }' | sort -u | grep -v -E '^process(\.c)?\.o$' || true)"
		local referenced
		referenced="$(printf '%s\n' "${table}" | awk -F'\t' '$2 == "U" && $3 == "_git_process_start" { print $1 }' | sort -u)"
		if [ -n "${offenders}" ]; then
			fail "A: spawn symbols outside libgit2's process.o:"
			printf '%s\n' "${offenders}" | sed 's/^/          /'
		elif [ -n "${referenced}" ]; then
			fail "A: something references _git_process_start, so process.o WILL be linked in:"
			printf '%s\n' "${referenced}" | sed 's/^/          /'
		else
			green "    OK  A: spawn symbols confined to an unreferenced process.o (relaxed mode)"
			printf '%s\n' "${spawn_hits}" | sed 's/^/          /'
		fi
	else
		fail "A: process-spawn symbols present. GIT_SSH_EXEC's transport, or
          something like it, has been linked in. This library must not be able
          to spawn a process: the sandbox blocks fork and iOS ships no ssh."
		printf '%s\n' "${spawn_hits}" | sed 's/^/          /'
	fi

	# ---- B ----
	local ucontext_hits
	ucontext_hits="$(printf '%s\n' "${table}" | awk -F'\t' -v re="${UCONTEXT_SYMBOLS}" '$3 ~ re { print $1 "  " $2 "  " $3 }' | sort -u)"
	if [ -z "${ucontext_hits}" ]; then
		green "    OK  B: no getcontext/makecontext/setcontext (ITMS-90338)"
	else
		fail "B: ucontext symbols present — OpenSSL was NOT configured with
          no-async. This is the documented ITMS-90338 'Non-public API usage'
          rejection at upload validation. Rebuild; do not ship."
		printf '%s\n' "${ucontext_hits}" | sed 's/^/          /'
	fi

	# ---- C ----
	local missing=()
	local sym
	for sym in "${REQUIRED_SYMBOLS[@]}"; do
		if ! printf '%s\n' "${table}" | awk -F'\t' -v s="${sym}" '$2 == "D" && $3 == s { found = 1 } END { exit !found }'; then
			missing+=("${sym}")
		fi
	done
	if [ ${#missing[@]} -eq 0 ]; then
		green "    OK  C: libgit2, libssh2 (incl. memory credentials) and OpenSSL all present"
	else
		fail "C: expected symbols missing — the build lost a backend:"
		printf '          %s\n' "${missing[@]}"
	fi
}

# --- D. feature header ----------------------------------------------------
check_feature_headers() {
	local found_any=0
	local features
	while IFS= read -r features; do
		found_any=1
		CHECKED=$((CHECKED + 1))
		head1 "git2_features.h (${features#"${PKG_ROOT}/"})"

		assert_defined()   { if grep -q "^#define $1 1" "${features}"; then green "    OK  D: $1 = 1"; else fail "D: $1 is not 1 — $2"; fi; }
		assert_undefined() { if grep -q "^#define $1" "${features}"; then fail "D: $1 IS defined — $2"; else green "    OK  D: $1 undefined"; fi; }

		assert_defined   GIT_HTTPS                          "HTTPS support is off"
		assert_defined   GIT_OPENSSL                        "the HTTPS backend is not OpenSSL (D-6 requires it)"
		assert_defined   GIT_SSH                            "SSH support is off; credential ladder orders 1 and 2 are dead"
		assert_defined   GIT_SSH_LIBSSH2                    "SSH is not going through libssh2"
		assert_defined   GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS "keys could only be read from disk, not the Keychain"
		assert_defined   GIT_REGEX_BUILTIN                  "REGEX_BACKEND=builtin did not take (did someone write -DUSE_REGEX?)"
		assert_defined   GIT_SHA1_COLLISIONDETECT           "sha1dc is git's own hash; a plain SHA-1 is SHAttered-susceptible"
		assert_defined   GIT_SHA256_OPENSSL                 "SHA-256 is not coming from the libcrypto already in this archive"
		assert_undefined GIT_SHA256_BUILTIN                 "deps/rfc6234's sha.h collides with <openssl/sha.h>"
		assert_undefined GIT_SSH_EXEC                       "that transport forks and execs /usr/bin/ssh"
		assert_undefined GIT_GSSAPI                         "GSS.framework does not exist on iOS"
	done < <(find "${PKG_ROOT}/build" -name 'git2_features.h' -path '*gen_headers*' 2>/dev/null | sort)

	if [ "${found_any}" = "0" ]; then
		item "no build/*/libgit2/gen_headers/git2_features.h found — skipping check D."
		item "(build-xcframework.sh removes build/ unless --keep-build is passed;"
		item " it performs the same assertions inline at configure time.)"
	fi
}

# --- main -----------------------------------------------------------------
if [ ${#EXPLICIT_TARGETS[@]} -gt 0 ]; then
	for lib in "${EXPLICIT_TARGETS[@]}"; do
		[ -f "${lib}" ] || { red "error: ${lib} not found"; exit 2; }
		check_archive "${lib}" "${lib}"
	done
else
	if [ ! -d "${XCFRAMEWORK}" ]; then
		red "error: ${XCFRAMEWORK} not found."
		red "       Run scripts/build-xcframework.sh first, or pass archive paths explicitly."
		exit 2
	fi
	while IFS= read -r lib; do
		slice="$(basename "$(dirname "${lib}")")"
		check_archive "slice ${slice}" "${lib}"
	done < <(find "${XCFRAMEWORK}" -name "${MERGED_LIBRARY_NAME}" | sort)
fi

check_feature_headers

head1 "Result"
if [ "${FAILURES}" -eq 0 ]; then
	green "PASS — ${CHECKED} target(s) checked, 0 failures"
	exit 0
fi
red "FAIL — ${FAILURES} failure(s) across ${CHECKED} target(s)"
exit 1
