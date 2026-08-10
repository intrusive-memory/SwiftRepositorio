#!/usr/bin/env bash
#
# build-xcframework.sh — build Clibgit2.xcframework from pinned upstream source.
#
#   libgit2 1.9.6  +  libssh2 1.11.1  +  OpenSSL 3.5.7
#
# Three slices, arm64 only in each:
#     macos-arm64             (the only slice Escribir links today)
#     ios-arm64               (device)
#     ios-arm64-simulator
#
# Every version is pinned in scripts/versions.sh. Every backend decision is
# explained in README.md § The build. The short version:
#
#   USE_SSH=libssh2          SSH is order 1 and 2 of the credential ladder.
#   USE_HTTPS=OpenSSL        Decision D-6: OpenSSL, not mbedTLS, not
#                            SecureTransport (deprecated).
#   REGEX_BACKEND=builtin    NOT `USE_REGEX` — see README; libgit2's option is
#                            called REGEX_BACKEND and a typo'd -D is silently
#                            ignored by CMake.
#   no-async (OpenSSL)       ITMS-90338: async_posix.c references the non-public
#                            _getcontext/_makecontext/_setcontext trio.
#   GIT_SSH_EXEC unset       fork()+execve() to /usr/bin/ssh. Fails silently at
#                            runtime under the sandbox. See § the guard below.
#
# Usage:
#   scripts/build-xcframework.sh                 # all three slices
#   SLICES="macos-arm64" scripts/build-xcframework.sh
#   scripts/build-xcframework.sh --keep-build    # keep intermediates for nm
#   scripts/build-xcframework.sh --fetch-only    # stages 1-2 only, then exit 0
#   scripts/build-xcframework.sh --configure-only  # + both cmake configures
#
# --fetch-only runs preflight, source fetch, checksum verification, extraction,
# the GIT_SSH_EXEC guard, and every per-slice SDK/triple/zlib resolution — then
# stops before the first compiler invocation. It touches nothing under a slice's
# install prefix, so it is safe to run against a half-finished build tree. Use it
# as a pre-gate: it catches path, quoting, checksum and SDK problems in seconds
# instead of twenty minutes into a compile.
#
# Environment knobs (all optional):
#   SLICES                    space-separated subset of slice names
#   GUARD_PROCESS_SPAWN=0     build stock libgit2 (leaves fork/execve in the
#                             archive as an unreferenced member; see README)
#   OPENSSL_NO_ASM=1          configure OpenSSL with no-asm
#   SIGN_IDENTITY="..."       codesign the finished .xcframework
#   JOBS=N                    parallelism (default: hw.ncpu)
#
# This script NEVER runs `swift build` or `swift test` (Standing Order 1).

set -euo pipefail

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PKG_ROOT}"

# shellcheck source=scripts/versions.sh
source "${SCRIPT_DIR}/versions.sh"

CACHE_DIR="${PKG_ROOT}/.cache"           # downloaded + cloned upstream sources
SRC_DIR="${CACHE_DIR}/src"
BUILD_DIR="${PKG_ROOT}/build"            # per-slice cmake/make trees + prefixes
STAGE_DIR="${PKG_ROOT}/build/stage"      # per-slice merged lib + Headers
ARTIFACTS_DIR="${PKG_ROOT}/artifacts"
XCFRAMEWORK="${ARTIFACTS_DIR}/${XCFRAMEWORK_NAME}.xcframework"

KEEP_BUILD=0
FETCH_ONLY=0
CONFIGURE_ONLY=0
for arg in "$@"; do
	case "$arg" in
		--keep-build) KEEP_BUILD=1 ;;
		--fetch-only) FETCH_ONLY=1 ;;
		--configure-only) CONFIGURE_ONLY=1 ;;
		-h|--help) sed -n '2,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
		*) echo "error: unknown argument '$arg'" >&2; exit 2 ;;
	esac
done

JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
GUARD_PROCESS_SPAWN="${GUARD_PROCESS_SPAWN:-1}"

# ---------------------------------------------------------------------------
# Hermeticity: scrub the environment before CMake can read it
#
# find_library / find_path / find_package consult a long list of environment
# variables in addition to their arguments, and each one is a route by which a
# Homebrew zlib, OpenSSL or PCRE substitutes itself for the SDK's. That failure
# is worse than a build error — it links, it works on the machine that built it,
# and it yields an artefact CI cannot reproduce. Unset them rather than hoping.
# ---------------------------------------------------------------------------
unset CMAKE_PREFIX_PATH CMAKE_LIBRARY_PATH CMAKE_INCLUDE_PATH CMAKE_FRAMEWORK_PATH
unset CMAKE_APPBUNDLE_PATH CMAKE_PROGRAM_PATH CMAKE_MODULE_PATH
unset PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBRARY_PATH CPATH C_INCLUDE_PATH
unset SDKROOT MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET
unset OPENSSL_ROOT_DIR ZLIB_ROOT

# Prefixes that must never contribute a library or header to any slice. CMake on
# Apple Silicon has /opt/homebrew on its default search path, which is how a host
# PCRE got resolved on an earlier run even though REGEX_BACKEND=builtin means
# libgit2 never consults it.
HOST_PREFIXES="/opt/homebrew;/usr/local;/opt/local;/sw"

# slice | cmake CMAKE_SYSTEM_NAME | sdk | arch | openssl Configure target | version-min flag
ALL_SLICES=(
	"macos-arm64|Darwin|macosx|arm64|darwin64-arm64|-mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}"
	"ios-arm64|iOS|iphoneos|arm64|ios64-xcrun|-miphoneos-version-min=${IOS_DEPLOYMENT_TARGET}"
	"ios-arm64-simulator|iOS|iphonesimulator|arm64|iossimulator-arm64-xcrun|-mios-simulator-version-min=${IOS_DEPLOYMENT_TARGET}"
)

SELECTED="${SLICES:-macos-arm64 ios-arm64 ios-arm64-simulator}"

# Set per slice in the build loop. Every compiler invocation gets an explicit
# `-target <triple>`, which is the difference between an xcframework that
# assembles and one that does not: `xcodebuild -create-xcframework` reads the
# platform out of each object's LC_BUILD_VERSION, and if the simulator slice were
# to come out tagged `ios` rather than `ios-simulator` the command fails with
# "two equivalent library definitions". CMAKE_OSX_SYSROOT alone has been known to
# leave that tag ambiguous; a triple never is.
SLICE_TRIPLE=""

