import Foundation

import Clibgit2

extension GitRepository {

    // MARK: - Staging

    /// Stages the named paths, byte for byte.
    ///
    /// ## Byte fidelity is structural here, not configured
    ///
    /// This does **not** use `git_index_add_bypath`, and that is the single most
    /// important thing about this method.
    ///
    /// `git_index_add_bypath` reads the file itself and passes
    /// `try_load_filters = true` to `git_blob__create_from_paths`
    /// (`src/libgit2/index.c:1015`). That runs libgit2's content-filter chain,
    /// which is driven by `.gitattributes` and by the `core.autocrlf` and
    /// `core.eol` configuration keys — and libgit2 reads the user's **global**
    /// `~/.gitconfig` by default. So on a machine where someone has ever set
    /// `core.autocrlf = true` or `input`, staging through that API rewrites line
    /// endings inside the committed blob. The working file is untouched, the
    /// commit is wrong, and nothing reports it.
    ///
    /// That is a direct violation of the mission's Standing Order 7 — "No
    /// character is transformed. A commit writes exactly the bytes the editor
    /// saved" — and it would be a violation that depends on whose laptop ran the
    /// build.
    ///
    /// So the bytes are read here with `Data` and handed to
    /// `git_index_add_from_buffer`, which calls `git_blob_create_from_buffer`
    /// directly and touches no filter chain at all. The guarantee then holds
    /// regardless of what any configuration file anywhere says, which is the only
    /// kind of guarantee worth making about user data. The test suite proves it by
    /// setting `core.autocrlf = true` in a fixture and asserting CRLF bytes
    /// survive.
    ///
    /// ## Why there is no `stageAll`
    ///
    /// Deliberately absent, per the plan. `git_index_add_all` stages whatever
    /// happens to be in the working directory, which means the set of things
    /// committed is decided by the state of the disk rather than by the user. For
    /// a document editor that is the wrong default twice over: it invites
    /// committing a file the user was still editing, and it makes "what am I about
    /// to commit" un-answerable from the call site. Callers enumerate paths, and
    /// ``status(options:)`` is how they find out what the candidates are.
    ///
    /// - Parameter paths: Repository-relative paths. Each must be an existing
    ///   regular file.
    public func stage(paths: [String]) throws {
        guard !paths.isEmpty else { return }
        guard let workdir = workingDirectory else {
            throw GitError(
                operation: "stage",
                code: GIT_EBAREREPO.rawValue,
                klass: -1,
                message: "cannot stage into a bare repository: it has no working directory"
            )
        }

        let repository = handle
        let index = try gitHandle("git_repository_index") { out in
            git_repository_index(&out, repository)
        }
        guard let index else {
            throw GitError(
                operation: "git_repository_index",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "libgit2 reported success but produced no index"
            )
        }
        defer { git_index_free(index) }

        for path in paths {
            let staged = try Self.readForStaging(path: path, workdir: workdir)
            try Self.addToIndex(index, path: path, contents: staged.contents, mode: staged.mode)
        }

        try gitCall("git_index_write") { git_index_write(index) }
    }

    /// What a file contributes to the index: its exact bytes and its file mode.
    private struct StagedContents {
        let contents: Data
        let mode: git_filemode_t
    }

    /// Reads a working-directory file for staging, refusing anything whose bytes
    /// would not round-trip.
    private static func readForStaging(path: String, workdir: String) throws -> StagedContents {
        let absolute = URL(fileURLWithPath: workdir).appendingPathComponent(path)

        // `resolvingSymlinksInPath` is deliberately NOT used. A symlink staged as
        // its target's contents is a silent data error: the repository would gain
        // a regular file where the user has a link, and checking it out elsewhere
        // would produce something different from what was committed. git stores
        // the link itself, and supporting that properly means writing the target
        // path as the blob — worth doing when something needs it, and worth
        // refusing loudly until then.
        let attributes = try FileManager.default.attributesOfItem(atPath: absolute.path)
        guard let type = attributes[.type] as? FileAttributeType else {
            throw GitError(
                operation: "stage",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "could not determine the file type of '\(path)'"
            )
        }

        switch type {
        case .typeRegular:
            break
        case .typeSymbolicLink:
            throw GitError(
                operation: "stage",
                code: GIT_ENOTSUPPORTED.rawValue,
                klass: -1,
                message: """
                    '\(path)' is a symbolic link, which this package does not stage. \
                    Staging it as its target's contents would commit something \
                    different from what is on disk.
                    """
            )
        case .typeDirectory:
            throw GitError(
                operation: "stage",
                code: GIT_EDIRECTORY.rawValue,
                klass: -1,
                message: """
                    '\(path)' is a directory. Paths must be named individually — \
                    there is no recursive staging. See status() for the candidates.
                    """
            )
        default:
            throw GitError(
                operation: "stage",
                code: GIT_ENOTSUPPORTED.rawValue,
                klass: -1,
                message: "'\(path)' is not a regular file (type \(type.rawValue))"
            )
        }

        // `.uncached` because the point of this read is the bytes on disk right
        // now, and a mapped or cached read is a longer window in which they could
        // change underneath us.
        let contents = try Data(contentsOf: absolute, options: .uncached)

        // git records exactly one bit of permission: whether the file is
        // executable. Everything else about the mode is discarded, so reading
        // more would be inventing information git cannot store.
        let isExecutable = FileManager.default.isExecutableFile(atPath: absolute.path)
        return StagedContents(
            contents: contents,
            mode: isExecutable ? GIT_FILEMODE_BLOB_EXECUTABLE : GIT_FILEMODE_BLOB
        )
    }

