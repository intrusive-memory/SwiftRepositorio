---
type: doc
package: SwiftRepositorio
state: current
updated: 2026-08-10
---

# SwiftRepositorio

A Swift face over libgit2, and the one place that owns the libgit2 + libssh2 +
OpenSSL xcframework and its CVE duty.

The Swift API is not written yet. What exists today is the binary target and the
build pipeline that produces it — the part nobody else ships, and the part that
decides whether the rest is possible at all.

## Status

| Piece | State |
|---|---|
| `scripts/build-xcframework.sh` — three-slice xcframework from pinned source | **exits 0 end-to-end for all three slices**; 40 MB `artifacts/Clibgit2.xcframework` assembled |
| `scripts/verify-no-spawn.sh` — the no-spawn / no-ucontext gate | **PASS, 6 targets, 0 failures**; also self-tested against positive and negative controls |
| `--fetch-only` pre-gate | passes clean for all three slices, including cold download, checksum rejection and re-extract |
| `--configure-only` pre-gate | libgit2 + libssh2 configure clean; all three slices verified |
| `Package.swift` + `Sources/` | `Clibgit2` binary target + the public build-shape surface (`libgit2Version`, `libssh2Version`, `enabledFeatures`) |
| `Makefile` — `build` / `test` / `lint` + pipeline wrappers | present; all three exit 0 |
| `Tests/` — 12 tests, 2 suites | pass; every assertion reads the linked binary |
| `LICENSES.md` | present — **read § LibXDiff is LGPL-2.1** |
| `.github/workflows/` | `tests.yml` (xcframework from scratch, then `make test`), `lint.yml` |

`swift build` fails until the xcframework exists. That is correct behaviour, not
a bug: run `scripts/build-xcframework.sh` first. There is no committed binary and
there will not be one.

Note that a default run deletes `build/` on success, including the per-slice
install prefixes and their stamps. There is therefore no cross-run caching: every
clean run rebuilds OpenSSL for all three slices, which is most of the 15-25
minutes. Pass `--keep-build` to retain the trees for `nm` work and to make a
re-run cheap.

## Build it

### Prerequisites

| Tool | Source | Required? |
|---|---|---|
| `cmake` | `brew install cmake` | **yes** — libgit2 and libssh2 are both CMake projects |
| `ninja` | `brew install ninja` | **yes** — the script configures with `-G Ninja` |
| `pkg-config` | `brew install pkg-config` | optional. libgit2 is deliberately denied it (§ Hermeticity); libssh2 uses it only for `FindOpenSSL` hints, and works without it |
| `xcodebuild` `xcrun` `lipo` `libtool` `nm` `perl` `make` `git` `curl` `shasum` | Xcode / macOS | already present |

The script preflights all of these and names the one that is missing. Homebrew's
`cmake` / `ninja` / `pkg-config` **executables** are expected and fine; what the
build refuses is Homebrew *libraries and headers* — see § Hermeticity.

Everything runs through `make` (Standing Order 1) — CI calls the same targets:

```sh
make fetch-only        # seconds: fetch + checksum + extract, no compiler
make configure-only    # + both CMake configures, stopping before ninja
make xcframework       # ~20-25 min cold, all three slices, ends with the gate
make verify-no-spawn   # the symbol gate on its own

make build             # macOS arm64
make build-ios         # proves the iOS device slice links
make test              # 12 tests, 2 suites
make lint              # SwiftLint, read-only
make help              # every target
```

`make build`, `test` and `lint` all need `artifacts/Clibgit2.xcframework`; a
fresh checkout has none, and the Makefile says so with instructions rather than
letting SwiftPM emit a wall of text about a missing artifact.

Useful knobs: `SLICES="macos-arm64"` to build one slice, `--keep-build` to keep
the CMake trees so `nm` has something to look at, `JOBS=N`, `SIGN_IDENTITY=...`.

### `--fetch-only` — run this first

Runs preflight, source fetch, checksum verification, extraction, the
`GIT_SSH_EXEC` guard, and every per-slice SDK / target-triple / zlib / iconv
resolution, then exits 0 **before the first compiler invocation**. It touches
nothing under any install prefix, so it is safe to run against a half-finished
build tree.

It exists because a fetch-stage mistake and a compile-stage mistake are
indistinguishable when both cost twenty minutes to reach. Everything it checks is
cheap and none of it needs a compiler, so there is no reason to discover a bad
path, a mis-quoted argument or a missing SDK stub any later than this. The real
build calls the same `prepare_slice` and `unpack_openssl_source` functions, so
this is the actual code path and not a rehearsal of it.