# Progress goes to stderr; only *data* goes to stdout.
#
# This is not a stylistic preference. Writing progress to stdout is what produced
# the `tar: … m: No such file or directory` failure: fetch_tarball logged with
# `step` and returned its path by echoing it, so `x="$(fetch_tarball …)"` captured
# the log lines INTO the variable, and tar was then handed a three-line operand.
# The log lines only became visible because tar quoted them back in its error
# message, which is also why "downloading" appeared to print after "extracting".
# With progress on stderr, a stray log line inside a function can no longer
# corrupt that function's return value.
#
# Value-returning helpers additionally assign to a named global rather than
# echoing (see fetch_tarball, sdk_zlib), so there is no command substitution left
# to capture anything in the first place. Belt and braces, because this class of
# bug is silent until it reaches a gate.
log()  { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }
step() { printf '    -- %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# assert_no_host_paths <CMakeCache.txt> <label>
#
# The hermeticity gate. Scrubbing the environment and ignoring host prefixes are
# both preventive; this is the check that says whether they worked. It looks only
# at cache entries that name a resolved library, header directory or link
# directory — deliberately NOT at *_EXECUTABLE or CMAKE_MAKE_PROGRAM, because
# pkg-config, cmake and ninja legitimately live in /opt/homebrew/bin and their
# location has no effect on what gets linked.
#
# A host path here means the artefact embeds something from this machine that CI
# does not have, or has at a different version. That is not a warning.
# ---------------------------------------------------------------------------
assert_no_host_paths() {
	local cache="$1" label="$2"
	[ -f "${cache}" ] || return 0

	# Two exclusions, both deliberate:
	#
	#   *_EXECUTABLE / CMAKE_MAKE_PROGRAM etc. are not matched by the key pattern
	#   at all — cmake, ninja and pkg-config legitimately live in /opt/homebrew/bin
	#   and where the tools live has no bearing on what gets linked.
	#
	#   Keys beginning with an underscore are pkg-config's scratch namespace
	#   (_OPENSSL_LDFLAGS, _OPENSSL_INCLUDE_DIRS, …). CMake's FindOpenSSL runs
	#   pkg_check_modules purely for hints and then discards the result when
	#   OPENSSL_ROOT_DIR is given explicitly, so those entries record what
	#   pkg-config *saw*, not what the build *uses*. Failing on them would fail a
	#   correct build, and an assertion that cries wolf gets an `|| true` bolted
	#   onto it within a week. What pkg-config can see is instead constrained at
	#   source, by PKG_CONFIG_LIBDIR — see the per-slice export in the build loop.
	local offenders
	offenders="$(awk -F: '
		/^[A-Za-z0-9_]+:(FILEPATH|PATH|STRING|INTERNAL)=/ {
			key = $1
			type = $2
			sub(/=.*/, "", type)
			val = $0
			sub(/^[^=]*=/, "", val)
			if (key !~ /_(LIBRARY|LIBRARIES|INCLUDE_DIR|INCLUDE_DIRS|LIBRARY_DIRS|LIBRARY_DIR|RESOLVED|LDFLAGS)$/) next
			if (type == "INTERNAL" && key ~ /^_/) next
			if (val ~ /\/opt\/homebrew|\/usr\/local\/|\/opt\/local\/|^\/sw\//) print "          " key " = " val
		}
	' "${cache}" | sort -u)"

	if [ -n "${offenders}" ]; then
		printf '%s\n' "${offenders}" >&2
		die "${label}: host-prefix contamination. The entries above resolve to
       libraries or headers outside the SDK and outside this build's own prefix,
       so the artefact would embed something from this machine. Do not ship it.
       Homebrew's cmake/ninja/pkg-config executables are fine and are not
       checked; only resolved library and include paths are."
	fi
	step "${label}: no host-prefix contamination"
}

# ---------------------------------------------------------------------------
# Stamps — idempotency across re-runs
#
# A prefix produced by an older recipe is indistinguishable from a current one by
# file existence alone, which is how "just re-run it" silently reuses a wrong
# install. Each component stamps its prefix with RECIPE_REVISION plus everything
# that would change its output; a mismatch rebuilds instead of reusing.
# ---------------------------------------------------------------------------
stamp_key() {
	# <component> <slice> <triple> <version-or-sha>
	printf '%s|%s|%s|%s|%s' "${RECIPE_REVISION}" "$1" "$2" "$3" "$4"
}

stamp_matches() {
	local file="$1" want="$2"
	[ -f "${file}" ] && [ "$(cat "${file}")" = "${want}" ]
}

stamp_write() {
	local file="$1" want="$2"
	mkdir -p "$(dirname "${file}")"
	printf '%s' "${want}" > "${file}"
}

# ---------------------------------------------------------------------------
# hermetic_cmake_args <prefix> <sdk_path>
#
# Emits the find-path arguments shared by the libssh2 and libgit2 configures.
# Order is the whole point: CMAKE_LIBRARY_PATH and CMAKE_INCLUDE_PATH are
# searched ahead of the PATHS given inside a find_library() call, so this build's
# own prefix must come first and the SDK second. Nothing else may come at all.
#
# This is what fixes libgit2's `could not resolve z`. libgit2's
# cmake/FindPkgLibraries.cmake takes each -l token out of libssh2.pc (`ssh2`,
# `crypto`, `z`) and re-resolves it with find_library(). Only the first two live
# in our prefix; `z` is the SDK's, and on modern macOS it exists only as
# <SDK>/usr/lib/libz.tbd — there is no /usr/lib/libz.dylib on disk any more.
# CMAKE_LIBRARY_PATH pointed at <SDK>/usr/lib is what lets find_library see it
# (verified: CMAKE_FIND_LIBRARY_SUFFIXES on Apple is ".tbd;.dylib;.so;.a", so the
# .tbd is tried first).
# ---------------------------------------------------------------------------

# sdk_zlib <sdk_path>
#
# Sets SDK_ZLIB to that SDK's zlib stub. Assigns a global rather than echoing, for
# the same reason as fetch_tarball, and because `die` inside a command
# substitution only kills the subshell — the caller would sail on with an empty
# string and hand CMake `-DZLIB_LIBRARY=`.
#
# On modern macOS there is no /usr/lib/libz.dylib on disk — the dylib lives in
# the dyld shared cache and only the SDK's .tbd stub exists as a file. Anything
# that resolves "z" must therefore be told where the SDK is.
# unpack_openssl_source <slice> <work-dir>
#
# OpenSSL is extracted per slice rather than once, because its build tree is
# configured in place and cannot be shared. Factored out of build_openssl so that
# --fetch-only can exercise this exact extraction without invoking a compiler.
unpack_openssl_source() {
	local slice="$1" work="$2"

	[ -f "${OPENSSL_TARBALL}" ] || die "openssl: tarball path is not a file: '${OPENSSL_TARBALL}'"

	step "openssl: unpacking source for ${slice}"
	rm -rf "${work}"
	mkdir -p "${work}"
	tar -xz -f "${OPENSSL_TARBALL}" -C "${work}" --strip-components=1

	[ -x "${work}/Configure" ] || die "openssl: ${work}/Configure missing after extraction — wrong strip-components?"
}

SDK_ZLIB=""
sdk_zlib() {
	local sdk_path="$1" candidate
	SDK_ZLIB=""
	for candidate in "${sdk_path}/usr/lib/libz.tbd" "${sdk_path}/usr/lib/libz.dylib"; do
		if [ -e "${candidate}" ]; then SDK_ZLIB="${candidate}"; return 0; fi
	done
	die "no libz in ${sdk_path}/usr/lib"
}

hermetic_cmake_args() {
	local prefix="$1" sdk_path="$2"
	printf '%s\n' \
		"-DCMAKE_LIBRARY_PATH=${prefix}/lib;${sdk_path}/usr/lib" \
		"-DCMAKE_INCLUDE_PATH=${prefix}/include;${sdk_path}/usr/include" \
		"-DCMAKE_IGNORE_PREFIX_PATH=${HOST_PREFIXES}" \
		"-DCMAKE_IGNORE_PATH=/opt/homebrew/lib;/opt/homebrew/include;/usr/local/lib;/usr/local/include;/opt/local/lib;/opt/local/include" \
		"-DCMAKE_FIND_FRAMEWORK=LAST" \
		"-DCMAKE_FIND_APPBUNDLE=NEVER"

	# Tools, as opposed to libraries, are supposed to come from the host. Passing
	# them explicitly keeps CMAKE_IGNORE_PREFIX_PATH from having to be careful
	# about /opt/homebrew/bin: ninja and pkg-config are found here, once, by the
	# shell, instead of by a find_program() that the ignore list also filters.
	printf '%s\n' "-DCMAKE_MAKE_PROGRAM=$(command -v ninja)"

	# Third argument `no-pkgconfig` denies the project pkg-config entirely, by
	# pre-seeding PKG_CONFIG_EXECUTABLE with a path that cannot exist. FindPkgConfig
	# then skips its find_program (the cache entry is already set) and every
	# pkg_check_modules call fails cleanly rather than erroring.
	#
	# libgit2 is configured this way on purpose. Its cmake/SelectSSH.cmake calls
	# find_pkglibraries(LIBSSH2 libssh2), and cmake/FindPkgLibraries.cmake takes
	# every -l token out of libssh2.pc — ssh2, crypto, z — and RE-RESOLVES each one
	# by name with find_library(). That re-resolution is the only thing in this
	# build that ever searches for a system library by name, and it is pure
	# downside: every dependency is already handed to libgit2 as an explicit
	# absolute path (LIBSSH2_LIBRARY, OPENSSL_*_LIBRARY, ZLIB_LIBRARY), and a
	# pre-seeded cache entry makes find_library a no-op. With pkg-config denied,
	# SelectSSH falls through to find_package(LibSSH2), whose FindLibSSH2.cmake
	# wants exactly the LIBSSH2_INCLUDE_DIR and LIBSSH2_LIBRARY we already pass.
	#
	# Same artefacts, one fewer mechanism, and no dependence on what pkg-config
	# thinks the world looks like. libssh2's own configure keeps pkg-config: it
	# uses it only for FindOpenSSL hints, and PKG_CONFIG_LIBDIR confines it.
	if [ "${3:-pkgconfig}" = "no-pkgconfig" ]; then
		printf '%s\n' "-DPKG_CONFIG_EXECUTABLE=${PKG_CONFIG_DENIED}"
	elif [ "${HAVE_PKGCONFIG}" = "1" ]; then
		printf '%s\n' "-DPKG_CONFIG_EXECUTABLE=$(command -v pkg-config)"
	fi
}

# A path that is guaranteed not to exist, used to deny a project pkg-config.
PKG_CONFIG_DENIED="${PKG_ROOT}/scripts/.no-pkg-config-on-purpose"

# ---------------------------------------------------------------------------
# [1/7] Preflight
# ---------------------------------------------------------------------------
log "[1/7] Preflight"

for tool in cmake ninja xcodebuild xcrun lipo libtool nm perl make git curl shasum; do
	command -v "$tool" >/dev/null 2>&1 || die "required tool '$tool' not found in PATH.
       hint: brew install cmake ninja  (the rest ship with Xcode / macOS)"
done

# pkg-config is optional but strongly preferred: libgit2's SelectSSH.cmake tries
# find_pkglibraries(LIBSSH2 libssh2) first and only falls back to its own
# FindLibSSH2 module. We feed both paths, so either works.
if command -v pkg-config >/dev/null 2>&1; then
	HAVE_PKGCONFIG=1
else
	HAVE_PKGCONFIG=0
	step "pkg-config absent — relying on FindLibSSH2 + explicit -DLIBSSH2_* vars"
fi

xcodebuild -version 2>/dev/null | sed -n '1s/^/    -- /p' >&2
step "jobs: ${JOBS}"
step "slices: ${SELECTED}"
step "libgit2 ${LIBGIT2_VERSION} / libssh2 ${LIBSSH2_VERSION} / OpenSSL ${OPENSSL_VERSION}"

# ---------------------------------------------------------------------------
# [2/7] Fetch and verify pinned sources
# ---------------------------------------------------------------------------
log "[2/7] Fetch and verify pinned sources"

mkdir -p "${SRC_DIR}"

# clone_pinned <name> <repo> <tag> <expected-commit>
clone_pinned() {
	local name="$1" repo="$2" tag="$3" want="$4"
	local dst="${SRC_DIR}/${name}"

	if [ -d "${dst}/.git" ]; then
		local have
		have="$(git -C "${dst}" rev-parse HEAD)"
		if [ "${have}" = "${want}" ]; then
			step "${name}: cached at ${want}"
			return 0
		fi
		step "${name}: cached tree is at ${have}, wanted ${want} — refetching"
		rm -rf "${dst}"
	fi

	step "${name}: cloning ${tag}"
	git clone --quiet --depth 1 --branch "${tag}" "${repo}" "${dst}"

	local have
	have="$(git -C "${dst}" rev-parse HEAD)"
	[ "${have}" = "${want}" ] || die "${name} ${tag} resolved to ${have}, expected ${want}.
       Either the tag moved (treat as a supply-chain event) or versions.sh is stale."
	step "${name}: verified ${want}"
}

# fetch_tarball <name> <url> <expected-sha256>
#
# Sets FETCHED_TARBALL to the verified path. Deliberately does NOT echo the path:
# it logs, and a function that both logs and echoes its result cannot be called in
# a command substitution safely. Read the global immediately after the call.
#
# Used for libssh2 and OpenSSL, both of which publish immutable uploaded release
# assets. A mismatch deletes the file and stops: a checksum failure here is a
# supply-chain event, not something to retry through.
FETCHED_TARBALL=""
fetch_tarball() {
	local name="$1" url="$2" want="$3"
	local base="${url##*/}"
	local dst="${CACHE_DIR}/${base}"
	FETCHED_TARBALL=""

	if [ -f "${dst}" ]; then
		step "${name}: ${base} already in .cache"
	else
		step "${name}: downloading ${base}"
		curl -fsSL "${url}" -o "${dst}.partial"
		mv "${dst}.partial" "${dst}"
	fi

	local have
	have="$(shasum -a 256 "${dst}" | awk '{print $1}')"
	if [ "${have}" != "${want}" ]; then
		rm -f "${dst}"
		die "${name}: sha256 mismatch on ${base}.
       expected ${want}
       actual   ${have}
       The file has been deleted. Do not retry blindly — verify upstream."
	fi
	step "${name}: sha256 verified ${want}"

	# Prove it is a readable gzip archive before anything tries to extract it. A
	# truncated-but-correct-length download is not a thing, but a cache file
	# clobbered by an editor or a half-finished `mv` is.
	tar -tzf "${dst}" >/dev/null 2>&1 || die "${name}: ${base} is not a readable gzip tar archive."

	FETCHED_TARBALL="${dst}"
}

# extract_tarball <name> <tarball> <sha> — idempotent, stamped
#
# Re-extracts whenever the stamp does not match, which covers three cases the
# supervisor will actually hit: a first run, a bumped version, and — the one that
# bit here — a directory left behind by the previous *git-based* fetch, which is
# detected by the presence of .git and wiped.
extract_tarball() {
	local name="$1" tarball="$2" sha="$3"
	local dst="${SRC_DIR}/${name}"
	local stamp="${dst}/.swiftrepositorio-stamp"
	local want="${RECIPE_REVISION}|${sha}"

	if [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${want}" ] && [ ! -d "${dst}/.git" ]; then
		step "${name}: source tree cached"
		return 0
	fi
	if [ -d "${dst}/.git" ]; then
		step "${name}: replacing a git checkout left by an earlier recipe"
	fi

	[ -f "${tarball}" ] || die "${name}: extract called with a tarball path that is not a file:
       '${tarball}'
       (If this looks like it has log lines in it, a value-returning helper is
       logging to stdout again — see the note on log/step.)"

	step "${name}: extracting ${tarball##*/}"
	rm -rf "${dst}"
	mkdir -p "${dst}"
	tar -xz -f "${tarball}" -C "${dst}" --strip-components=1
	printf '%s' "${want}" > "${stamp}"
}

clone_pinned libgit2 "${LIBGIT2_REPO}" "${LIBGIT2_TAG}" "${LIBGIT2_COMMIT}"

fetch_tarball libssh2 "${LIBSSH2_TARBALL_URL}" "${LIBSSH2_TARBALL_SHA256}"
LIBSSH2_TARBALL="${FETCHED_TARBALL}"
extract_tarball libssh2 "${LIBSSH2_TARBALL}" "${LIBSSH2_TARBALL_SHA256}"

# The tarball must carry the clean version string. If it ever does not, the
# runtime assertion in Sortie 1b's tests is what breaks, a long way from here.
LIBSSH2_HEADER_VERSION="$(awk -F'"' '/^#define LIBSSH2_VERSION[[:space:]]/{print $2; exit}' "${SRC_DIR}/libssh2/include/libssh2.h")"
[ "${LIBSSH2_HEADER_VERSION}" = "${LIBSSH2_VERSION}" ] || die "libssh2 header reports version '${LIBSSH2_HEADER_VERSION}', expected '${LIBSSH2_VERSION}'.
       The git TAG carries '1.11.1_DEV'; only the release tarball carries a clean
       version. If this fired, something re-pointed the source at the tag. See
       the libssh2 block in scripts/versions.sh."
step "libssh2: header version ${LIBSSH2_HEADER_VERSION}"

fetch_tarball openssl "${OPENSSL_TARBALL_URL}" "${OPENSSL_TARBALL_SHA256}"
OPENSSL_TARBALL="${FETCHED_TARBALL}"

# ---------------------------------------------------------------------------
# The GIT_SSH_EXEC guard
#
# Plan-of-record assumed src/util/unix/process.c would simply not be compiled
# when GIT_SSH_EXEC is off. That is FALSE for libgit2 1.9.6:
#
#   src/util/CMakeLists.txt:  file(GLOB UTIL_SRC_OS unix/*.c unix/*.h)
#
# unix/process.c is globbed unconditionally and its body carries no #ifdef, so
# raw fork() (line ~374) and execve() (line ~409) land in libgit2.a as members
# of the `util` object library every time.
#
# What IS true: nothing references it once ssh_exec is out. `git_process_start`
# and friends are referenced only by src/libgit2/transports/ssh_exec.c (wholly
# inside #ifdef GIT_SSH_EXEC), src/cli/cmd_commit.c (BUILD_CLI=OFF), and the
# test suite (BUILD_TESTS=OFF). ssh_libssh2.c does include process.h, but only
# for git_process__is_cmdline_option(), which is a GIT_INLINE in the header and
# therefore creates no link dependency. So the member is dead weight the linker
# will not pull into an app binary.
#
# "Dead but present" is not what the exit criterion asks for, and it is not what
# we want to hand a static analyser either. This transform makes the symbols
# physically absent: the implementation moves to a .h (CMake adds headers to
# target_sources but never compiles them) and the .c becomes a stub that
# includes it only under GIT_SSH_EXEC. If some future libgit2 genuinely needs
# git_process_start on the libssh2 path, the link fails loudly instead of
# quietly shelling out to a binary iOS does not have.
# ---------------------------------------------------------------------------
guard_process_spawn() {
	local root="${SRC_DIR}/libgit2"
	local impl="${root}/src/util/unix/process.c"
	local moved="${root}/src/util/unix/process_spawn_impl.h"

	if [ "${GUARD_PROCESS_SPAWN}" != "1" ]; then
		step "GIT_SSH_EXEC guard: DISABLED by GUARD_PROCESS_SPAWN=0"
		return 0
	fi

	if grep -q 'SWIFTREPOSITORIO_PROCESS_SPAWN_GUARDED' "${impl}" 2>/dev/null; then
		step "GIT_SSH_EXEC guard: already applied"
		return 0
	fi

	[ -f "${impl}" ] || die "src/util/unix/process.c not found — libgit2 layout changed.
       Re-read src/util/CMakeLists.txt before touching this guard."
	grep -q 'execve(' "${impl}" || die "src/util/unix/process.c no longer calls execve().
       The guard's premise changed; re-verify before assuming it is still needed."

	mv "${impl}" "${moved}"
	cat > "${impl}" <<'GUARD'
/*
 * SWIFTREPOSITORIO_PROCESS_SPAWN_GUARDED
 *
 * Applied by scripts/build-xcframework.sh. Upstream compiles this translation
 * unit unconditionally (src/util/CMakeLists.txt globs unix/*.c), which puts
 * fork() and execve() into libgit2.a even when GIT_SSH_EXEC is off. The real
 * implementation now lives in process_spawn_impl.h and is compiled only when
 * the exec-ssh transport is actually enabled — which, in this package, it never
 * is. See README.md § Why GIT_SSH_EXEC is off.
 */

#include "git2_util.h"

#ifdef GIT_SSH_EXEC
#	include "process_spawn_impl.h"
#else
typedef int git_process__spawn_disabled_translation_unit;
#endif
GUARD
	step "GIT_SSH_EXEC guard: applied (fork/execve moved behind #ifdef GIT_SSH_EXEC)"
}

guard_process_spawn

# ---------------------------------------------------------------------------
# Per-slice preparation — the last thing before a compiler runs
#
# Resolves the SDK, the target triple, and the SDK's zlib/iconv stubs for each
# selected slice, and unpacks OpenSSL's source into that slice's work directory.
# All of it is filesystem and path work, none of it compiles, and every step here
# is a place where a quoting or ordering mistake has already bitten once. Running
# it as its own stage means --fetch-only exercises the real code paths rather than
# an approximation of them.
# ---------------------------------------------------------------------------
prepare_slice() {
	local slice="$1" sdk="$2" arch="$3"

	SLICE_SDK_PATH="$(xcrun --sdk "${sdk}" --show-sdk-path)"
	[ -d "${SLICE_SDK_PATH}" ] || die "${slice}: SDK path does not exist: ${SLICE_SDK_PATH}"

	case "${sdk}" in
		macosx)          SLICE_TRIPLE="${arch}-apple-macos${MACOS_DEPLOYMENT_TARGET}" ;;
		iphoneos)        SLICE_TRIPLE="${arch}-apple-ios${IOS_DEPLOYMENT_TARGET}" ;;
		iphonesimulator) SLICE_TRIPLE="${arch}-apple-ios${IOS_DEPLOYMENT_TARGET}-simulator" ;;
		*) die "no target triple mapping for sdk '${sdk}'" ;;
	esac

	sdk_zlib "${SLICE_SDK_PATH}"

	SLICE_ICONV=""
	local candidate
	for candidate in "${SLICE_SDK_PATH}/usr/lib/libiconv.tbd" "${SLICE_SDK_PATH}/usr/lib/libiconv.dylib"; do
		if [ -e "${candidate}" ]; then SLICE_ICONV="${candidate}"; break; fi
	done

	step "sdk:     ${SLICE_SDK_PATH}"
	step "triple:  ${SLICE_TRIPLE}"
	step "zlib:    ${SDK_ZLIB}"
	step "iconv:   ${SLICE_ICONV:-<none, USE_ICONV=OFF>}"
}
SLICE_SDK_PATH=""
SLICE_ICONV=""

