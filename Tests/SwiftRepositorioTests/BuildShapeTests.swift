import Testing

import SwiftRepositorio

/// What actually got linked.
///
/// Every expectation here reads the **binary**, never
/// `SwiftRepositorio.PinnedVersions`. That is the entire value of this suite: the
/// build script is the component most likely to be wrong, so a test that compares
/// the build script's constants against themselves is a test that cannot fail for
/// the reason you care about.
///
/// Nothing here skips. A skipped assertion about the shape of a crypto build is
/// indistinguishable from a passing one at a glance, and this is the suite that
/// stands between a mis-built xcframework and an authentication bug that looks
/// like a bad key.
@Suite("Linked build shape")
struct BuildShapeTests {

    // MARK: - Features

    @Test("HTTPS transport is compiled in")
    func httpsIsPresent() {
        let features = SwiftRepositorio.enabledFeatures
        #expect(
            features.contains(.https),
            """
            libgit2 reports no HTTPS support. Features: \(features).
            Every credential-ladder order that is not SSH goes over HTTPS, and
            USE_HTTPS=OpenSSL is decision D-6. Rebuild the xcframework.
            """
        )
    }

    @Test("SSH transport is compiled in")
    func sshIsPresent() {
        let features = SwiftRepositorio.enabledFeatures
        #expect(
            features.contains(.ssh),
            """
            libgit2 reports no SSH support. Features: \(features).
            Orders 1 and 2 of the credential ladder are SSH — an imported
            ~/.ssh key and an in-app generated key. Without this the product's
            default authentication path does not exist.
            """
        )
    }

    /// The floor that this whole package exists to hold.
    @Test("linked libssh2 is at least 1.11.0")
    func libssh2MeetsTheFloor() throws {
        let linked = try #require(
            SwiftRepositorio.libssh2Version,
            """
            libssh2_version() returned nothing, so libssh2 is not linked at all.
            """
        )

        #expect(
            linked >= SwiftRepositorio.minimumLibssh2Version,
            """
            Linked libssh2 is \(linked), below the \
            \(SwiftRepositorio.minimumLibssh2Version) floor.
            RFC 8332 rsa-sha2-256/512 merged into libssh2 on 2022-01-06; 1.10.0
            shipped 2021-08-29, before that merge. GitHub has refused SHA-1
            ssh-rsa signatures since 2022, so this build cannot authenticate an
            RSA key and will fail with an error that looks like a bad key rather
            than a bad algorithm.
            """
        )
    }

    /// The tag-versus-tarball trap, asserted at runtime.
    ///
    /// libssh2 tags its release commit before stripping the in-development
    /// suffix, so a git-tag-based build reports `1.11.1_DEV` from
    /// `libssh2_version()` while the release tarball reports `1.11.1`. Both
    /// satisfy the floor above, which is exactly why that test cannot catch this
    /// and this one exists.
    @Test("linked libssh2 is a release build, not a tagged working tree")
    func libssh2IsARelease() throws {
        let linked = try #require(SwiftRepositorio.libssh2Version)
        #expect(
            !linked.raw.contains("_DEV"),
            """
            libssh2 reports \(linked.raw) — an in-development version string.
            The source was taken from the git tag rather than the release
            tarball; see README § Why libssh2 comes from the tarball.
            """
        )
        #expect(
            linked.raw == SwiftRepositorio.PinnedVersions.libssh2,
            """
            Linked libssh2 reports \(linked.raw) but scripts/versions.sh pins
            \(SwiftRepositorio.PinnedVersions.libssh2). The artefact and the
            recipe disagree; one of them is stale.
            """
        )
    }

    @Test("linked libgit2 is the pinned version")
    func libgit2IsThePinnedVersion() {
        let linked = SwiftRepositorio.libgit2Version
        let pinned = SwiftRepositorio.PinnedVersions.libgit2
        #expect(
            linked.raw == pinned,
            """
            Linked libgit2 reports \(linked.raw) but scripts/versions.sh pins
            \(pinned). The xcframework in artifacts/ was built from a different
            source than the recipe currently describes — rebuild it.
            """
        )
    }

    @Test("threads, regex and a HTTP parser are all compiled in")
    func supportingFeaturesArePresent() {
        let features = SwiftRepositorio.enabledFeatures
        #expect(features.contains(.threads), "USE_THREADS=ON is required; the wrapper is an actor over a non-Sendable handle. Features: \(features)")
        #expect(features.contains(.regex), "no regex engine — .gitignore and .gitattributes matching would be dead. Features: \(features)")
        #expect(features.contains(.httpParser), "no HTTP parser — the smart-HTTP transport cannot work. Features: \(features)")
    }

    /// The deliberate absences. A backend that switched itself back on is a
    /// change in the shipped binary's shape, and it should fail here rather than
    /// be discovered on a device.
    @Test("NTLM and Negotiate are absent, as configured")
    func disabledAuthBackendsStayDisabled() {
        let features = SwiftRepositorio.enabledFeatures
        #expect(
            !features.contains(.authNTLM),
            "USE_NTLMCLIENT=OFF, but NTLM is reported present. Features: \(features)"
        )
        #expect(
            !features.contains(.authNegotiate),
            """
            USE_GSSAPI=OFF, but Negotiate is reported present. Features: \(features).
            GSS.framework does not exist on iOS, so this also means the macOS and
            iOS slices were configured differently.
            """
        )
    }

    @Test("the build description names every linked component")
    func buildDescriptionIsUsable() {
        let text = SwiftRepositorio.buildDescription
        #expect(text.contains("libgit2 "))
        #expect(text.contains("libssh2 "))
        #expect(!text.contains("not linked"), "buildDescription reports something unlinked: \(text)")
    }
}

