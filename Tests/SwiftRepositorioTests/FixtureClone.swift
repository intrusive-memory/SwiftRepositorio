import Foundation

import Clibgit2

/// Reads a reference's target straight out of a repository on disk.
///
/// The only way to know a **push actually moved the server's ref** rather than the
/// client merely believing it did: it opens the bare repository and reads the ref,
/// with no involvement from the code under test.
enum RefReader {

    /// The 40-character hex SHA `ref` points at.
    static func target(of ref: String, in repositoryPath: String) throws -> String {
        _ = git_libgit2_init()

        var repository: OpaquePointer?
        guard git_repository_open(&repository, repositoryPath) == 0, let repository else {
            throw FixtureError(operation: "git_repository_open", code: -1, message: repositoryPath)
        }
        defer { git_repository_free(repository) }

        var oid = git_oid()
        guard git_reference_name_to_id(&oid, repository, ref) == 0 else {
            let message = git_error_last()?.pointee.message.map { String(cString: $0) } ?? ""
            throw FixtureError(
                operation: "git_reference_name_to_id(\(ref))",
                code: -1,
                message: message
            )
        }
        guard let hex = git_oid_tostr_s(&oid) else {
            throw FixtureError(operation: "git_oid_tostr_s", code: -1, message: "")
        }
        return String(cString: hex)
    }

    /// Whether a reference exists at all.
    static func exists(_ ref: String, in repositoryPath: String) -> Bool {
        (try? target(of: ref, in: repositoryPath)) != nil
    }
}

/// A second working copy that clones, commits and pushes — entirely in C.
///
/// ## Why not use `GitRepository` for this
///
/// It would be circular. These helpers exist to move the *server* forward so that
/// the code under test has something real to fetch, diverge from, and fast-forward
/// onto. If the thing that advanced the server were the same actor whose fetch and
/// pull are being tested, a bug that broke both would cancel out and the suite
/// would stay green.
///
/// So this is deliberately an independent implementation, using libgit2 directly,
/// and synchronous so it can be called from anywhere in a test without threading
/// its own `await` through the helper chain.
enum FixtureClone {

    /// Clones `source`, adds one file, commits, and pushes to `main`.
    ///
    /// - Returns: The SHA the source repository's `refs/heads/main` now points at.
    static func cloneCommitAndPush(
        from source: String,
        to destination: String,
        fileName: String,
        contents: Data
    ) throws -> String {
        _ = git_libgit2_init()

        var repository: OpaquePointer?
        var cloneOptions = git_clone_options()
        try check(
            git_clone_options_init(&cloneOptions, UInt32(GIT_CLONE_OPTIONS_VERSION)),
            "git_clone_options_init"
        )
        cloneOptions.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
        try check(git_clone(&repository, source, destination, &cloneOptions), "git_clone")
        guard let repository else {
            throw FixtureError(operation: "git_clone", code: -1, message: "no handle")
        }
        defer { git_repository_free(repository) }

        // Write and stage from the buffer, for the same byte-fidelity reason the
        // library does: add_bypath would run the filter chain and make this helper's
        // behaviour depend on the developer's global git configuration.
        let fileURL = URL(fileURLWithPath: destination).appendingPathComponent(fileName)
        try contents.write(to: fileURL, options: .atomic)

        var index: OpaquePointer?
        try check(git_repository_index(&index, repository), "git_repository_index")
        defer { git_index_free(index) }

        var entry = git_index_entry()
        entry.mode = UInt32(GIT_FILEMODE_BLOB.rawValue)
        try fileName.withCString { cPath in
            entry.path = cPath
            try contents.withUnsafeBytes { bytes in
                let base = bytes.baseAddress ?? UnsafeRawPointer(bitPattern: 1)
                try check(
                    git_index_add_from_buffer(index, &entry, base, bytes.count),
                    "git_index_add_from_buffer"
                )
            }
        }
        try check(git_index_write(index), "git_index_write")

        var treeOID = git_oid()
        try check(git_index_write_tree(&treeOID, index), "git_index_write_tree")

        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, repository, &treeOID), "git_tree_lookup")
        defer { git_tree_free(tree) }

        var signature: UnsafeMutablePointer<git_signature>?
        try check(
            git_signature_new(
                &signature,
                "Other Clone",
                "other@example.invalid",
                1_700_001_000,
                0
            ),
            "git_signature_new"
        )
        defer { git_signature_free(signature) }

        var parent: OpaquePointer?
        var headOID = git_oid()
        if git_reference_name_to_id(&headOID, repository, "HEAD") == 0 {
            try check(git_commit_lookup(&parent, repository, &headOID), "git_commit_lookup")
        }
        defer { if let parent { git_commit_free(parent) } }

        var commitOID = git_oid()
        var parents: [OpaquePointer?] = parent.map { [$0] } ?? []
        try check(
            parents.withUnsafeMutableBufferPointer { buffer in
                git_commit_create(
                    &commitOID,
                    repository,
                    "HEAD",
                    signature,
                    signature,
                    nil,
                    "Commit from the other clone",
                    tree,
                    buffer.count,
                    buffer.count == 0 ? nil : buffer.baseAddress
                )
            },
            "git_commit_create"
        )

        try push(from: repository)

        // Read the answer back from the server, not from this clone — the point is
        // what the server ended up with.
        return try RefReader.target(of: "refs/heads/main", in: source)
    }

    private static func push(from repository: OpaquePointer) throws {
        var remote: OpaquePointer?
        try check(git_remote_lookup(&remote, repository, "origin"), "git_remote_lookup")
        defer { git_remote_free(remote) }

        var pushOptions = git_push_options()
        try check(
            git_push_options_init(&pushOptions, UInt32(GIT_PUSH_OPTIONS_VERSION)),
            "git_push_options_init"
        )

        // Plain refspec, no leading '+', exactly like the library's own push.
        let refspec = "refs/heads/main:refs/heads/main"
        let cString = strdup(refspec)
        defer { free(cString) }
        var pointers: [UnsafeMutablePointer<CChar>?] = [cString]

        try pointers.withUnsafeMutableBufferPointer { buffer in
            var array = git_strarray(strings: buffer.baseAddress, count: 1)
            try check(git_remote_push(remote, &array, &pushOptions), "git_remote_push")
        }
    }

    private static func check(_ code: Int32, _ operation: String) throws {
        guard code < 0 else { return }
        let message = git_error_last()?.pointee.message.map { String(cString: $0) } ?? ""
        throw FixtureError(operation: operation, code: code, message: message)
    }
}