if [ "${FETCH_ONLY}" = "1" ]; then
	log "[fetch-only] Per-slice preparation"
	for entry in "${ALL_SLICES[@]}"; do
		IFS='|' read -r slice _system sdk arch _ossl_target _vmin <<< "${entry}"
		case " ${SELECTED} " in *" ${slice} "*) ;; *) continue ;; esac
		log "[fetch-only] slice ${slice}"
		prepare_slice "${slice}" "${sdk}" "${arch}"
		unpack_openssl_source "${slice}" "${BUILD_DIR}/${slice}/openssl"
	done

	log "[fetch-only] Source trees"
	step "libgit2: ${SRC_DIR}/libgit2 ($(git -C "${SRC_DIR}/libgit2" rev-parse --short HEAD))"
	step "libssh2: ${SRC_DIR}/libssh2 (LIBSSH2_VERSION ${LIBSSH2_HEADER_VERSION})"
	step "openssl: $(basename "${OPENSSL_TARBALL}"), unpacked per slice"

	log "[fetch-only] PASS — nothing compiled, no install prefix touched"
	exit 0
fi


# ---------------------------------------------------------------------------
# [3/7] Per-slice build: OpenSSL -> libssh2 -> libgit2
# ---------------------------------------------------------------------------
log "[3/7] Per-slice build"