    /// Adds one path's bytes to the index without going through any filter.
    private static func addToIndex(
        _ index: OpaquePointer,
        path: String,
        contents: Data,
        mode: git_filemode_t
    ) throws {
        var entry = git_index_entry()
        entry.mode = UInt32(mode.rawValue)

        // The entry's `path` is borrowed by libgit2 for the duration of the call
        // — `index_entry_dup` copies it internally — so the C string only has to
        // outlive `git_index_add_from_buffer`, which `withCString` guarantees.
        try path.withCString { cPath in
            entry.path = cPath
            try contents.withUnsafeBytes { bytes in
                try gitCall("git_index_add_from_buffer(\(path))") {
                    // An empty file has no base address. Passing a non-NULL dummy
                    // with length 0 keeps libgit2's assertions happy and produces
                    // the correct empty blob.
                    let base = bytes.baseAddress ?? UnsafeRawPointer(bitPattern: 1)
                    return git_index_add_from_buffer(index, &entry, base, bytes.count)
                }
            }
        }
    }

    // MARK: - Committing

    /// Commits everything currently staged.
    ///
    /// ## Why both identities are required
    ///
    /// There is exactly one `commit` method and it has no defaults. No
    /// `author: Author? = nil`, no overload that falls back to the git config, no
    /// `committer` defaulting to the author. A commit with no identity, or with an
    /// identity quietly inherited from whatever `~/.gitconfig` happens to say, is
    /// a commit whose provenance is wrong — and unlike most wrong things, it is
    /// permanent and rewriting it changes every downstream SHA.
    ///
    /// Making that a compile error rather than a runtime default is the point.
    /// libgit2 offers `git_signature_default`, which reads the global config; it
    /// is deliberately not used, because "the machine's identity" is not the same
    /// claim as "this user's identity" and only the caller knows which it has.
    ///
    /// If a convenience is ever wanted, it must default the **committer** to the
    /// author and never the other way round. The author is the claim about who
    /// wrote the change; the committer is a detail about who recorded it.
    ///
    /// - Returns: The new commit's 40-character hex SHA.
    public func commit(message: String, author: Author, committer: Author) throws -> String {
        let tree = try writeStagedTree()
        defer { git_tree_free(tree) }

        let parent = try currentHeadCommit()
        defer { if let parent { git_commit_free(parent) } }

        return try author.withSignature { authorSignature in
            try committer.withSignature { committerSignature in
                try createCommit(
                    message: message,
                    tree: tree,
                    parent: parent,
                    author: authorSignature,
                    committer: committerSignature
                )
            }
        }
    }

    /// Writes the index out as a tree and looks it up.
    private func writeStagedTree() throws -> OpaquePointer {
        let repository = handle

        let index = try gitHandle("git_repository_index") { out in
            git_repository_index(&out, repository)
        }
        guard let index else {
            throw GitError(
                operation: "git_repository_index",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "libgit2 reported success but produced no index"
            )
        }
        defer { git_index_free(index) }

        var treeOID = git_oid()
        try gitCall("git_index_write_tree") {
            git_index_write_tree(&treeOID, index)
        }

        let tree = try withUnsafePointer(to: treeOID) { oid in
            try gitHandle("git_tree_lookup") { out in
                git_tree_lookup(&out, repository, oid)
            }
        }
        guard let tree else {
            throw GitError(
                operation: "git_tree_lookup",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "the tree just written to the index could not be looked up"
            )
        }
        return tree
    }

    /// The `git_commit_create` call itself.
    private func createCommit(
        message: String,
        tree: OpaquePointer,
        parent: OpaquePointer?,
        author: UnsafePointer<git_signature>?,
        committer: UnsafePointer<git_signature>?
    ) throws -> String {
        let repository = handle
        var commitOID = git_oid()
        var parents: [OpaquePointer?] = parent.map { [$0] } ?? []

        try parents.withUnsafeMutableBufferPointer { buffer in
            try gitCall("git_commit_create") {
                git_commit_create(
                    &commitOID,
                    repository,
                    // Updating HEAD here is what makes the commit the new tip.
                    // Passing nil would create a dangling commit that nothing
                    // references and gc would eventually delete — a mistake that
                    // looks like a successful commit.
                    "HEAD",
                    author,
                    committer,
                    // NULL message encoding means UTF-8, which is what Swift
                    // `String` already is. Naming an encoding here would assert
                    // something about bytes we do not have.
                    nil,
                    message,
                    tree,
                    buffer.count,
                    buffer.count == 0 ? nil : buffer.baseAddress
                )
            }
        }
        return Self.hexString(commitOID)
    }

    /// The commit HEAD points at, or `nil` when HEAD is unborn.
    ///
    /// Unborn is the first-commit case and is not an error — see
    /// ``head()`` for the same reasoning.
    private func currentHeadCommit() throws -> OpaquePointer? {
        let repository = handle
        var headOID = git_oid()
        let code = try gitCall(
            "git_reference_name_to_id(HEAD)",
            tolerating: [GIT_ENOTFOUND, GIT_EUNBORNBRANCH]
        ) {
            git_reference_name_to_id(&headOID, repository, "HEAD")
        }
        guard code == 0 else { return nil }

        return try withUnsafePointer(to: headOID) { oid in
            try gitHandle("git_commit_lookup") { out in
                git_commit_lookup(&out, repository, oid)
            }
        }
    }
}
