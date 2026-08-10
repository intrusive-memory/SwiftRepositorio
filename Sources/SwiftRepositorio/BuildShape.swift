import Clibgit2

/// What the **linked** C libraries actually are, and what they can actually do.
///
/// Everything in this file is read out of the binary at runtime. None of it is
/// derived from ``SwiftRepositorio/PinnedVersions``, and that separation is the
/// whole point: the build script is the thing most likely to be wrong, so a test
/// that asserts against what the build script *said* proves nothing. `libssh2`
/// has already caught this out once here — its git tag reports `1.11.1_DEV`
/// while the release tarball reports `1.11.1`, and the only way to tell which
/// one got linked is to ask the library.
extension SwiftRepositorio {

    // MARK: - Versions

    /// A three-component version, comparable so a floor can be asserted rather
    /// than string-matched.
    public struct Version: Comparable, Hashable, Sendable, CustomStringConvertible {
        public let major: Int
        public let minor: Int
        public let patch: Int

        /// The version exactly as the library reported it, suffixes and all.
        ///
        /// Kept because it is the only place a `_DEV`, `-rc1` or `+quic` suffix
        /// survives, and a diagnostic that silently drops it would hide the
        /// difference between a release build and somebody's working tree.
        public let raw: String

        public init(major: Int, minor: Int, patch: Int, raw: String? = nil) {
            self.major = major
            self.minor = minor
            self.patch = patch
            self.raw = raw ?? "\(major).\(minor).\(patch)"
        }

        /// Parses a leading `major.minor.patch`, ignoring any suffix.
        ///
        /// Returns `nil` only when there is no leading numeric triple at all —
        /// a missing patch component is read as `0`, since `"1.11"` means
        /// 1.11.0 everywhere this is used.
        public init?(parsing text: String) {
            let numeric = text.prefix { $0.isNumber || $0 == "." }
            let parts = numeric.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
            guard let major = parts.first.flatMap(Int.init) else { return nil }
            self.major = major
            self.minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            self.patch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
            self.raw = text
        }

        public var description: String { raw }

        public static func < (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }

        /// Ordering and equality ignore `raw`: `1.11.1` and `1.11.1_DEV` are the
        /// same version of the library, differing only in how it was packaged.
        public static func == (lhs: Version, rhs: Version) -> Bool {
            (lhs.major, lhs.minor, lhs.patch) == (rhs.major, rhs.minor, rhs.patch)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(major)
            hasher.combine(minor)
            hasher.combine(patch)
        }
    }

    /// The linked libgit2's version, from `git_libgit2_version()`.
    public static var libgit2Version: Version {
        var major: Int32 = 0
        var minor: Int32 = 0
        var patch: Int32 = 0
        // Documented to return 0; on a non-zero return the out-params are
        // untouched, so reporting 0.0.0 is honest rather than a guess.
        guard git_libgit2_version(&major, &minor, &patch) == 0 else {
            return Version(major: 0, minor: 0, patch: 0, raw: "unknown")
        }
        let prerelease = git_libgit2_prerelease().map { String(cString: $0) }
        let base = "\(major).\(minor).\(patch)"
        return Version(
            major: Int(major),
            minor: Int(minor),
            patch: Int(patch),
            raw: prerelease.map { "\(base)-\($0)" } ?? base
        )
    }

    /// The linked libssh2's version, from `libssh2_version()`.
    ///
    /// `nil` means libssh2 is not linked at all — which is itself a failure this
    /// package's tests need to be able to state, since SSH is orders 1 and 2 of
    /// the credential ladder.
    public static var libssh2Version: Version? {
        guard let raw = libssh2_version(0) else { return nil }
        return Version(parsing: String(cString: raw))
    }

    /// The libssh2 floor, and the reason this package pins versions at all.
    ///
    /// RFC 8332 `rsa-sha2-256` / `rsa-sha2-512` signing merged into libssh2 on
    /// 2022-01-06. 1.10.0 shipped 2021-08-29, *before* that merge, so it does not
    /// contain it — 1.11.0 (2023-05-30) is the first release that does. GitHub
    /// stopped accepting SHA-1 `ssh-rsa` signatures in 2022, so an older libssh2
    /// fails to authenticate a perfectly good RSA key with an error that reads
    /// like a bad key rather than a bad algorithm.
    public static let minimumLibssh2Version = Version(major: 1, minor: 11, patch: 0)

    // MARK: - Features

    /// `git_libgit2_features()`, decoded.
    ///
    /// This is the shape of the build, asserted rather than assumed. It reports
    /// what libgit2 was *compiled* with — it says nothing about which crypto
    /// library serves those features, so `.https` being present does not by
    /// itself tell you OpenSSL is underneath. `git2_features.h` is where that
    /// lives, and `scripts/verify-no-spawn.sh` check D is what asserts it.
    public struct Features: OptionSet, Sendable, CustomStringConvertible {
        public let rawValue: Int32
        public init(rawValue: Int32) { self.rawValue = rawValue }

        /// Thread-safe: libgit2 was built with `USE_THREADS=ON`.
        public static let threads = Features(rawValue: 1 << 0)
        /// HTTPS transport available. Says nothing about *which* TLS backend.
        public static let https = Features(rawValue: 1 << 1)
        /// SSH transport available. Under this package that means libssh2.
        public static let ssh = Features(rawValue: 1 << 2)
        /// Nanosecond mtime/ctime precision.
        public static let nsec = Features(rawValue: 1 << 3)
        /// A bundled or system HTTP parser is present.
        public static let httpParser = Features(rawValue: 1 << 4)
        /// A regex engine is present. Here it is libgit2's bundled PCRE2.
        public static let regex = Features(rawValue: 1 << 5)
        /// iconv-backed Unicode path handling (HFS+ precomposition).
        public static let i18n = Features(rawValue: 1 << 6)
        /// NTLM authentication. Off in this build.
        public static let authNTLM = Features(rawValue: 1 << 7)
        /// SPNEGO/Negotiate via GSSAPI. Off in this build — no GSS on iOS.
        public static let authNegotiate = Features(rawValue: 1 << 8)
        /// zlib compression.
        public static let compression = Features(rawValue: 1 << 9)
        /// SHA-1 support.
        public static let sha1 = Features(rawValue: 1 << 10)
        /// SHA-256 support (object-format-256 repositories).
        public static let sha256 = Features(rawValue: 1 << 11)

        static let known: [(Features, String)] = [
            (.threads, "threads"), (.https, "https"), (.ssh, "ssh"),
            (.nsec, "nsec"), (.httpParser, "httpParser"), (.regex, "regex"),
            (.i18n, "i18n"), (.authNTLM, "authNTLM"),
            (.authNegotiate, "authNegotiate"), (.compression, "compression"),
            (.sha1, "sha1"), (.sha256, "sha256"),
        ]

        public var description: String {
            let names = Features.known.filter { contains($0.0) }.map(\.1)
            return names.isEmpty ? "[]" : "[\(names.joined(separator: ", "))]"
        }
    }

    /// The linked libgit2's feature bitmask, decoded.
    public static var enabledFeatures: Features {
        Features(rawValue: git_libgit2_features())
    }

    // MARK: - Diagnostics

    /// One line naming everything that actually got linked.
    ///
    /// Worth having as API rather than as test-only code: when a clone fails with
    /// an authentication error, the first question is always which libssh2 is in
    /// the binary, and the answer should not require a debugger.
    public static var buildDescription: String {
        let ssh = libssh2Version.map(\.description) ?? "not linked"
        return "libgit2 \(libgit2Version) / libssh2 \(ssh) / features \(enabledFeatures)"
    }
}