rm -rf "${STAGE_DIR}"
mkdir -p "${STAGE_DIR}"

build_openssl() {
	local slice="$1" sdk_path="$2" arch="$3" ossl_target="$4" vmin="$5" prefix="$6"
	local work="${BUILD_DIR}/${slice}/openssl"
	local stamp="${prefix}/.stamp.openssl"

	local asm_opt=""
	if [ "${OPENSSL_NO_ASM:-0}" = "1" ]; then
		asm_opt="no-asm"
	fi

	local want
	want="$(stamp_key openssl "${slice}" "${SLICE_TRIPLE}" "${OPENSSL_TARBALL_SHA256}:${asm_opt}")"

	if stamp_matches "${stamp}" "${want}" \
		&& [ -f "${prefix}/lib/libcrypto.a" ] && [ -f "${prefix}/lib/libssl.a" ]; then
		step "openssl: reusing ${slice} (stamp matches)"
		return 0
	fi

	# OpenSSL is the root of this prefix — libssh2 links against it and libgit2
	# resolves both out of it — so a stale OpenSSL invalidates the whole prefix.
	# Wiping it is the only honest option; a partial refresh would leave libssh2
	# linked against headers that no longer match.
	if [ -d "${prefix}" ]; then
		step "openssl: prefix is stale or unstamped — rebuilding ${slice} from scratch"
		rm -rf "${prefix}"
	fi
	mkdir -p "${prefix}"

	unpack_openssl_source "${slice}" "${work}"

	# Configure notes, each one load-bearing:
	#
	#   no-async   ITMS-90338. crypto/async/arch/async_posix.c uses getcontext /
	#              makecontext / setcontext, which Apple's upload validator
	#              treats as non-public symbol usage. OpenSSL's own iOS targets
	#              (Configurations/15-ios.conf, "ios-common") already carry
	#              disable => ["async"] — the macOS target does NOT, so this
	#              flag is what actually matters for the macos-arm64 slice.
	#              Passed on every slice anyway: intent belongs in the script.
	#   no-shared  we want .a only; a dylib would have to be embedded + signed.
	#   no-tests / no-apps / no-docs   nothing here ships the openssl CLI.
	#   no-engine  OpenSSL 3 uses providers; ENGINE is legacy dlopen surface.
	#   no-comp    TLS-level compression (CRIME); libssh2 compression is a
	#              separate switch and is also off.
	#   no-ssl3 / no-ssl3-method / no-weak-ssl-ciphers   nothing we talk to.
	#
	# Deliberately NOT passed:
	#   no-legacy      the legacy provider is what reads old PEM private keys.
	#                  The requirements' primary credential is an existing
	#                  ~/.ssh/id_rsa which may well be legacy PEM; breaking that
	#                  to save a few hundred KB would reproduce exactly the
	#                  "looks like a bad key" misdiagnosis this package exists to
	#                  avoid.
	#   no-deprecated  libssh2 still calls a handful of OpenSSL 1.1-era APIs.
	#   --libdir is pinned to `lib` so the prefix layout is identical on every
	#   slice (some platforms default to lib64 and then CMake cannot find it).
	#
	# --openssldir points at a path that will not exist on any shipping device,
	# and that is deliberate rather than sloppy: a sandboxed app has no
	# /usr/local/ssl/certs, so OpenSSL's SSL_CTX_set_default_verify_paths() finds
	# no trust store and HTTPS certificate verification fails. The fix is a
	# runtime one and it belongs to the sorties that open connections, not here —
	# see README § The trust store problem. Baking a CA bundle into this
	# xcframework would silently make this package the owner of a root store.
	step "openssl: configuring ${slice} (${ossl_target})"
	(
		cd "${work}"
		export CC
		CC="$(xcrun -f clang)"
		export CFLAGS="-target ${SLICE_TRIPLE} -isysroot ${sdk_path} -arch ${arch} ${vmin} -fno-common -O2"
		export LDFLAGS="-target ${SLICE_TRIPLE} -isysroot ${sdk_path} -arch ${arch} ${vmin}"
		./Configure "${ossl_target}" \
			no-shared \
			no-async \
			no-tests \
			no-apps \
			no-docs \
			no-engine \
			no-comp \
			no-ssl3 \
			no-ssl3-method \
			no-weak-ssl-ciphers \
			${asm_opt} \
			--prefix="${prefix}" \
			--openssldir="${prefix}/ssl" \
			--libdir=lib \
			> "${work}/configure.log" 2>&1 || {
				tail -40 "${work}/configure.log" >&2
				die "openssl Configure failed for ${slice} (see ${work}/configure.log)"
			}

		# Belt and braces: prove no-async actually took, rather than trusting
		# that the flag spelling is still current.
		grep -q 'define OPENSSL_NO_ASYNC' include/openssl/configuration.h \
			|| die "OpenSSL configured WITHOUT no-async for ${slice}.
       OPENSSL_NO_ASYNC is missing from include/openssl/configuration.h, which
       means the ITMS-90338 mitigation is not in effect. Do not ship this."

		step "openssl: building ${slice}"
		make -j"${JOBS}" build_libs > "${work}/build.log" 2>&1 || {
			tail -40 "${work}/build.log" >&2
			die "openssl build failed for ${slice} (see ${work}/build.log)"
		}
		# install_dev = headers + static libs + pkgconfig, no apps, no man pages.
		make install_dev > "${work}/install.log" 2>&1 || {
			tail -40 "${work}/install.log" >&2
			die "openssl install failed for ${slice} (see ${work}/install.log)"
		}
	)

	[ -f "${prefix}/lib/libcrypto.a" ] || die "openssl: ${prefix}/lib/libcrypto.a missing after install"
	[ -f "${prefix}/lib/libssl.a" ]    || die "openssl: ${prefix}/lib/libssl.a missing after install"
	stamp_write "${stamp}" "${want}"
}

