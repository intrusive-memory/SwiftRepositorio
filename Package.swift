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
    // KNOWN FOLLOW-UP (not this sortie's): consuming this package from another
    // repository over SPM requires the remote form, because a git clone will not
    // contain artifacts/. That means publishing the zipped xcframework as a
    // release asset and swapping the declaration below for:
    //
    //     .binaryTarget(
    //       name: "Clibgit2",
    //       url: "https://github.com/…/releases/download/<tag>/Clibgit2.xcframework.zip",
    //       checksum: "<swift package compute-checksum Clibgit2.xcframework.zip>"
    //     )
    //
    // Until that release exists, Escribir must consume SwiftRepositorio as a
    // local sibling checkout with the xcframework built in place.
    .binaryTarget(
      name: "Clibgit2",
      path: "artifacts/Clibgit2.xcframework"
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

    // Tests are Sortie 1b's work: the features/version surface and the runtime
    // assertion that the LINKED libssh2 reports >= 1.11.0.
  ]
)