### `--configure-only` — the second pre-gate

Everything `--fetch-only` does, plus the libssh2 and libgit2 CMake configures,
stopping before ninja. Configures do run the compiler for their own try-compiles;
nothing is built or installed, and no install prefix is written.

A slice can only be configured once OpenSSL and libssh2 are installed into its
prefix, because libgit2's configure resolves both out of it. Slices without a
prefix are **reported and skipped**, never built — building one is a compile step.
The summary names what was configured and what was skipped, so an exit code of 0
is never mistaken for "all three verified":

```
-- configured clean: macos-arm64
-- skipped (no prefix): ios-arm64 ios-arm64-simulator
```

This is where every backend decision is actually checked: the host-prefix scan,
the pkg-config bypass assertion, and all seven `git2_features.h` assertions run
here, at configure time, rather than after a twenty-minute compile.

**Re-running is safe.** Each slice's install prefix is stamped with
`RECIPE_REVISION` (`scripts/versions.sh`) plus the target triple and the source
checksum; a prefix that does not match is rebuilt rather than reused, the libgit2
tree is rebuilt every time, and a source directory left behind by an earlier
fetch strategy is detected and replaced. Bump `RECIPE_REVISION` whenever a
configure flag changes — silently reusing an install produced by an unknown
recipe is exactly what the stamps exist to prevent.

## What gets built

Three slices, arm64 only in each — `macos-arm64`, `ios-arm64`,
`ios-arm64-simulator`. Only macOS is linked by Escribir today; the iOS slices are
cheap and keep the package platform-honest.

Each slice is one static archive, `libClibgit2.a`, containing four libraries
merged with `libtool -static`:

| Library | Version | Pin | Licence |
|---|---|---|---|
| libgit2 | 1.9.6 | git tag `v1.9.6`, commit `26055f5af74ab1cf636d272e8a34315496d3f06f` | **GPLv2 WITH a linking exception** |
| libssh2 | 1.11.1 | release tarball, sha256 `d9ec76cb…58f7` | BSD-3-Clause |
| OpenSSL | 3.5.7 | release tarball, sha256 `a8c0d28a…c98e8` | Apache-2.0 |

Everything is declared in `scripts/versions.sh` and nowhere else.

**Pinning strategy.** libgit2 is pinned by tag *and* by the commit SHA that tag
must resolve to: the build clones the tag and then asserts `git rev-parse HEAD`.
GitHub's *auto-generated* source archives are not byte-stable across git
versions, so a checksum over one of those would be a pin that rots; a commit SHA
cannot. libssh2 and OpenSSL are pinned by their release tarballs — uploaded,
immutable release assets rather than generated archives — plus a sha256.

### Why libssh2 comes from the tarball, not the tag

This one is not a style preference. libssh2 tags the release commit *before*
stripping the in-development suffix from its header. At tag `libssh2-1.11.1`
(commit `a312b43…`, confirmed by `git describe`), `include/libssh2.h` reads:

```c
#define LIBSSH2_VERSION      "1.11.1_DEV"
#define LIBSSH2_VERSION_NUM  0x010b01
```

The numeric macro is correct; the string is not. libssh2's CMake parses that
string, so a tag-based build produces `Version: 1.11.1_DEV` in `libssh2.pc` and —
the part that actually matters — makes **`libssh2_version()` return
`"1.11.1_DEV"` at runtime**. Sortie 1b's exit criterion is a runtime assertion
that the linked libssh2 is ≥ 1.11.0, and that assertion must not have to
special-case a suffix.

The release tarball carries a clean `"1.11.1"` and ships the complete CMake
build. Patching the version string in a tag-based tree was the alternative and
was rejected: editing a library's self-reported version is precisely how a build
starts lying about itself, which is the failure mode this package exists to
prevent. libssh2 publishes no `.sha256` asset, so the checksum in `versions.sh`
was computed from the official GitHub release asset, whose detached signature is
by the libssh2/curl release key `27EDEAF2…B71E12C2`.

The build asserts both the header version and the generated `.pc` version, so a
future change that re-points this at the tag fails immediately rather than in
Sortie 1b's tests.

## The build, decision by decision

### libgit2 cmake