configure_libssh2() {
	local slice="$1" system="$2" sdk_path="$3" arch="$4" vmin="$5" prefix="$6" work="$7"

	step "libssh2: configuring ${slice}"
	rm -rf "${work}"
	mkdir -p "${work}"

	local hermetic=()
	while IFS= read -r a; do hermetic+=("${a}"); done < <(hermetic_cmake_args "${prefix}" "${sdk_path}")

	sdk_zlib "${sdk_path}"
	local zlib_lib="${SDK_ZLIB}"

	# CRYPTO_BACKEND=OpenSSL is what gives us ed25519 (src/openssl.h defines
	# LIBSSH2_ED25519 1) and rsa-sha2-256/512. The mbedTLS backend defines
	# LIBSSH2_ED25519 0 — that is the whole reason D-6 lands on OpenSSL.
	#
	# ENABLE_ZLIB_COMPRESSION=OFF turns off SSH-level compression, which GitHub
	# does not negotiate. It does NOT stop libssh2 from linking zlib: libssh2's
	# OpenSSL branch calls find_package(ZLIB) unconditionally (CMakeLists.txt
	# ~line 336) and appends it to LIBSSH2_LIBS, which is where the `-lz` in the
	# generated libssh2.pc comes from — and that `-lz` is what libgit2 later has
	# to re-resolve. So zlib is pointed at the SDK explicitly here, exactly as it
	# is for libgit2. Left to itself, find_package(ZLIB) resolves whatever the
	# host happens to have.
	cmake -S "${SRC_DIR}/libssh2" -B "${work}" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_SYSTEM_NAME="${system}" \
		-DCMAKE_OSX_SYSROOT="${sdk_path}" \
		-DCMAKE_OSX_ARCHITECTURES="${arch}" \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="${vmin}" \
		-DCMAKE_C_FLAGS="-target ${SLICE_TRIPLE}" \
		-DCMAKE_INSTALL_PREFIX="${prefix}" \
		-DCMAKE_INSTALL_LIBDIR=lib \
		"${hermetic[@]}" \
		-DBUILD_SHARED_LIBS=OFF \
		-DBUILD_STATIC_LIBS=ON \
		-DBUILD_EXAMPLES=OFF \
		-DBUILD_TESTING=OFF \
		-DENABLE_ZLIB_COMPRESSION=OFF \
		-DCRYPTO_BACKEND=OpenSSL \
		-DOPENSSL_ROOT_DIR="${prefix}" \
		-DOPENSSL_USE_STATIC_LIBS=ON \
		-DOPENSSL_INCLUDE_DIR="${prefix}/include" \
		-DOPENSSL_CRYPTO_LIBRARY="${prefix}/lib/libcrypto.a" \
		-DOPENSSL_SSL_LIBRARY="${prefix}/lib/libssl.a" \
		-DZLIB_INCLUDE_DIR="${sdk_path}/usr/include" \
		-DZLIB_LIBRARY="${zlib_lib}" \
		> "${work}/configure.log" 2>&1 || {
			tail -40 "${work}/configure.log" >&2
			die "libssh2 cmake configure failed for ${slice} (see ${work}/configure.log)"
		}

	assert_no_host_paths "${work}/CMakeCache.txt" "libssh2 ${slice}"
}

build_libssh2() {
	local slice="$1" system="$2" sdk_path="$3" arch="$4" vmin="$5" prefix="$6"
	local work="${BUILD_DIR}/${slice}/libssh2"
	local stamp="${prefix}/.stamp.libssh2"
	local want
	want="$(stamp_key libssh2 "${slice}" "${SLICE_TRIPLE}" "${LIBSSH2_TARBALL_SHA256}")"

	if stamp_matches "${stamp}" "${want}" && [ -f "${prefix}/lib/libssh2.a" ]; then
		step "libssh2: reusing ${slice} (stamp matches)"
		return 0
	fi

	# Remove only libssh2's own installed files, so a libssh2-only recipe change
	# does not force an OpenSSL rebuild. Anything OpenSSL owns in this prefix is
	# left alone; its stamp governs it.
	rm -f "${prefix}/lib/libssh2.a" "${prefix}/lib/pkgconfig/libssh2.pc" "${stamp}"
	rm -f "${prefix}"/include/libssh2*.h
	rm -rf "${prefix}/lib/cmake/libssh2"

	configure_libssh2 "${slice}" "${system}" "${sdk_path}" "${arch}" "${vmin}" "${prefix}" "${work}"

	step "libssh2: building ${slice}"
	cmake --build "${work}" --parallel "${JOBS}" > "${work}/build.log" 2>&1 || {
		tail -40 "${work}/build.log" >&2
		die "libssh2 build failed for ${slice} (see ${work}/build.log)"
	}
	cmake --install "${work}" > "${work}/install.log" 2>&1 || {
		tail -40 "${work}/install.log" >&2
		die "libssh2 install failed for ${slice} (see ${work}/install.log)"
	}

	[ -f "${prefix}/lib/libssh2.a" ] || die "libssh2: ${prefix}/lib/libssh2.a missing after install"

	# The .pc is what libgit2 reads. Record what it ended up saying, because
	# `Version:` here is the first place a tag-versus-tarball mix-up shows up.
	local pc="${prefix}/lib/pkgconfig/libssh2.pc"
	if [ -f "${pc}" ]; then
		local pc_version
		pc_version="$(awk '/^Version:/{sub(/^Version:[[:space:]]*/, ""); print; exit}' "${pc}")"
		[ "${pc_version}" = "${LIBSSH2_VERSION}" ] || die "libssh2.pc reports Version: ${pc_version}, expected ${LIBSSH2_VERSION}"
		step "libssh2: libssh2.pc Version: ${pc_version}, Libs: $(awk '/^Libs:/{sub(/^Libs:[[:space:]]*/, ""); print; exit}' "${pc}")"
	fi

	stamp_write "${stamp}" "${want}"
}

