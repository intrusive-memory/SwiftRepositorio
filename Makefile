# SwiftRepositorio — a Swift face over libgit2, and the owner of the
# libgit2 + libssh2 + OpenSSL xcframework.
#
# Standing Order 1: everything runs through a `make` target, and CI calls the
# same targets a developer does. Nothing here invokes the two forbidden
# incantations; the collection's convention is `xcodebuild` against SwiftPM's
# auto-generated `-Package` scheme, and that is what these targets use.

# NOTE FOR ANYONE COPYING A SIBLING PACKAGE'S MAKEFILE HERE: the scheme is
# `SwiftRepositorio`, NOT `SwiftRepositorio-Package`, and that is not an
# oversight. SwiftEscribo and SwiftProyecto both need the `-Package` scheme
# because they expose several products, so SwiftPM's per-product schemes cover
# only a subset of their targets and carry no test action. This package has one
# library product whose name equals the package name, so SwiftPM generates a
# single `SwiftRepositorio` scheme that already contains the test target —
# `xcodebuild -list` shows it as the only scheme, and a `-Package` scheme does
# not exist. Using the sibling spelling fails with "does not contain a scheme
# named SwiftRepositorio-Package" (exit 65), which reads like a broken checkout
# rather than a wrong name. Verified: `xcodebuild test -scheme SwiftRepositorio`
# runs all 12 tests.
SCHEME = SwiftRepositorio
DESTINATION = 'platform=macOS,arch=arm64'

# The iOS slices exist in the xcframework and this target is what proves they are
# consumable. `generic/platform=iOS` builds for the device slice without needing
# a provisioning profile or a connected device; the tests do not run there —
# nothing in this package's test suite is platform-specific, and Escribir links
# the macOS slice only (D-8).
IOS_DESTINATION = 'generic/platform=iOS'

# Apple Silicon only. An accidental x86_64 or universal build would not match the
# xcframework, which ships arm64 in every slice, and the failure would surface as
# a link error about a missing architecture rather than as a wrong flag.
ARCH = ARCHS=arm64 ONLY_ACTIVE_ARCH=YES

# CODE_SIGNING_ALLOWED=NO: a library package has nothing to sign, and on a CI
# runner with no keychain the default tries anyway and fails.
XCODE_FLAGS = CODE_SIGNING_ALLOWED=NO

.PHONY: build build-ios test lint format clean resolve \
        xcframework fetch-only configure-only verify-no-spawn help

# ---------------------------------------------------------------------------
# The three Standing-Order targets
#
# Each of these needs artifacts/Clibgit2.xcframework to exist. It is gitignored
# and roughly 40 MB, so a fresh checkout has to build it first — `make
# xcframework`. The guard below is here because the failure without it is a wall
# of SwiftPM output about a missing artifact that says nothing about what to do.
# ---------------------------------------------------------------------------
XCFRAMEWORK = artifacts/Clibgit2.xcframework

$(XCFRAMEWORK):
	@echo "error: $(XCFRAMEWORK) does not exist."
	@echo "       It is a ~40 MB build product and is deliberately not committed."
	@echo "       Build it first:  make xcframework   (~20-25 min from scratch)"
	@echo "       Cheap pre-checks: make fetch-only / make configure-only"
	@exit 1

build: $(XCFRAMEWORK)
	xcodebuild build -scheme $(SCHEME) -destination $(DESTINATION) $(ARCH) $(XCODE_FLAGS)

# Not part of `build`, and not wired into this package's CI. It proves the iOS
# slices link, which is worth having, but Escribir links macOS only and a broken
# iOS slice must not be able to block the macOS path.
build-ios: $(XCFRAMEWORK)
	xcodebuild build -scheme $(SCHEME) -destination $(IOS_DESTINATION) $(ARCH) $(XCODE_FLAGS)

test: $(XCFRAMEWORK)
	xcodebuild test -scheme $(SCHEME) -destination $(DESTINATION) $(ARCH) $(XCODE_FLAGS)

# A read-only gate. It must never rewrite the tree it is checking — see
# `format` below for the tool that does, and the lint workflow's
# "fail if linting modified the checkout" step for the standing assertion that
# these two never get confused again.
#
# A missing linter fails loudly rather than skipping: a gate that did not run is
# not a gate that passed.
lint:
	@command -v swiftlint >/dev/null 2>&1 || { \
	  echo "error: swiftlint not found on PATH. Install it with: brew install swiftlint"; \
	  echo "       A missing linter must fail loudly — a skipped gate is not a passed gate."; \
	  exit 1; \
	}
	swiftlint version
	swiftlint lint --quiet

# Rewrites files in place, so it is never what CI runs.
format:
	swift format -i -r Sources Tests

# ---------------------------------------------------------------------------
# The xcframework pipeline
#
# Thin wrappers on purpose. The logic lives in scripts/ because it is 1,200 lines
# of build recipe with a checksum gate and a symbol gate in it, and because CI and
# a developer must run the identical thing.
# ---------------------------------------------------------------------------

# Builds all three slices from pinned source. ~20-25 min from cold; a default run
# deletes build/ on success, so there is no cross-run caching.
xcframework:
	scripts/build-xcframework.sh

# Pre-gate 1: fetch, checksum, extract, per-slice SDK/triple/zlib resolution.
# Seconds, and no compiler. Run this before anything long.
fetch-only:
	scripts/build-xcframework.sh --fetch-only

# Pre-gate 2: the above plus both CMake configures, stopping before ninja. This
# is where every backend assertion actually fires — the host-prefix scan, the
# pkg-config bypass check, and all of git2_features.h.
configure-only:
	scripts/build-xcframework.sh --configure-only

# The symbol gate: no fork/exec/posix_spawn (the exec-ssh transport must not be
# linked), no getcontext/makecontext/setcontext (ITMS-90338, proving OpenSSL's
# no-async took), the expected symbols actually present, and git2_features.h
# saying what was asked for. Also run automatically at the end of `xcframework`.
verify-no-spawn:
	scripts/verify-no-spawn.sh

clean:
	xcodebuild clean -scheme $(SCHEME) -destination $(DESTINATION) || true
	rm -rf .build

resolve:
	swift package resolve

help:
	@echo "Available targets:"
	@echo "  build            - Build for macOS (arm64)"
	@echo "  build-ios        - Build for the iOS device slice (proves it links)"
	@echo "  test             - Run the test suite on macOS (arm64)"
	@echo "  lint             - Run SwiftLint (read-only gate; what CI runs)"
	@echo "  format           - Reformat Sources and Tests in place"
	@echo "  clean            - Clean build artifacts"
	@echo "  resolve          - Resolve Swift package dependencies"
	@echo ""
	@echo "  xcframework      - Build Clibgit2.xcframework, all 3 slices (~20-25 min)"
	@echo "  fetch-only       - Pre-gate: fetch + checksum + extract (seconds)"
	@echo "  configure-only   - Pre-gate: + both CMake configures, before ninja"
	@echo "  verify-no-spawn  - Symbol gate over the built xcframework"
	@echo "  help             - Show this help message"
	@echo ""
	@echo "arm64 only. Apple Silicon is the only supported architecture."
	@echo "build/test/lint need artifacts/Clibgit2.xcframework — run 'make xcframework' first."
