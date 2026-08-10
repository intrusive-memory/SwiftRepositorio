/// SwiftRepositorio — a Swift face over libgit2.
///
/// This file is a **skeleton**. Sortie 1a's job was the xcframework and its
/// build pipeline; the API surface belongs to later sorties, and deliberately
/// nothing here pre-empts their design. What is here exists so the package
/// compiles and so the pinned versions have exactly one authority inside Swift.
public enum SwiftRepositorio {

    /// The versions baked into `Clibgit2.xcframework`, as declared by
    /// `scripts/versions.sh`.
    ///
    /// These are the versions the build script was *told* to use. They are not
    /// evidence of what actually got linked — that is what
    /// ``Clibgit2Linkage`` reads out of the library at runtime, and why Sortie
    /// 1b's tests must assert against the runtime values rather than these.
    /// A build script that lies is the exact failure mode being guarded against.
    public enum PinnedVersions {
        public static let libgit2 = "1.9.6"
        public static let libssh2 = "1.11.1"
        public static let openSSL = "3.5.7"

        /// The hard floor for libssh2, and the reason this package pins at all.
        ///
        /// RFC 8332 `rsa-sha2-256` / `rsa-sha2-512` signing merged into libssh2
        /// on 2022-01-06; 1.10.0 shipped 2021-08-29, *before* that merge. GitHub
        /// stopped accepting SHA-1 `ssh-rsa` signatures in 2022, so a 1.10 build
        /// fails to authenticate an existing RSA key with an error that reads
        /// like a bad key rather than a bad algorithm. 1.11.0 (2023-05-30) is the
        /// first release that contains it.
        public static let libssh2Minimum = "1.11.0"
    }
}