configure_libgit2() {
	local slice="$1" system="$2" sdk_path="$3" arch="$4" vmin="$5" prefix="$6" work="$7"

	for required in libcrypto.a libssl.a libssh2.a; do
		[ -f "${prefix}/lib/${required}" ] || die "libgit2 ${slice}: ${prefix}/lib/${required} is missing.
       libgit2's configure needs OpenSSL and libssh2 already installed into the
       slice prefix. Build them first (this slice has no usable prefix)."
	done

	step "libgit2: configuring ${slice}"
	rm -rf "${work}"
	mkdir -p "${work}"

	# Point zlib and iconv at the SDK explicitly. Left to its own devices, CMake's
	# FindZLIB will hand a build the HOST's zlib — it links, and then fails at the
	# worst possible moment.
	sdk_zlib "${sdk_path}"
	local zlib_lib="${SDK_ZLIB}"

	local iconv_lib=""
	for candidate in "${sdk_path}/usr/lib/libiconv.tbd" "${sdk_path}/usr/lib/libiconv.dylib"; do
		if [ -e "${candidate}" ]; then iconv_lib="${candidate}"; break; fi
	done

	local iconv_args=()
	if [ -n "${iconv_lib}" ]; then
		iconv_args=(-DUSE_ICONV=ON -DIconv_INCLUDE_DIR="${sdk_path}/usr/include" -DIconv_LIBRARY="${iconv_lib}")
	else
		iconv_args=(-DUSE_ICONV=OFF)
	fi

	# `no-pkgconfig`: see the long note below on why libgit2 must not use it.
	local hermetic=()
	while IFS= read -r a; do hermetic+=("${a}"); done < <(hermetic_cmake_args "${prefix}" "${sdk_path}" no-pkgconfig)

	# -DREGEX_BACKEND=builtin, NOT -DUSE_REGEX=builtin. libgit2's cache variable
	# is REGEX_BACKEND (CMakeLists.txt line ~40, consumed by
	# cmake/SelectRegex.cmake). `-DUSE_REGEX=...` is accepted silently by CMake
	# and ignored by libgit2, at which point SelectRegex autodetects: regcomp_l
	# on macOS, plain regcomp on iOS. Both work, neither is what we asked for,
	# and the difference only shows up as a behavioural drift between slices.
	# builtin = libgit2's bundled PCRE2, identical on every platform.
	#
	# -DHAVE_LIBSSH2_MEMORY_CREDENTIALS=1 pre-seeds SelectSSH.cmake's
	# check_library_exists(). That check is a LINK test, and cross-compiled link
	# tests are the flakiest part of an iOS CMake configure. The answer is known:
	# libssh2 1.11.1 with the OpenSSL backend exports
	# libssh2_userauth_publickey_frommemory. It is not a guess — the built
	# archive is checked for that symbol by scripts/verify-no-spawn.sh, which
	# fails the build if it is absent. Without it libgit2 sets no
	# GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS and every key would have to come off
	# disk, which defeats keeping private material in the Keychain.
	#
	# USE_SHA256=OpenSSL, not builtin.
	#
	# libgit2's builtin SHA-256 is deps/rfc6234, whose sha.h declares an enum whose
	# members are named SHA1, SHA224, SHA256, SHA384, SHA512. <openssl/sha.h>
	# declares FUNCTIONS with those names. Any translation unit that sees both fails
	# to compile — here streams/openssl.h reaching libgit2.c:
	#
	#   prefix/include/openssl/sha.h:133:16: error: redefinition of 'SHA512' as a
	#   different kind of symbol
	#
	# USE_SHA256's own default is HTTPS, which under USE_HTTPS=OpenSSL resolves to
	# OpenSSL — so forcing `builtin` was the mistake, and this is a return to
	# libgit2's intended shape rather than a workaround. It is spelled explicitly so
	# the choice is recorded rather than inherited. libcrypto is in this archive
	# unconditionally; a second SHA-256 implementation alongside it is pure weight,
	# and rfc6234 now leaves the build entirely.
	#
	# USE_SHA1 stays CollisionDetection. sha1dc is what git itself uses, and
	# SelectHashes.cmake warns explicitly that any other SHA-1 backend "may leave you
	# and your users susceptible to SHAttered-style attacks". Its symbols are
	# namespaced (SHA1DC*, compiled with SHA1DC_NO_STANDARD_INCLUDES), so it does not
	# collide with OpenSSL. Tidiness is not worth trading a collision-detecting hash
	# for a plain one.
	#
	# Downstream effect, for Sortie 1b: git2_features.h now carries
	# GIT_SHA256_OPENSSL instead of GIT_SHA256_BUILTIN.
	#
	# LINK_WITH_STATIC_LIBRARIES IS DELIBERATELY NOT PASSED. It reads like a
	# statement of intent for a static build, and it was passed here for exactly
	# that reason — which cost two gate runs. cmake/DefaultCFlags.cmake:98 does:
	#
	#     if(NOT BUILD_SHARED_LIBS AND LINK_WITH_STATIC_LIBRARIES)
	#         set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
	#     endif()
	#
	# That narrows find_library() project-wide to archives only, before
	# SelectSSH runs. On modern macOS the SDK's zlib exists solely as
	# libz.tbd, so `z` became unresolvable — while `ssh2` resolved fine,
	# because we do ship a libssh2.a. Its only other effect is appending
	# CMAKE_DL_LIBS in SelectHTTPSBackend, and CMAKE_DL_LIBS is empty on Apple.
	# So the flag buys nothing here and breaks system-library resolution.
	cmake -S "${SRC_DIR}/libgit2" -B "${work}" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_SYSTEM_NAME="${system}" \
		-DCMAKE_OSX_SYSROOT="${sdk_path}" \
		-DCMAKE_OSX_ARCHITECTURES="${arch}" \
		-DCMAKE_OSX_DEPLOYMENT_TARGET="${vmin}" \
		-DCMAKE_C_FLAGS="-target ${SLICE_TRIPLE}" \
		-DCMAKE_PREFIX_PATH="${prefix}" \
		"${hermetic[@]}" \
		-DBUILD_SHARED_LIBS=OFF \
		-DBUILD_TESTS=OFF \
		-DBUILD_CLI=OFF \
		-DBUILD_EXAMPLES=OFF \
		-DBUILD_FUZZERS=OFF \
		-DUSE_THREADS=ON \
		-DUSE_SSH=libssh2 \
		-DUSE_HTTPS=OpenSSL \
		-DUSE_SHA1=CollisionDetection \
		-DUSE_SHA256=OpenSSL \
		-DREGEX_BACKEND=builtin \
		-DUSE_GSSAPI=OFF \
		-DUSE_NTLMCLIENT=OFF \
		-DUSE_BUNDLED_ZLIB=OFF \
		-DHAVE_LIBSSH2_MEMORY_CREDENTIALS=1 \
		-DLIBSSH2_INCLUDE_DIR="${prefix}/include" \
		-DLIBSSH2_LIBRARY="${prefix}/lib/libssh2.a" \
		-DOPENSSL_ROOT_DIR="${prefix}" \
		-DOPENSSL_USE_STATIC_LIBS=ON \
		-DOPENSSL_INCLUDE_DIR="${prefix}/include" \
		-DOPENSSL_CRYPTO_LIBRARY="${prefix}/lib/libcrypto.a" \
		-DOPENSSL_SSL_LIBRARY="${prefix}/lib/libssl.a" \
		-DZLIB_INCLUDE_DIR="${sdk_path}/usr/include" \
		-DZLIB_LIBRARY="${zlib_lib}" \
		"${iconv_args[@]}" \
		> "${work}/configure.log" 2>&1 || {
			tail -60 "${work}/configure.log" >&2
			die "libgit2 cmake configure failed for ${slice} (see ${work}/configure.log)"
		}

	assert_no_host_paths "${work}/CMakeCache.txt" "libgit2 ${slice}"

	# Prove the pkg-config bypass actually engaged, rather than assuming it. If
	# FindPkgLibraries ran at all it prints "Resolved libraries:", and its `z`
	# re-resolution is the failure this build is engineered around.
	if grep -q 'Resolved libraries:' "${work}/configure.log"; then
		die "libgit2 ${slice}: FindPkgLibraries ran — the pkg-config bypass did not
       engage, and libssh2.pc's -l tokens are being re-resolved by name again.
       See README § Hermeticity."
	fi
	local ssh2_resolved
	ssh2_resolved="$(awk '/^LIBSSH2_LIBRARY:/{sub(/^[^=]*=/, ""); print; exit}' "${work}/CMakeCache.txt")"
	[ "${ssh2_resolved}" = "${prefix}/lib/libssh2.a" ] \
		|| die "libgit2 ${slice}: LIBSSH2_LIBRARY resolved to '${ssh2_resolved}', expected ${prefix}/lib/libssh2.a"
	step "libgit2: libssh2 via find_package(LibSSH2), no pkg-config"

	# The generated feature header is the contract. Assert it before spending
	# minutes compiling the wrong library.
	local features="${work}/gen_headers/git2_features.h"
	[ -f "${features}" ] || die "libgit2 did not generate ${features}"
	grep -q '^#define GIT_SSH_LIBSSH2 1'  "${features}" || die "GIT_SSH_LIBSSH2 not set for ${slice} — libssh2 was not detected"
	grep -q '^#define GIT_HTTPS 1'        "${features}" || die "GIT_HTTPS not set for ${slice}"
	grep -q '^#define GIT_OPENSSL 1'      "${features}" || die "GIT_OPENSSL not set for ${slice} — HTTPS backend is not OpenSSL"
	grep -q '^#define GIT_REGEX_BUILTIN 1' "${features}" || die "GIT_REGEX_BUILTIN not set for ${slice} — REGEX_BACKEND did not take"
	grep -q '^#define GIT_SHA1_COLLISIONDETECT 1' "${features}" || die "GIT_SHA1_COLLISIONDETECT not set for ${slice} — sha1dc is what git uses; a plain SHA-1 is SHAttered-susceptible"
	grep -q '^#define GIT_SHA256_OPENSSL 1' "${features}" || die "GIT_SHA256_OPENSSL not set for ${slice} — SHA-256 is not coming from libcrypto"
	if grep -q '^#define GIT_SHA256_BUILTIN 1' "${features}"; then
		die "GIT_SHA256_BUILTIN is set for ${slice}. deps/rfc6234's sha.h declares an
       enum with members SHA1/SHA224/SHA256/SHA384/SHA512 and <openssl/sha.h>
       declares functions of the same names; any TU seeing both fails to compile."
	fi
	if grep -q '^#define GIT_SSH_EXEC' "${features}"; then
		die "GIT_SSH_EXEC IS DEFINED for ${slice}. Refusing to build.
       That transport fork()s and execve()s /usr/bin/ssh, which the sandbox
       blocks and iOS does not ship. See README § Why GIT_SSH_EXEC is off."
	fi
	grep -q '^#define GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS 1' "${features}" \
		|| die "GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS not set for ${slice} — keys could only be loaded from disk"
	step "libgit2: feature header verified for ${slice}"
}

