// swift-tools-version: 6.2
import PackageDescription

// SwiftRepositorio — a thin, Swift-6-concurrency-correct face over libgit2.
//
// The package exists so that ONE place owns the xcframework and its CVE duty.
// libgit2, libssh2 and OpenSSL all ship security advisories; vendored into an
// app project, patching them means a manual rebuild by whoever remembers, and
// in a package it is a version bump. That is the whole argument, and it is why
// `Clibgit2` is a binary target here rather than a pile of C sources in the app.
//
// There are no Swift package dependencies and there will not be any: the only
// dependencies are the three C libraries baked into Clibgit2.xcframework, pinned
// in scripts/versions.sh.
//
//   libgit2 1.9.6   GPLv2 WITH a linking exception (static linking into a
//                   closed-source App Store binary is permitted — that
//                   exception is the reason any of this is viable)
//   libssh2 1.11.1  BSD-3-Clause. The floor is 1.11.0, not 1.9/1.10: RFC 8332
//                   rsa-sha2-256/512 merged after 1.10.0 shipped, and GitHub
//                   has refused SHA-1 ssh-rsa signatures since 2022.
//   OpenSSL 3.5.7   Apache-2.0
//
// See README.md for the full build rationale and LICENSES.md (Sortie 1b) for
// the complete licence text inventory.
let package = Package(
  name: "SwiftRepositorio",
  platforms: [
    .macOS(.v26),
    .iOS(.v26),
  ],
  products: [
    .library(
      name: "SwiftRepositorio",
      targets: ["SwiftRepositorio"]
    )
  ],
  targets: [
    // The prebuilt C world: libgit2 + libssh2 + libssl + libcrypto, merged into
    // one static archive per slice. Three slices, arm64 only in each:
    // macos-arm64, ios-arm64, ios-arm64-simulator.
    //
    // This is a LOCAL path, so a fresh checkout cannot build until the
    // xcframework has been produced:
    //
    //     scripts/build-xcframework.sh
    //
    // `swift build` will fail with "artifact not found" until then, which is the
    // honest behaviour — a stale committed binary would be worse. The artefact
    // is ~40 MB of static archive and is gitignored for that reason.
    //
    // TODO: flip to the release-asset form once a release exists.
    //
    // Consuming this package from another repository over SPM REQUIRES the remote
    // form: a git clone does not contain artifacts/, so Escribir cannot depend on
    // SwiftRepositorio by URL until the xcframework is published. Until then the
    // only workable arrangement is a local sibling checkout with the xcframework
    // built in place (`make xcframework`).
    //
    // Cutting that release is a supervisor step, not a code change here. When it
    // happens: zip the xcframework, attach it to the release, take the checksum
    // with `swift package compute-checksum Clibgit2.xcframework.zip`, and swap the
    // declaration below for:
    //
    //     .binaryTarget(
    //       name: "Clibgit2",
    //       url: "https://github.com/…/releases/download/<tag>/Clibgit2.xcframework.zip",
    //       checksum: "<swift package compute-checksum Clibgit2.xcframework.zip>"
    //     )
    //
    // Until that release exists, Escribir must consume SwiftRepositorio as a
    // local sibling checkout with the xcframework built in place.
    // Dev form: local artifact, built in place by `make xcframework`. The release
    // TAG carries the url+checksum form (see v0.1.0) — flip at release time only.
    .binaryTarget(
      name: "Clibgit2",
      url:
        "https://github.com/intrusive-memory/SwiftRepositorio/releases/download/v0.2.1/Clibgit2.xcframework.zip",
      checksum: "226058c40705d0777f8f9ec88d25691d4da5959caa486d8af51b069e402a28ff"
    ),

    .target(
      name: "SwiftRepositorio",
      dependencies: ["Clibgit2"],
      linkerSettings: [
        // libgit2 links the SDK's zlib (USE_BUNDLED_ZLIB=OFF, so no second copy
        // of zlib's symbols ends up inside our archive) and the SDK's iconv
        // (USE_ICONV=ON, for HFS+ Unicode precomposition on Apple filesystems).
        .linkedLibrary("z"),
        .linkedLibrary("iconv"),
        // Not strictly required by the OpenSSL HTTPS backend — libgit2's
        // SecureTransport stream is compiled but empty under our flags. Declared
        // anyway because the certificate-verification work (see README § The
        // trust store problem) will reach for Security.framework, and an
        // unnecessary framework link costs nothing while a missing one costs a
        // failed build gate.
        .linkedFramework("Security"),
        .linkedFramework("CoreFoundation"),
      ]
    ),

    // Reads the linked binary, never the pinned constants. `swift-testing` ships
    // with the toolchain, so this adds no package dependency — matching the
    // collection's convention.
    //
    // `Clibgit2` is a direct dependency so the fixture builder can create test
    // repositories by calling libgit2 itself. Shelling out to `git` is not an
    // option: there is no `Process` on iOS, a spawned child would inherit the
    // sandbox anyway, and Sortie 20 asserts the shipped archive contains no spawn
    // symbols at all. The write API that would let fixtures be built through
    // SwiftRepositorio's own surface is Sortie 3's work; until it exists the
    // fixtures use C directly, and this dependency is what allows that.
    .testTarget(
      name: "SwiftRepositorioTests",
      dependencies: ["SwiftRepositorio", "Clibgit2"]
    ),
  ]
)