```
USE_SSH=libssh2          USE_HTTPS=OpenSSL         REGEX_BACKEND=builtin
USE_SHA1=CollisionDetection                        USE_SHA256=OpenSSL
USE_GSSAPI=OFF           USE_NTLMCLIENT=OFF        USE_BUNDLED_ZLIB=OFF
BUILD_SHARED_LIBS=OFF    BUILD_TESTS=OFF           BUILD_CLI=OFF

LINK_WITH_STATIC_LIBRARIES is deliberately NOT passed — see § Hermeticity.
```

### Why `REGEX_BACKEND=builtin` — and why the option is not called `USE_REGEX`

**libgit2 has no `USE_REGEX` option.** The cache variable is `REGEX_BACKEND`
(`CMakeLists.txt` line ~40, consumed by `cmake/SelectRegex.cmake`). Passing
`-DUSE_REGEX=builtin` is accepted silently by CMake and ignored by libgit2, at
which point `SelectRegex.cmake` autodetects — and it does not pick PCRE:
`regcomp_l` on macOS, plain `regcomp` on iOS, because the file explicitly
special-cases iOS (`# 'regcomp_l' has been explicitly marked unavailable on
iOS_SDK`). So the received wisdom that "libgit2 wants libpcre, which the iOS SDK
lacks, and that is why SwiftGit2 never compiled for iOS" is not what the 1.9.6
source says.

`builtin` is still the right answer, for a better reason: it is libgit2's bundled
PCRE2, identical on every slice. Regex behaviour is load-bearing for `.gitignore`
and `.gitattributes` matching, and having macOS use `regcomp_l` while iOS uses
`regcomp` is a behavioural difference between slices that would surface as an
irreproducible bug rather than a build error. The build script asserts
`GIT_REGEX_BUILTIN 1` in the generated feature header, so a typo'd flag fails the
build instead of quietly changing the engine.

### Why SHA-256 comes from OpenSSL and SHA-1 does not

`USE_SHA256=OpenSSL`, `USE_SHA1=CollisionDetection`.

libgit2's builtin SHA-256 is `deps/rfc6234`, whose `sha.h` declares an enum whose
members are named `SHA1, SHA224, SHA256, SHA384, SHA512`. `<openssl/sha.h>`
declares *functions* with those names. Any translation unit that sees both fails
to compile, and with `USE_HTTPS=OpenSSL` one does — `streams/openssl.h` reaches
`libgit2.c`:

```
prefix/include/openssl/sha.h:133:16: error: redefinition of 'SHA512'
as a different kind of symbol
```

`USE_SHA256`'s own default is `HTTPS`, which under `USE_HTTPS=OpenSSL` resolves to
`OpenSSL`, so forcing `builtin` was the mistake and this is a return to libgit2's
intended shape rather than a workaround. It is spelled out explicitly so the
choice is recorded rather than inherited. libcrypto is in this archive
unconditionally; a second SHA-256 implementation beside it is pure weight, and
`rfc6234` now leaves the build entirely.

**SHA-1 stays on sha1dc**, and that is not symmetry for its own sake.
`SelectHashes.cmake` warns that any other SHA-1 backend "may leave you and your
users susceptible to SHAttered-style attacks" — sha1dc is the collision-detecting
hash git itself uses, and git object identity depends on it. Its symbols are
namespaced (`SHA1DC*`, compiled with `SHA1DC_NO_STANDARD_INCLUDES`) so it does not
collide with OpenSSL. Consistency is not worth trading a collision-detecting hash
for a plain one.

**Note for Sortie 1b**: `git2_features.h` carries `GIT_SHA256_OPENSSL`, not
`GIT_SHA256_BUILTIN`. `git_libgit2_features()` itself is unaffected — the feature
bitmask reports threads/HTTPS/SSH/nsec, not the hash backend — so the
`enabledFeatures` tests are unchanged. Both facts are asserted by
`verify-no-spawn.sh` check D.

### Why `GIT_SSH_EXEC` is off

libgit2 1.8+ ships a second SSH transport that shells out to the `ssh` binary:
`src/libgit2/transports/ssh_exec.c` calls `git_process_start`, which
`fork()`s and `execve()`s. The iOS sandbox blocks `fork` at the syscall and iOS
ships no `ssh` binary, so enabling it produces a library that builds, links, and
fails silently at runtime — the worst available failure mode. Every currently
maintained SPM libgit2 package defines it by default, so turning it off is a
deliberate act. `USE_SSH=libssh2` leaves it undefined; the build script asserts
that `GIT_SSH_EXEC` is absent from `git2_features.h` before it spends a minute
compiling.

