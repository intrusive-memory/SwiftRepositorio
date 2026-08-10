import Clibgit2

/// Reads identity out of the **linked** C libraries.
///
/// Internal on purpose. Sortie 1b owns the public `libgit2Version` and
/// `enabledFeatures` surface (and the tests that assert on them); this type is
/// the minimum needed to prove `Clibgit2.xcframework` links and to give those
/// tests something to build on via `@testable import`.
///
/// Every value here is read from the library at runtime. Nothing in this type
/// may ever be derived from `SwiftRepositorio.PinnedVersions` — the build script
/// is precisely the thing that would be wrong.
enum Clibgit2Linkage {

    /// `git_libgit2_version()` — the linked libgit2's own version triple.
    static func libgit2Version() -> (major: Int, minor: Int, revision: Int)? {
        var major: Int32 = 0
        var minor: Int32 = 0
        var revision: Int32 = 0
        guard git_libgit2_version(&major, &minor, &revision) == 0 else { return nil }
        return (Int(major), Int(minor), Int(revision))
    }

    /// The raw `git_libgit2_features()` bitmask.
    ///
    /// Sortie 1b decodes this into an `OptionSet` and asserts `.https` and
    /// `.ssh` are present. Left raw here so that decoding is designed once, by
    /// the sortie that also writes its tests.
    static func rawFeatures() -> Int32 {
        git_libgit2_features()
    }

    /// `libssh2_version(0)` — the linked libssh2's version string, e.g. "1.11.1".
    ///
    /// The whole point of shipping `libssh2.h` in the module surface. Returns
    /// `nil` only if SSH is not linked at all, which is itself the assertion
    /// failure Sortie 1b needs to be able to make.
    static func libssh2Version() -> String? {
        guard let raw = libssh2_version(0) else { return nil }
        return String(cString: raw)
    }
}