build_libgit2() {
	local slice="$1" system="$2" sdk_path="$3" arch="$4" vmin="$5" prefix="$6"
	local work="${BUILD_DIR}/${slice}/libgit2"

	configure_libgit2 "${slice}" "${system}" "${sdk_path}" "${arch}" "${vmin}" "${prefix}" "${work}"

	step "libgit2: building ${slice}"
	cmake --build "${work}" --parallel "${JOBS}" > "${work}/build.log" 2>&1 || {
		tail -60 "${work}/build.log" >&2
		die "libgit2 build failed for ${slice} (see ${work}/build.log)"
	}

	# Where CMake drops libgit2.a moves between CMake versions, so find it — but
	# `-print -quit` rather than `| head -1`, because find writing into a pipe that
	# head has already closed dies of SIGPIPE and pipefail turns that into a failed
	# build. And copy only if it is not already where we want it: cp refuses to copy
	# a file onto itself and returns 1, which under set -e ends the run one step
	# from success. That is exactly how this script failed the first time libgit2
	# compiled all the way through.
	local found
	found="$(find "${work}" -maxdepth 3 -name 'libgit2.a' -print -quit)"
	[ -n "${found}" ] || die "libgit2.a not found under ${work}"
	if [ "${found}" != "${work}/libgit2.a" ]; then
		cp "${found}" "${work}/libgit2.a"
	fi
	step "libgit2: ${found#"${PKG_ROOT}/"}"
}

merge_and_stage() {
	local slice="$1" arch="$2" prefix="$3"
	local work="${BUILD_DIR}/${slice}"
	local stage="${STAGE_DIR}/${slice}"

	mkdir -p "${stage}/Headers"

	# One archive per xcframework slice: `xcodebuild -create-xcframework
	# -library` takes exactly one library, so libgit2 + libssh2 + libssl +
	# libcrypto have to be merged. Order matters only for readability; ld
	# resolves within an archive regardless.
	step "merging four archives into ${MERGED_LIBRARY_NAME} (${slice})"
	libtool -static -no_warning_for_no_symbols \
		-o "${stage}/${MERGED_LIBRARY_NAME}" \
		"${work}/libgit2/libgit2.a" \
		"${prefix}/lib/libssh2.a" \
		"${prefix}/lib/libssl.a" \
		"${prefix}/lib/libcrypto.a" \
		2> "${work}/libtool.log" || {
			tail -20 "${work}/libtool.log" >&2
			die "libtool -static failed for ${slice}"
		}

	local info
	info="$(lipo -info "${stage}/${MERGED_LIBRARY_NAME}")"
	echo "${info}" | grep -q "${arch}" \
		|| die "${slice}: merged archive is not ${arch} (${info})"

	# Public headers: libgit2's in-source tree, then the CMake-generated
	# additions for THIS slice overlaid on top. k-ymmt's script copies one
	# representative slice's generated headers to all three; that is only safe
	# while nothing platform-conditional is generated, which is not a property
	# worth betting on. Per-slice costs nothing.
	cp "${SRC_DIR}/libgit2/include/git2.h" "${stage}/Headers/git2.h"
	rm -rf "${stage}/Headers/git2"
	cp -R "${SRC_DIR}/libgit2/include/git2" "${stage}/Headers/git2"
	if [ -d "${BUILD_DIR}/${slice}/libgit2/include" ]; then
		(cd "${BUILD_DIR}/${slice}/libgit2/include" && find . -type f) | while read -r rel; do
			mkdir -p "$(dirname "${stage}/Headers/${rel}")"
			cp "${BUILD_DIR}/${slice}/libgit2/include/${rel}" "${stage}/Headers/${rel}"
		done
	fi

	# libssh2's public header, for the runtime libssh2_version() assertion.
	cp "${prefix}/include/libssh2.h" "${stage}/Headers/libssh2.h"

	cp "${SCRIPT_DIR}/module/Clibgit2.h"     "${stage}/Headers/Clibgit2.h"
	cp "${SCRIPT_DIR}/module/module.modulemap" "${stage}/Headers/module.modulemap"

	# Record exactly what went into this slice, next to the slice.
	cat > "${stage}/BUILD-PROVENANCE.txt" <<EOF
slice:    ${slice}
built:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')
libgit2:  ${LIBGIT2_VERSION} (${LIBGIT2_COMMIT})
libssh2:  ${LIBSSH2_VERSION} (${LIBSSH2_COMMIT})
openssl:  ${OPENSSL_VERSION} (sha256 ${OPENSSL_TARBALL_SHA256})
xcode:    $(xcodebuild -version | tr '\n' ' ')
guard:    GUARD_PROCESS_SPAWN=${GUARD_PROCESS_SPAWN}
EOF
}