**A correction to the plan of record, verified against 1.9.6 source.** The plan
assumed `process.o` would simply not be compiled with the exec transport off. It
is compiled regardless: `src/util/CMakeLists.txt` does
`file(GLOB UTIL_SRC_OS unix/*.c unix/*.h)`, and `unix/process.c` carries no
`#ifdef` — raw `fork()` at line ~374 and `execve()` at line ~409 land in
`libgit2.a` every time, on every Apple platform.

What *is* true is the reachability claim. `git_process_start` and friends are
referenced only by `ssh_exec.c` (wholly inside `#ifdef GIT_SSH_EXEC`),
`src/cli/cmd_commit.c` (`BUILD_CLI=OFF`), and the test suite
(`BUILD_TESTS=OFF`). `ssh_libssh2.c` does include `process.h`, but only for
`git_process__is_cmdline_option()`, which is a `GIT_INLINE` in the header and so
creates no link dependency. The member is dead weight a linker will not pull into
an app.

"Dead but present" is not what the exit criterion asks for and not what we want
to hand a static analyser, so the build script performs one scripted,
idempotent source transform: `unix/process.c` moves to
`unix/process_spawn_impl.h` (CMake adds headers to `target_sources` but never
compiles them) and the `.c` becomes a stub that includes it only under
`#ifdef GIT_SSH_EXEC`. The symbols become physically absent. If some future
libgit2 genuinely needs `git_process_start` on the libssh2 path, the link fails
loudly instead of quietly reaching for a binary iOS does not have. Set
`GUARD_PROCESS_SPAWN=0` to build stock upstream, in which case run the gate with
`--allow-unreferenced-process` and it will verify the weaker property instead:
the symbols appear only in `process.o`, and nothing references
`_git_process_start`.

The transform is guarded by a sentinel comment and by two assertions (the file
must exist; it must still call `execve`), so a version bump that changes this
area fails loudly rather than silently doing nothing.

### Why OpenSSL is configured with `no-async`

