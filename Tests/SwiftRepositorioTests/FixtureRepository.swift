import Foundation

import Clibgit2

/// Builds real git repositories in a temporary directory, using libgit2.
///
/// ## Why this is hand-rolled C rather than `git init`
///
/// There is no shelling out available to this package, now or later. iOS has no
/// `Process`; a spawned child on sandboxed macOS inherits the sandbox and cannot
/// reach anything the parent cannot; and Sortie 20 asserts the shipped archive
/// contains no `fork`/`execve`/`posix_spawn` symbols at all. A test helper that
/// depended on the `git` binary would also mean the suite tested whatever git the
/// developer happened to have rather than the library under test.
///
/// So fixtures are built with `git_repository_init`, `git_index_add_bypath` and
/// `git_commit_create` directly. That is *write*-path C, which is Sortie 3's
/// public API to design — this helper deliberately does not anticipate that
/// design. When Sortie 3 lands, replacing these internals with the real API is a
/// worthwhile simplification and this comment is the note to do it.
///
/// Not an actor: each instance is created, used, and destroyed inside a single
/// test, on one task. The repository handle here never crosses a boundary.
final class FixtureRepository {

    /// Directory containing the repository. Removed by ``cleanUp()``.
    let root: URL
    private var handle: OpaquePointer?

    /// Fixed identity and timestamp, so a fixture's commit SHA is deterministic
    /// for identical content. A test that depended on `git_signature_now` would
    /// produce a different SHA every run, and nothing here needs wall-clock time.
    private static let authorName = "SwiftRepositorio Fixtures"
    private static let authorEmail = "fixtures@example.invalid"
    private static let commitTime: git_time_t = 1_700_000_000
    private static let commitOffset: Int32 = 0

    // MARK: - Lifecycle

    /// Creates an empty repository in a fresh temporary directory.
    init(name: String = "fixture", bare: Bool = false) throws {
        // A unique directory per instance: several fixtures coexist within one
        // test (a source and a clone destination at minimum), and swift-testing
        // runs tests in parallel by default.
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftRepositorioTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = git_libgit2_init()

        var options = git_repository_init_options()
        try check(
            git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION)),
            "git_repository_init_options_init"
        )
        if bare { options.flags |= GIT_REPOSITORY_INIT_BARE.rawValue }
        // Pin the branch name. libgit2 otherwise takes it from init.defaultBranch
        // in the developer's global config, which would make the fixture's branch
        // name depend on whose machine the suite ran on.
        try "main".withCString { branch in
            options.initial_head = branch
            try check(git_repository_init_ext(&handle, root.path, &options), "git_repository_init_ext")
        }
    }

    deinit {
        git_repository_free(handle)
    }

    /// Frees the handle and deletes the directory.
    ///
    /// Explicit rather than left to `deinit` because a test that fails should not
    /// also leak a repository into `/tmp`, and because `deinit` ordering relative
    /// to the file system is not something to rely on.
    func cleanUp() {
        git_repository_free(handle)
        handle = nil
        // The whole unique parent, not just `root` — `init` created two levels.
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: - Content

    /// Writes a file into the working directory, creating parent directories.
    func write(_ contents: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Stages a path and commits everything currently staged.
    ///
    /// - Returns: The new commit's 40-character hex SHA.
    @discardableResult
    func commit(_ message: String, adding paths: [String]) throws -> String {
        for path in paths {
            try stage(path)
        }
        let treeOID = try writeTree()

        var tree: OpaquePointer?
        try check(git_tree_lookup(&tree, handle, [treeOID]), "git_tree_lookup")
        defer { git_tree_free(tree) }

        var signature: UnsafeMutablePointer<git_signature>?
        try check(
            git_signature_new(
                &signature,
                Self.authorName,
                Self.authorEmail,
                Self.commitTime,
                Self.commitOffset
            ),
            "git_signature_new"
        )
        defer { git_signature_free(signature) }

        // Parent is whatever HEAD currently is; absent for the first commit, which
        // libgit2 reports as GIT_EUNBORNBRANCH rather than as a failure.
        let parent = try currentHeadCommit()
        defer { git_commit_free(parent) }

        var commitOID = git_oid()
        var parents: [OpaquePointer?] = parent.map { [$0] } ?? []
        try check(
            parents.withUnsafeMutableBufferPointer { buffer in
                git_commit_create(
                    &commitOID,
                    handle,
                    "HEAD",
                    signature,
                    signature,
                    nil,  // message encoding: NULL means UTF-8
                    message,
                    tree,
                    buffer.count,
                    buffer.count == 0 ? nil : buffer.baseAddress
                )
            },
            "git_commit_create"
        )
        return Self.hex(commitOID)
    }

    /// Writes the current index out as a tree object.
    private func writeTree() throws -> git_oid {
        var index: OpaquePointer?
        try check(git_repository_index(&index, handle), "git_repository_index")
        defer { git_index_free(index) }

        var treeOID = git_oid()
        try check(git_index_write_tree(&treeOID, index), "git_index_write_tree")
        return treeOID
    }

    /// The commit HEAD points at, or `nil` when HEAD is unborn.
    private func currentHeadCommit() throws -> OpaquePointer? {
        var headOID = git_oid()
        guard git_reference_name_to_id(&headOID, handle, "HEAD") == 0 else { return nil }
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, handle, &headOID), "git_commit_lookup")
        return commit
    }

    /// Stages a path without committing, so status has something on the index side.
    func stage(_ relativePath: String) throws {
        var index: OpaquePointer?
        try check(git_repository_index(&index, handle), "git_repository_index")
        defer { git_index_free(index) }
        try relativePath.withCString { cPath in
            try check(git_index_add_bypath(index, cPath), "git_index_add_bypath(\(relativePath))")
        }
        try check(git_index_write(index), "git_index_write")
    }

    /// Creates a branch at the current HEAD commit, without switching to it.
    func createBranch(_ name: String) throws {
        var headOID = git_oid()
        try check(git_reference_name_to_id(&headOID, handle, "HEAD"), "git_reference_name_to_id(HEAD)")

        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, handle, &headOID), "git_commit_lookup")
        defer { git_commit_free(commit) }

        var branch: OpaquePointer?
        try check(git_branch_create(&branch, handle, name, commit, 0), "git_branch_create(\(name))")
        git_reference_free(branch)
    }

    /// A one-commit repository with a single tracked file — the smallest fixture
    /// that has a resolvable HEAD.
    static func withInitialCommit(name: String = "source") throws -> (FixtureRepository, String) {
        let fixture = try FixtureRepository(name: name)
        try fixture.write("# Fixture\n", to: "README.md")
        let sha = try fixture.commit("Initial commit", adding: ["README.md"])
        return (fixture, sha)
    }

    // MARK: - Plumbing

    private func check(_ code: Int32, _ operation: String) throws {
        guard code < 0 else { return }
        // Same thread as the failing call, for the same reason the library's own
        // `gitCall` does it there — see GitError.swift.
        let message = git_error_last()?.pointee.message.map { String(cString: $0) } ?? ""
        throw FixtureError(operation: operation, code: code, message: message)
    }

    private static func hex(_ oid: git_oid) -> String {
        var oid = oid
        guard let cString = git_oid_tostr_s(&oid) else { return "" }
        return String(cString: cString)
    }
}