/// `Version` is the thing that decides whether the libssh2 floor holds, so its
/// parsing and ordering are worth testing directly rather than only through the
/// linked library — the interesting inputs are ones a correct build never
/// produces.
@Suite("Version parsing and ordering")
struct VersionTests {

    @Test(
        "parses the forms libgit2 and libssh2 actually emit",
        arguments: [
            ("1.11.1", 1, 11, 1),
            ("1.11.1_DEV", 1, 11, 1),
            ("1.9.6", 1, 9, 6),
            ("1.11", 1, 11, 0),
            ("3", 3, 0, 0),
            ("1.11.1-rc1", 1, 11, 1),
        ]
    )
    func parsesKnownForms(text: String, major: Int, minor: Int, patch: Int) throws {
        let parsed = try #require(SwiftRepositorio.Version(parsing: text))
        #expect(parsed.major == major)
        #expect(parsed.minor == minor)
        #expect(parsed.patch == patch)
        #expect(parsed.raw == text, "raw must survive parsing verbatim, suffix included")
    }

    @Test("rejects text with no leading version", arguments: ["", "unknown", "v1.11.1"])
    func rejectsNonVersions(text: String) {
        #expect(SwiftRepositorio.Version(parsing: text) == nil)
    }

    @Test("orders by component, not lexically")
    func ordersNumerically() {
        let floor = SwiftRepositorio.Version(major: 1, minor: 11, patch: 0)
        // The whole point: 1.9.x sorts BELOW 1.11.0, which a string compare gets
        // backwards. 1.10.0 is the version the requirements document originally
        // named, and it must not satisfy the floor.
        #expect(SwiftRepositorio.Version(major: 1, minor: 9, patch: 0) < floor)
        #expect(SwiftRepositorio.Version(major: 1, minor: 10, patch: 0) < floor)
        #expect(SwiftRepositorio.Version(major: 1, minor: 11, patch: 0) >= floor)
        #expect(SwiftRepositorio.Version(major: 1, minor: 11, patch: 1) >= floor)
        #expect(SwiftRepositorio.Version(major: 2, minor: 0, patch: 0) >= floor)
    }

    @Test("a packaging suffix does not change which version it is")
    func suffixDoesNotAffectOrdering() throws {
        let release = try #require(SwiftRepositorio.Version(parsing: "1.11.1"))
        let tagged = try #require(SwiftRepositorio.Version(parsing: "1.11.1_DEV"))
        #expect(release == tagged)
        #expect(!(release < tagged))
        #expect(!(tagged < release))
    }
}