`crypto/async/arch/async_posix.c` uses `getcontext` / `makecontext` /
`setcontext`. Apple's upload validator treats those as non-public symbol usage —
this is **ITMS-90338**, with a decade of history (openssl#2545, openssl#7318).
`no-async` removes them at configure time.

Two details worth knowing. First, OpenSSL's own iOS targets already disable it:
`Configurations/15-ios.conf` gives `ios-common` a `disable => [ "async" ]`, so
the iOS slices would be clean without us. The **macOS** target
(`darwin64-arm64`) does not, and macOS is the slice Escribir actually ships — so
this flag is doing real work, not ceremony. Second, the script does not trust the
flag: it greps `include/openssl/configuration.h` for `OPENSSL_NO_ASYNC` after
configuring and refuses to build without it, and `verify-no-spawn.sh` re-checks
the finished archive for the four `*context` symbols.

Deliberately **not** passed: `no-legacy` (the legacy provider is what reads old
PEM private keys — the primary credential in this product is an existing
`~/.ssh/id_rsa` that may well be legacy PEM, and breaking that to save a few
hundred kilobytes would reproduce exactly the "looks like a bad key"
misdiagnosis this package exists to prevent) and `no-deprecated` (libssh2 still
calls OpenSSL 1.1-era APIs).

### Why the OpenSSL build is from source, and not `krzyzanowskim/OpenSSL`

The plan told this sortie to seriously evaluate consuming
`krzyzanowskim/OpenSSL`'s signed XCFramework instead of building OpenSSL, on the
strength of its per-slice `PrivacyInfo.xcprivacy` (the ITMS-91061 mitigation).
Verified against that repository at release 3.6.3000 (2026-07-30), it cannot
serve this build, for three independent reasons — any one of which is
disqualifying:

1. **It is not configured with `no-async`.** `scripts/build.sh` configures every
   platform with exactly `no-asm no-shared no-tests`. Its iOS slices inherit
   `disable => ["async"]` from OpenSSL's own iOS target, but its **macOS** slice
   does not — and macOS is the slice that ships. Adopting it would mean
   abandoning obligation (a) of decision D-6 to gain obligation (b). The two
   mitigations are not interchangeable; ITMS-90338 and ITMS-91061 are different
   checks.
2. **The headers are namespace-rewritten.** The build rewrites every
   `#include <openssl/…>` to `#include <OpenSSL/…>`, concatenates per-arch
   `opensslconf.h` behind `#if defined(__arm64__)` blocks, and adds a `shim.h`.
   libgit2 and libssh2 both compile against `<openssl/evp.h>` and expect a
   `include/openssl/` + `lib/libcrypto.a` layout for CMake's `FindOpenSSL`.
   Feeding this to them means un-rewriting their headers — a patch on a patch.
3. **It ships a dynamic framework, not a static archive.** `Project.swift`
   declares `product: .framework` with `-Xlinker -all_load`,
   `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` and dSYMs. Static libgit2/libssh2 linked
   against it would leave the app embedding and signing a separate OpenSSL
   framework, and this package's version pin would become whatever Krzyżanowski
   released last.

So: OpenSSL is built from source, with `no-async`, and ITMS-91061 is handled in
the app's own privacy manifest — see below.

### ITMS-91061, honestly

A static-library xcframework has no bundle, so it cannot carry a privacy
manifest: Apple reads `PrivacyInfo.xcprivacy` out of an SDK bundle, and there is
nothing here to put one in. Faking one inside `Clibgit2.xcframework` would be
theatre. The required-reason API declarations therefore have to live in the
**app's** manifest, which is Sortie 14's task, and this remains — in the plan's
own words — an unproven mitigation rather than a fix. Only an actual App Store
Connect upload settles it.

One thing the recheck turned up that the plan does not account for: there is a
dated (September 2025) developer report of an app rejected for *non-public
symbols* named `_BIO_s_socket` and `_OPENSSL_cleanse`, from statically linked
OpenSSL — Apple's scanner appears to flag OpenSSL symbol names that collide with
its own internal BoringSSL. That is a third, distinct OpenSSL risk alongside
ITMS-91061 and ITMS-90338, and neither `no-async` nor a privacy manifest
addresses it. See `docs/UNVERIFIED-recheck.md` § Finding 3.

### The trust store problem

With `USE_HTTPS=OpenSSL`, certificate verification uses OpenSSL's trust store,
and OpenSSL looks for one at its compiled-in `OPENSSLDIR`. A sandboxed app has no
such directory, so `SSL_CTX_set_default_verify_paths()` finds nothing and HTTPS
clones fail with a certificate error that has nothing to do with the network.

This is a real consequence of choosing OpenSSL over SecureTransport and it is not
solved here. Baking a CA bundle into this xcframework would quietly make this
package the owner of a root certificate store, which is a bad trade. The two
sane options both belong to the sorties that open connections: point libgit2 at a
shipped bundle via `GIT_OPT_SET_SSL_CERT_LOCATIONS`, or validate in libgit2's
`certificate_check` callback using Security.framework. Recording it here so it is
not discovered during the first clone attempt.

### Hermeticity — and the `could not resolve z` failure

Two consecutive gate runs died at the libgit2 configure with:

```
CMake Error at cmake/FindPkgLibraries.cmake:17 (message):
  could not resolve z
```

Worth writing down, because the first fix was aimed at the wrong thing.

libgit2's `SelectSSH.cmake` reads `libssh2.pc`, and `cmake/FindPkgLibraries.cmake`
then takes every `-l` token out of it — `ssh2`, `crypto`, `z` — and *re-resolves
each one by name* with `find_library()`. `-lz` is in that file because libssh2's
OpenSSL branch calls `find_package(ZLIB)` unconditionally (`CMakeLists.txt` ~line
336) and appends the result to `LIBSSH2_LIBS`; `ENABLE_ZLIB_COMPRESSION=OFF` turns
off SSH-level compression, not that link.

The first fix assumed a search-path problem and pointed `CMAKE_LIBRARY_PATH` at
the prefix and the SDK. The cache showed that half-worked, and named the real
cause:

```
ssh2_RESOLVED:FILEPATH=…/build/macos-arm64/prefix/lib/libssh2.a
z_RESOLVED:FILEPATH=z_RESOLVED-NOTFOUND
```

`ssh2` resolving out of the prefix is reachable *only* via `CMAKE_LIBRARY_PATH`,
so the paths were never the problem. What differs between the two names is the
file extension — and `cmake/DefaultCFlags.cmake:98` does this:

```cmake
if(NOT BUILD_SHARED_LIBS AND LINK_WITH_STATIC_LIBRARIES)
    set(CMAKE_FIND_LIBRARY_SUFFIXES ".a")
endif()
```

We were passing `-DLINK_WITH_STATIC_LIBRARIES=ON` as a statement of intent for a
static build. It narrows `find_library` project-wide to archives only, before
`SelectSSH` runs. We ship a `libssh2.a`, so `ssh2` resolved; the SDK's zlib exists
**only** as `libz.tbd` — there is no `/usr/lib/libz.dylib` on disk any more, the
dylib lives in the dyld shared cache — so `z` could not. The flag's only other
effect is appending `CMAKE_DL_LIBS` in `SelectHTTPSBackend`, and `CMAKE_DL_LIBS`
is empty on Apple. It bought nothing and broke system-library resolution, so it
is gone.

**libgit2 is also now denied pkg-config entirely**, which is the durable half of
the fix. `PKG_CONFIG_EXECUTABLE` is pre-seeded with a path that cannot exist, so
`FindPkgConfig` skips its `find_program`, `pkg_check_modules` fails cleanly, and
`SelectSSH` falls through to `find_package(LibSSH2)` — whose `FindLibSSH2.cmake`
wants exactly the `LIBSSH2_INCLUDE_DIR` and `LIBSSH2_LIBRARY` this build already
passes.

That deletes the re-resolution step instead of accommodating it. It was the only
thing in this build that ever searched for a system library by name, and it was
pure downside: every dependency is already handed to libgit2 as an absolute path
(`LIBSSH2_LIBRARY`, `OPENSSL_*_LIBRARY`, `ZLIB_LIBRARY`, `Iconv_LIBRARY`), and a
pre-seeded cache entry makes `find_library` a no-op whatever the suffix rules say.

Verified equivalent rather than merely passing: the generated `git2_features.h` is
identical to what the pkg-config path produced (`GIT_SSH_LIBSSH2`,
`GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS`, `GIT_HTTPS`, `GIT_OPENSSL`,
`GIT_REGEX_BUILTIN`, `GIT_USE_ICONV`, `GIT_SHA1_COLLISIONDETECT`,
`GIT_SHA256_BUILTIN`, no `GIT_SSH_EXEC`), every dependency resolves inside the
prefix or the SDK, and no `-I` on any compile line points at a host prefix. The
configure asserts the bypass engaged — if `FindPkgLibraries` ever runs again the
build fails and says so, rather than silently going back to re-resolving names.

libssh2's own configure keeps pkg-config: it uses it only for `FindOpenSSL` hints,
and `PKG_CONFIG_LIBDIR` confines it to the slice's prefix.

The same failing run also resolved `PCRE_LIBRARY` to
`/opt/homebrew/lib/libpcre.a`. That one was harmless — `REGEX_BACKEND=builtin`
means libgit2 never consults it — but it proved the configure was searching this
machine's Homebrew tree, and a Homebrew zlib or OpenSSL substituting itself for
the SDK's is a failure that *links*, works on the machine that built it, and
cannot be reproduced on CI.

So the build is also explicit about where libraries may come from:

- **`CMAKE_LIBRARY_PATH` / `CMAKE_INCLUDE_PATH`** = this slice's prefix first,
  then the slice's SDK. Both are searched *ahead* of the `PATHS` given inside a
  `find_library()` call, which is what makes `z` resolve to the SDK's `.tbd`
  (`CMAKE_FIND_LIBRARY_SUFFIXES` on Apple is `.tbd;.dylib;.so;.a`) and `crypto`
  and `ssh2` resolve to ours.
- **`CMAKE_IGNORE_PREFIX_PATH` / `CMAKE_IGNORE_PATH`** exclude `/opt/homebrew`,
  `/usr/local`, `/opt/local` and `/sw`. CMake puts the Homebrew prefix on its
  default search path on Apple Silicon; this takes it off.
- **`ZLIB_LIBRARY` / `ZLIB_INCLUDE_DIR`** passed explicitly to *both* libssh2 and
  libgit2, pointing into the slice's SDK.
- **`PKG_CONFIG_LIBDIR`** set per slice to the prefix's own `pkgconfig` directory.
  It *replaces* pkg-config's default search path rather than prepending to it —
  the only setting strong enough to hide Homebrew. Without it, CMake's
  `FindOpenSSL` (invoked by libssh2) ran `pkg_check_modules` and found Homebrew's
  `openssl@3` 3.6.3. The explicit `OPENSSL_*` paths meant it was used only as a
  hint and nothing wrong was linked — but a probe that can see a different
  OpenSSL than the one being linked is a coin toss waiting to be flipped by a
  CMake release.
- **The environment is scrubbed** at the top of the script (`CMAKE_PREFIX_PATH`,
  `PKG_CONFIG_PATH`, `CFLAGS`, `SDKROOT`, `OPENSSL_ROOT_DIR`, and the rest).
  `find_*` reads all of them, and each is a route to the same failure.
- **`CMAKE_MAKE_PROGRAM` and `PKG_CONFIG_EXECUTABLE`** are passed explicitly, so
  the ignore list never has to be careful about `/opt/homebrew/bin`. Tools come
  from the host; libraries do not.

Prevention is not proof, so after each configure the script reads
`CMakeCache.txt` and **fails the build** if any resolved library, include or
link directory sits under a host prefix. Two exclusions, both deliberate:
`*_EXECUTABLE`-style entries are not examined at all, and `INTERNAL` keys
beginning with an underscore are skipped because they are pkg-config's scratch
namespace (`_OPENSSL_LDFLAGS` and friends) recording what pkg-config *saw*
rather than what the build *uses*. Failing on those would fail a correct build,
and an assertion that cries wolf gets an `|| true` bolted onto it within a week.

### Smaller choices

- **`USE_GSSAPI=OFF`** — `GSS.framework` does not exist on iOS, and libgit2's
  default detection finds it on macOS, which would make the two slices differ.
- **`USE_NTLMCLIENT=OFF`** — defaults ON whenever HTTPS is on. GitHub does not
  need NTLM; this is attack surface with no user.
- **`USE_SHA1=CollisionDetection`** — the sha1dc implementation git itself uses.
- **`USE_BUNDLED_ZLIB=OFF`** with `ZLIB_LIBRARY` pointed explicitly at the
  slice's SDK — see § Hermeticity. The bundled copy was rejected because it would
  put a second set of `inflate` / `deflate` symbols inside our archive, next to
  the app's system libz.
- **`ENABLE_ZLIB_COMPRESSION=OFF`** for libssh2 — GitHub does not negotiate SSH
  compression. Note this does *not* remove zlib from libssh2's link interface;
  see § Hermeticity.
- **`HAVE_LIBSSH2_MEMORY_CREDENTIALS=1`** pre-seeded. `SelectSSH.cmake` probes
  for it with `check_library_exists`, which is a *link* test, and cross-compiled
  link tests are the flakiest part of an iOS CMake configure. The answer is known
  for libssh2 1.11.1 + OpenSSL, and it is not taken on faith: the gate fails the
  build if `_libssh2_userauth_publickey_frommemory` is missing from the archive.
  Without it libgit2 defines no `GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS` and every
  private key must come off disk, which defeats keeping key material in the
  Keychain.

### The module surface

`scripts/module/Clibgit2.h` and `scripts/module/module.modulemap` are committed
and copied verbatim into every slice. The module exposes `git2.h` and
`libssh2.h` — the latter for exactly one reason: the assertion that the *linked*
libssh2 is ≥ 1.11.0 must read `libssh2_version()` from the library, never from
the build script, because the build script is the thing that would be wrong.

The `git2/sys/*.h` headers ship in the slice but are not included by the umbrella;
adding one is a deliberate edit to a committed header. OpenSSL headers are not
shipped at all — the crypto backend is an implementation detail, and exposing
`<openssl/*.h>` to Swift would mean a future backend swap has to renegotiate this
package's public surface.

## The gate

`scripts/verify-no-spawn.sh` (to be wired as `make verify-no-spawn` in Sortie 1b)
runs `nm -m` over every slice and makes four assertions:

| | Assertion | Why |
|---|---|---|
| A | no `_fork` / `_vfork` / `_exec*` / `_posix_spawn*` | the exec-ssh transport must not be linked |
| B | no `_getcontext` / `_makecontext` / `_setcontext` / `_swapcontext` | ITMS-90338; proves `no-async` took |
| C | `_git_libgit2_init`, `_libssh2_version`, `_libssh2_userauth_publickey_frommemory`, `_SSL_CTX_new` **are** present | absence of the bad thing is not presence of the good thing |
| D | `git2_features.h` says `GIT_OPENSSL`, `GIT_SSH_LIBSSH2`, `GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS`, `GIT_REGEX_BUILTIN`; not `GIT_SSH_EXEC`, not `GIT_GSSAPI` | catches a `-D` flag CMake accepted and ignored |

The build script adds four more assertions inline, where they are cheap and fail
early: the libssh2 header and `.pc` version strings (§ Why libssh2 comes from the
tarball), `OPENSSL_NO_ASYNC` in OpenSSL's generated `configuration.h`, the same
feature-header checks as D above, and the host-prefix scan of every
`CMakeCache.txt` (§ Hermeticity).

It has been exercised against a purpose-built archive containing `fork`,
`execve` and `getcontext` (detected), the same archive in relaxed mode
(tolerated as unreferenced), and a variant where another object references
`git_process_start` (correctly refused). Check D is skipped when `build/` has
been cleaned; the same assertions run inline during the build.

## The Swift surface

Small on purpose — the API for repositories, clones and commits belongs to later
sorties. What exists is the answer to "what actually got linked":

```swift
SwiftRepositorio.libgit2Version        // Version, from git_libgit2_version()
SwiftRepositorio.libssh2Version        // Version?, from libssh2_version()
SwiftRepositorio.enabledFeatures       // Features, git_libgit2_features() decoded
SwiftRepositorio.minimumLibssh2Version // the 1.11.0 floor, and why
SwiftRepositorio.buildDescription      // one line naming everything linked
SwiftRepositorio.PinnedVersions        // what the build script was TOLD
```

The split between the first four and `PinnedVersions` is the whole design. The
first four read the binary; `PinnedVersions` records the recipe. A test that
compares the recipe against itself cannot fail for the reason that matters, and
this package has already produced the failure that proves it: libssh2's git tag
reports `1.11.1_DEV` while its release tarball reports `1.11.1`, and only the
library can say which one is in the binary. `.swiftlint.yml` has a custom rule
that errors on `PinnedVersions.x == PinnedVersions.y` for that reason.

`Version` is `Comparable` and ignores packaging suffixes, so the libssh2 floor is
asserted by comparison rather than string matching — `1.10.0 < 1.11.0` is a
numeric fact, and a lexical compare gets it backwards.

## Tests

12 tests in 2 suites (swift-testing, matching the collection's convention).
They assert; none of them skips. `make test`:

- HTTPS is present in `enabledFeatures`
- SSH is present in `enabledFeatures`
- the **linked** libssh2 is ≥ 1.11.0, read from `libssh2_version()` at runtime
- the linked libssh2 is a *release* build — no `_DEV` suffix, which is the
  tag-versus-tarball trap and is invisible to the floor test above, since
  `1.11.1_DEV` satisfies the floor perfectly well
- the linked libgit2 matches the pinned 1.9.6
- threads, regex and an HTTP parser are present
- NTLM and Negotiate are **absent**, as configured — a backend that switched
  itself back on is a change in the shipped binary's shape
- `Version` parsing and ordering, including the inputs a correct build never
  produces

## Licences

Full inventory in `LICENSES.md`, each entry verified against the source file that
states it. The situation in brief:

- **libgit2 — GPLv2 with a linking exception.** The exception is what permits
  static linking into a closed-source App Store binary, and it is the reason any
  of this is viable. It must be re-confirmed on every version bump, not assumed.
  The exception covers linking; it does not cover modifying libgit2 and
  distributing the modification without source. The `process.c` transform above
  is a build-time change to GPLv2 code, so the transform itself stays in this
  repository, in the open, where the licence expects it.
- **OpenSSL 3.x — Apache-2.0.** Attribution, no copyleft. Also the only
  component here on Apple's third-party-SDK list.
- **libssh2 — BSD-3-Clause.** Attribution.
- **PCRE2** (BSD-3-Clause with a binary-redistribution exemption), **llhttp**
  (MIT) and **SHA-1DC** (MIT) are bundled inside libgit2 and are compiled into
  this archive.
- **⚠️ LibXDiff is LGPL-2.1-or-later**, is mandatory in libgit2 1.9.6, and is
  **not** covered by libgit2's linking exception — that exception is a grant from
  the libgit2 authors, and Libenzi is not one of them. Static LGPL linking into an
  App Store binary is the awkward case under LGPL-2.1 §6. Every libgit2 consumer
  is in the same position, so this is well-trodden rather than novel, but it is a
  decision above this package's level and `LICENSES.md` lays out the options.
- Not shipped and deliberately so: **wolfSSL**, the only other ed25519-capable
  libssh2 backend, is GPL with no linking exception — non-viable for a closed
  App Store binary.

Export: a bundled crypto library means `ITSAppUsesNonExemptEncryption = YES` and
a one-time French encryption declaration if the app ships in France. That is the
app's paperwork, not the package's.

## Further reading

- `docs/UNVERIFIED-recheck.md` — the two `[UNVERIFIED]` App Store claims the
  plan assigned to this sortie, rechecked with sources and dates.
- `scripts/versions.sh` — the only place a version number may be changed.