/// Counts commits reachable from HEAD, by revwalk.
///
/// Lives in the test target rather than on ``GitRepository`` on purpose: the
/// plan scopes Sortie 2's public surface to open / clone / head / status, and a
/// revwalk is not in it. It exists only to give the shallow-clone verdict a
/// measurement instead of an assumption, so it stays here until some sortie has
/// an actual product reason to expose history walking.
enum CommitCounter {

    /// How many commits are reachable from HEAD.
    static func countFromHead(at path: String) throws -> Int {
        _ = git_libgit2_init()

        var repository: OpaquePointer?
        guard git_repository_open(&repository, path) == 0, let repository else {
            throw FixtureError(operation: "git_repository_open", code: -1, message: "could not open \(path)")
        }
        defer { git_repository_free(repository) }

        var walker: OpaquePointer?
        guard git_revwalk_new(&walker, repository) == 0, let walker else {
            throw FixtureError(operation: "git_revwalk_new", code: -1, message: "")
        }
        defer { git_revwalk_free(walker) }

        guard git_revwalk_push_head(walker) == 0 else {
            throw FixtureError(operation: "git_revwalk_push_head", code: -1, message: "")
        }

        var count = 0
        var oid = git_oid()
        // GIT_ITEROVER is how a revwalk says "done", not how it says "broken".
        while git_revwalk_next(&oid, walker) == 0 {
            count += 1
        }
        return count
    }
}

/// A failure while *building* a fixture, kept distinct from `GitError` so a
/// broken fixture can never be mistaken for the behaviour under test.
struct FixtureError: Error, CustomStringConvertible {
    let operation: String
    let code: Int32
    let message: String

    var description: String {
        "fixture setup failed: \(operation) → \(code) \(message.isEmpty ? "(no message)" : message)"
    }
}
