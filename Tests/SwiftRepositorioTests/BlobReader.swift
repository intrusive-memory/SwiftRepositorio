import Foundation

import Clibgit2

/// Reads committed bytes straight out of the object database.
///
/// ## Why the assertions do not read the working file
///
/// A byte-fidelity test that compared the file on disk with itself would pass
/// unconditionally. The question is whether the bytes that reached the **blob**
/// are the bytes that were on disk, so this reads
/// `git_blob_rawcontent` — "raw" meaning exactly as stored, with no filter
/// applied on the way out. If staging had transformed line endings, the working
/// file would still hold CRLF and only the blob would differ, so this is the only
/// place the difference is visible.
///
/// In the test target rather than the library for the same reason `CommitCounter`
/// is: Sortie 3's public surface is `stage` and `commit`, and a blob-reading API
/// is not in it. When some sortie needs to show file contents from history, this
/// is the shape it wants.
enum BlobReader {

    /// The exact bytes stored for `path` in the commit `sha` points at.
    static func bytes(of path: String, atCommit sha: String, in repositoryPath: String) throws -> Data {
        _ = git_libgit2_init()

        var repository: OpaquePointer?
        guard git_repository_open(&repository, repositoryPath) == 0, let repository else {
            throw FixtureError(
                operation: "git_repository_open",
                code: -1,
                message: "could not open \(repositoryPath)"
            )
        }
        defer { git_repository_free(repository) }

        var oid = git_oid()
        guard git_oid_fromstr(&oid, sha) == 0 else {
            throw FixtureError(operation: "git_oid_fromstr", code: -1, message: "bad SHA \(sha)")
        }

        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repository, &oid) == 0, let commit else {
            throw FixtureError(operation: "git_commit_lookup", code: -1, message: sha)
        }
        defer { git_commit_free(commit) }

        var tree: OpaquePointer?
        guard git_commit_tree(&tree, commit) == 0, let tree else {
            throw FixtureError(operation: "git_commit_tree", code: -1, message: "")
        }
        defer { git_tree_free(tree) }

        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0, let entry else {
            throw FixtureError(
                operation: "git_tree_entry_bypath",
                code: -1,
                message: "'\(path)' is not in the tree of \(sha)"
            )
        }
        defer { git_tree_entry_free(entry) }

        var blob: OpaquePointer?
        guard let entryID = git_tree_entry_id(entry),
              git_blob_lookup(&blob, repository, entryID) == 0,
              let blob
        else {
            throw FixtureError(operation: "git_blob_lookup", code: -1, message: path)
        }
        defer { git_blob_free(blob) }

        let size = Int(git_blob_rawsize(blob))
        guard size > 0 else { return Data() }
        guard let raw = git_blob_rawcontent(blob) else {
            throw FixtureError(operation: "git_blob_rawcontent", code: -1, message: path)
        }
        // Copied, not wrapped: the buffer belongs to the blob and dies with it at
        // the `defer` above.
        return Data(bytes: raw, count: size)
    }

    /// The file mode recorded for `path` in that commit's tree.
    ///
    /// Enough to tell a regular file from an executable one, which is the only
    /// permission distinction git keeps.
    static func mode(of path: String, atCommit sha: String, in repositoryPath: String) throws -> UInt32 {
        _ = git_libgit2_init()

        var repository: OpaquePointer?
        guard git_repository_open(&repository, repositoryPath) == 0, let repository else {
            throw FixtureError(operation: "git_repository_open", code: -1, message: repositoryPath)
        }
        defer { git_repository_free(repository) }

        var oid = git_oid()
        guard git_oid_fromstr(&oid, sha) == 0 else {
            throw FixtureError(operation: "git_oid_fromstr", code: -1, message: sha)
        }

        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repository, &oid) == 0, let commit else {
            throw FixtureError(operation: "git_commit_lookup", code: -1, message: sha)
        }
        defer { git_commit_free(commit) }

        var tree: OpaquePointer?
        guard git_commit_tree(&tree, commit) == 0, let tree else {
            throw FixtureError(operation: "git_commit_tree", code: -1, message: "")
        }
        defer { git_tree_free(tree) }

        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0, let entry else {
            throw FixtureError(operation: "git_tree_entry_bypath", code: -1, message: path)
        }
        defer { git_tree_entry_free(entry) }

        return UInt32(git_tree_entry_filemode(entry).rawValue)
    }
}

extension FixtureRepository {

    /// Writes raw bytes, bypassing any string encoding.
    ///
    /// The byte-fidelity fixtures include sequences that are not valid UTF-8, so
    /// they cannot be expressed as a Swift `String` at all — writing them has to
    /// start from `Data` or the test would be unable to express its own input.
    func writeBytes(_ data: Data, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    /// Sets a local config value, overriding whatever the user's global config says.
    ///
    /// Used to make the byte-fidelity tests **hostile**: a repository configured
    /// the way a Windows-oriented developer's git would configure it, proving the
    /// guarantee holds under the configuration most likely to break it rather than
    /// only under the default.
    func setConfig(_ name: String, _ value: String) throws {
        var config: OpaquePointer?
        try check(git_repository_config(&config, handleForTests), "git_repository_config")
        defer { git_config_free(config) }
        try check(git_config_set_string(config, name, value), "git_config_set_string(\(name))")
    }
}