# ---------------------------------------------------------------------------
# --configure-only
#
# Everything --fetch-only does, plus the libssh2 and libgit2 CMake configures,
# stopping before ninja. Configures do invoke the compiler for their internal
# try-compiles; nothing is built or installed and no install prefix is written.
#
# A slice can only be configured if OpenSSL and libssh2 are already installed
# into its prefix — libgit2's configure resolves both out of it. Slices without a
# prefix are REPORTED AND SKIPPED rather than built, because building them is a
# compile step. Exit status covers the slices that could be checked; skipped
# slices are named so the caller knows what remains unverified.
# ---------------------------------------------------------------------------
if [ "${CONFIGURE_ONLY}" = "1" ]; then
	CONFIGURED=""
	SKIPPED=""
	for entry in "${ALL_SLICES[@]}"; do
		IFS='|' read -r slice system sdk arch _ossl_target vmin <<< "${entry}"
		case " ${SELECTED} " in *" ${slice} "*) ;; *) continue ;; esac

		log "[configure-only] slice ${slice}"
		prepare_slice "${slice}" "${sdk}" "${arch}"
		prefix="${BUILD_DIR}/${slice}/prefix"
		vmin_value="${vmin##*=}"

		if [ ! -f "${prefix}/lib/libcrypto.a" ] || [ ! -f "${prefix}/lib/libssl.a" ] || [ ! -f "${prefix}/lib/libssh2.a" ]; then
			step "SKIPPED: no OpenSSL/libssh2 prefix at ${prefix}"
			step "         building one is a compile step — run the full script for this slice"
			SKIPPED="${SKIPPED} ${slice}"
			continue
		fi

		export PKG_CONFIG_LIBDIR="${prefix}/lib/pkgconfig"
		export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"

		# libssh2 into a scratch tree: its real build dir belongs to the installed
		# artefact, and this mode must not disturb an install.
		configure_libssh2 "${slice}" "${system}" "${SLICE_SDK_PATH}" "${arch}" "${vmin_value}" \
			"${prefix}" "${BUILD_DIR}/${slice}/libssh2-configure-check"
		configure_libgit2 "${slice}" "${system}" "${SLICE_SDK_PATH}" "${arch}" "${vmin_value}" \
			"${prefix}" "${BUILD_DIR}/${slice}/libgit2"
		CONFIGURED="${CONFIGURED} ${slice}"
	done

	log "[configure-only] Result"
	step "configured clean:${CONFIGURED:- none}"
	step "skipped (no prefix):${SKIPPED:- none}"
	if [ -z "${CONFIGURED}" ]; then
		die "no slice could be configured — every selected slice lacks a prefix."
	fi
	log "[configure-only] PASS — nothing compiled past try-compiles, no prefix written"
	exit 0
fi

for entry in "${ALL_SLICES[@]}"; do
	IFS='|' read -r slice system sdk arch ossl_target vmin <<< "${entry}"
	case " ${SELECTED} " in *" ${slice} "*) ;; *) continue ;; esac

	log "[3/7] slice ${slice}"
	prepare_slice "${slice}" "${sdk}" "${arch}"
	sdk_path="${SLICE_SDK_PATH}"
	prefix="${BUILD_DIR}/${slice}/prefix"
	mkdir -p "${prefix}"

	# The version-min value CMake wants is bare (26.0); OpenSSL wants the whole
	# -m...-version-min flag. Strip to the number for CMake.
	vmin_value="${vmin##*=}"

	# Confine pkg-config to this slice's own prefix, for BOTH configures.
	#
	# PKG_CONFIG_LIBDIR *replaces* the default search path rather than prepending
	# to it, which is the only setting strong enough to hide Homebrew. Without it,
	# CMake's FindOpenSSL — invoked by libssh2 — ran pkg_check_modules and found
	# Homebrew's openssl@3 3.6.3; the explicit OPENSSL_* paths meant it was only
	# ever used as a hint and nothing wrong got linked, but a probe that can see a
	# different OpenSSL than the one being linked is a coin toss waiting to be
	# flipped by the next CMake release.
	export PKG_CONFIG_LIBDIR="${prefix}/lib/pkgconfig"
	export PKG_CONFIG_PATH="${prefix}/lib/pkgconfig"

	build_openssl "${slice}" "${sdk_path}" "${arch}" "${ossl_target}" "${vmin}" "${prefix}"
	build_libssh2 "${slice}" "${system}" "${sdk_path}" "${arch}" "${vmin_value}" "${prefix}"
	build_libgit2 "${slice}" "${system}" "${sdk_path}" "${arch}" "${vmin_value}" "${prefix}"
	merge_and_stage "${slice}" "${arch}" "${prefix}"
done

# ---------------------------------------------------------------------------
# [4/7] Assemble the xcframework
# ---------------------------------------------------------------------------
log "[4/7] Assemble ${XCFRAMEWORK_NAME}.xcframework"

mkdir -p "${ARTIFACTS_DIR}"
rm -rf "${XCFRAMEWORK}"

create_args=()
for entry in "${ALL_SLICES[@]}"; do
	IFS='|' read -r slice _ _ _ _ _ <<< "${entry}"
	case " ${SELECTED} " in *" ${slice} "*) ;; *) continue ;; esac
	create_args+=(-library "${STAGE_DIR}/${slice}/${MERGED_LIBRARY_NAME}" -headers "${STAGE_DIR}/${slice}/Headers")
done

xcodebuild -create-xcframework "${create_args[@]}" -output "${XCFRAMEWORK}" >/dev/null
[ -f "${XCFRAMEWORK}/Info.plist" ] || die "xcodebuild produced no Info.plist"
step "slices in ${XCFRAMEWORK##*/}:"
/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "${XCFRAMEWORK}/Info.plist" 2>/dev/null \
	| grep -E 'LibraryIdentifier' | sed 's/^/       /' || true

# ---------------------------------------------------------------------------
# [5/7] Provenance + licence text alongside the artefact
# ---------------------------------------------------------------------------
log "[5/7] Provenance"

cat > "${ARTIFACTS_DIR}/BUILD-PROVENANCE.txt" <<EOF
${XCFRAMEWORK_NAME}.xcframework
built:    $(date -u '+%Y-%m-%dT%H:%M:%SZ')
slices:   ${SELECTED}

libgit2   ${LIBGIT2_VERSION}   ${LIBGIT2_TAG}   ${LIBGIT2_COMMIT}
libssh2   ${LIBSSH2_VERSION}   ${LIBSSH2_TAG}   ${LIBSSH2_COMMIT}
OpenSSL   ${OPENSSL_VERSION}   sha256 ${OPENSSL_TARBALL_SHA256}

libgit2 cmake:   USE_SSH=libssh2 USE_HTTPS=OpenSSL USE_SHA1=CollisionDetection
                 USE_SHA256=OpenSSL REGEX_BACKEND=builtin USE_GSSAPI=OFF
                 USE_NTLMCLIENT=OFF BUILD_CLI=OFF BUILD_TESTS=OFF
libssh2 cmake:   CRYPTO_BACKEND=OpenSSL ENABLE_ZLIB_COMPRESSION=OFF
openssl config:  no-shared no-async no-tests no-apps no-docs no-engine no-comp
                 no-ssl3 no-ssl3-method no-weak-ssl-ciphers

GIT_SSH_EXEC:    not defined (guard applied: ${GUARD_PROCESS_SPAWN})
xcode:           $(xcodebuild -version | tr '\n' ' ')
EOF
step "wrote ${ARTIFACTS_DIR##*/}/BUILD-PROVENANCE.txt"

# ---------------------------------------------------------------------------
# [6/7] Optional code signature
#
# A static-library xcframework carries no bundle, so it carries no privacy
# manifest either: Apple reads PrivacyInfo.xcprivacy out of an SDK bundle, and
# there is nothing here to put one in. The required-reason API declarations for
# libgit2/OpenSSL therefore have to live in the APP's own manifest — that is
# Sortie 14's job, and README § ITMS-91061 spells out which keys.
# Signing is still available for consumers who want the xcframework signed.
# ---------------------------------------------------------------------------
log "[6/7] Signature"
if [ -n "${SIGN_IDENTITY:-}" ]; then
	codesign --timestamp -s "${SIGN_IDENTITY}" "${XCFRAMEWORK}"
	step "signed with '${SIGN_IDENTITY}'"
else
	step "unsigned (set SIGN_IDENTITY to sign) — see README § ITMS-91061"
fi

# ---------------------------------------------------------------------------
# [7/7] Verification gate
# ---------------------------------------------------------------------------
log "[7/7] Verification"
# Written without an array on purpose: macOS ships bash 3.2, where expanding an
# empty array under `set -u` is an "unbound variable" error.
if [ "${GUARD_PROCESS_SPAWN}" = "1" ]; then
	"${SCRIPT_DIR}/verify-no-spawn.sh"
else
	"${SCRIPT_DIR}/verify-no-spawn.sh" --allow-unreferenced-process
fi

if [ "${KEEP_BUILD}" = "0" ]; then
	log "Cleaning intermediates (pass --keep-build to retain them)"
	rm -rf "${BUILD_DIR}"
fi

log "Success"
du -sh "${XCFRAMEWORK}"
