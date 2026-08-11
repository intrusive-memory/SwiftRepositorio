import Foundation

import Clibgit2

/// A git repository.
///
/// ## Why an actor
///
/// Not for the usual reason. The point is not that callers want concurrency — it
/// is that libgit2 forbids it. From `docs/threading.md`: "Unless otherwise
/// specified, libgit2 objects cannot be safely accessed by multiple threads
/// simultaneously. Use an object from a single thread at a time. Most data
/// structures do not guard against concurrent access themselves." Only `git_odb`
/// locks internally; `git_repository` does not.
///
/// So the `git_repository *` needs an owner that serialises every access to it,
/// and an actor is exactly that. The handle is actor-isolated state and never
/// leaves: no method returns it, and nothing accepts one from outside. Every
/// value crossing the boundary is a copied Swift value.
///
/// ## Why nothing here is `@unchecked Sendable`
///
/// It would compile. `OpaquePointer` is bitwise-copyable, so a `@unchecked
/// Sendable` wrapper around the handle would silence the compiler and let the
/// pointer be shared — which is precisely the thing libgit2 says not to do. The
/// package's `.swiftlint.yml` makes `@unchecked Sendable` an error for this
/// reason. Actor isolation is the mechanism; the annotation would be a way of
/// asserting a safety property the C library does not have.
public actor GitRepository {

    /// Owns the `git_repository *` and frees it exactly once.
    ///
    /// ## Why the pointer is not stored directly on the actor
    ///
    /// It was, and it did not compile:
    ///
    /// ```
    /// error: cannot access property 'handle' with a non-Sendable type
    ///        'OpaquePointer' from nonisolated deinit
    /// ```
    ///
    /// An actor's `deinit` is nonisolated, and `OpaquePointer` is not `Sendable`,
    /// so `deinit` may not read actor-isolated storage to free it. Swift is right:
    /// in general a nonisolated deinit racing actor state is a real hazard, and
    /// the compiler cannot see that deinit only runs when no references remain.
    ///
    /// Rather than assert the exception with `@unchecked Sendable` — which this
    /// package's lint rules forbid, for good reason — ownership moves to a plain
    /// class. Freeing then happens in *its* deinit, reading *its own* storage,
    /// which involves no isolation boundary at all. `git_repository_free` is
    /// guaranteed to run exactly once, when the last reference goes, without
    /// anything being deferred to a task that might never run.
    private final class Handle {
        let raw: OpaquePointer
        init(_ raw: OpaquePointer) { self.raw = raw }
        deinit { git_repository_free(raw) }
    }

    private let owned: Handle

    /// `git_repository *`, reachable only from actor-isolated code.
    ///
    /// `internal`, not `private`, so the write paths in
    /// `GitRepository+Write.swift` can reach it — an extension in another file
    /// cannot see `private`. Still actor-isolated and still never returned to a
    /// caller, so the guarantee that matters is unchanged: the pointer does not
    /// leave the actor.
    var handle: OpaquePointer { owned.raw }

    /// Absolute path this repository was opened or cloned to.
    ///
    /// `nonisolated` because it is immutable metadata captured at creation, not
    /// libgit2 state: reading it touches no C handle, so making callers `await`
    /// for it would suggest a synchronisation requirement that does not exist.
    /// Everything that *does* reach into libgit2 — `isBare`, `isShallow`,
    /// `workingDirectory` — stays isolated.
    public nonisolated let path: String

    private init(handle: OpaquePointer, path: String) {
        self.owned = Handle(handle)
        self.path = path
    }

    // MARK: - Opening

    /// Opens an existing repository.
    ///
    /// - Parameter path: A working directory or a `.git` directory. libgit2 does
    ///   not search parent directories here — use ``discover(from:)`` for that.
    public static func open(at path: String) throws -> GitRepository {
        let handle = try gitHandle("git_repository_open") { out in
            git_repository_open(&out, path)
        }
        guard let handle else {
            throw GitError(
                operation: "git_repository_open",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "libgit2 reported success but produced no repository handle"
            )
        }
        return GitRepository(handle: handle, path: path)
    }

    /// Finds the repository containing `path`, walking up from it.
    ///
    /// Separate from ``open(at:)`` because the two answer different questions and
    /// conflating them hides bugs: "open this repository" failing is a real error,
    /// while "is there a repository above this file" legitimately returns nothing.
    public static func discover(from path: String) throws -> GitRepository? {
        var buffer = git_buf()
        defer { git_buf_dispose(&buffer) }

        let code = try gitCall("git_repository_discover", tolerating: [GIT_ENOTFOUND]) {
            git_repository_discover(&buffer, path, 0, nil)
        }
        guard code == 0, let found = buffer.ptr else { return nil }
        return try open(at: String(cString: found))
    }

    // MARK: - Creating

    /// Creates a new, empty repository at `path`.
    ///
    /// Added for callers (Escribir's `CloneOrchestrator` tests, first) that need a
    /// real, hermetic local repository to stage/commit content into and clone
    /// *from* — without shelling out to `git init` (this package has no `Process`
    /// anywhere, on any platform) and without depending on a fixture checked into
    /// some other project's tree. `Tests/SwiftRepositorioTests/FixtureRepository.swift`
    /// hand-rolled exactly this with raw `git_repository_init_ext` calls before this
    /// method existed; this is that logic, promoted to public API and reused by
    /// `WritePathTests`'s own fixture builder (see that file).
    ///
    /// - Parameters:
    ///   - path: Destination directory. Created (including any missing parent
    ///     directories) before `git_repository_init_ext` runs — libgit2's own
    ///     directory creation is not documented to create intermediate parents, and
    ///     a caller building a fixture under a fresh temporary directory should not
    ///     have to `mkdir -p` it first.
    ///   - bare: `true` for a bare repository (no working directory) — the shape a
    ///     local "remote" fixture needs (`FixtureRepository.addRemote` and
    ///     `GitRepositoryTests`/`RemoteTests` both point at one). `false` (the
    ///     default) creates an ordinary working-directory repository.
    ///   - initialBranch: The branch name HEAD points at before the first commit.
    ///     Defaults to `"main"` rather than falling through to `init.defaultBranch`
    ///     in whatever `~/.gitconfig` the calling machine happens to have — a
    ///     fixture whose branch name depends on the developer's global config is a
    ///     fixture that behaves differently on CI than it does locally, which is
    ///     exactly what `FixtureRepository.init` already pins for the same reason.
    public static func create(
        at path: String,
        bare: Bool = false,
        initialBranch: String = "main"
    ) throws -> GitRepository {
        Libgit2Runtime.ensureInitialized()

        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)

        var options = git_repository_init_options()
        try gitCall("git_repository_init_options_init") {
            git_repository_init_options_init(&options, UInt32(GIT_REPOSITORY_INIT_OPTIONS_VERSION))
        }
        if bare {
            options.flags |= GIT_REPOSITORY_INIT_BARE.rawValue
        }

        // `initial_head` is a `const char *` libgit2 reads during the call —
        // `withCString` keeps the buffer alive for exactly that long, the same
        // discipline `clone(from:to:options:)` uses for `checkout_branch` below.
        let handle = try initialBranch.withCString { cBranch -> OpaquePointer? in
            options.initial_head = cBranch
            return try gitHandle("git_repository_init_ext") { out in
                git_repository_init_ext(&out, path, &options)
            }
        }

        guard let handle else {
            throw GitError(
                operation: "git_repository_init_ext",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "libgit2 reported success but produced no repository handle"
            )
        }
        return GitRepository(handle: handle, path: path)
    }

    // MARK: - Cloning

    /// Clones `url` into `path`.
    ///
    /// - Parameters:
    ///   - url: Anything libgit2 accepts — a local path, a `file://` URL, or a
    ///     remote. Sortie 2 exercises the local forms; authenticated remotes need
    ///     the credential callbacks that are Sortie 4's work.
    ///   - path: Destination directory. Must not already exist as a repository.
    ///   - options: See ``CloneOptions``, and read the note on `depth` before
    ///     using it.
    public static func clone(
        from url: String,
        to path: String,
        options: CloneOptions = .default
    ) throws -> GitRepository {
        Libgit2Runtime.ensureInitialized()

        var cloneOptions = git_clone_options()
        try gitCall("git_clone_options_init") {
            git_clone_options_init(&cloneOptions, UInt32(GIT_CLONE_OPTIONS_VERSION))
        }

        cloneOptions.bare = options.bare ? 1 : 0
        cloneOptions.local = options.localStrategy.libgit2Value
        if let depth = options.depth {
            cloneOptions.fetch_opts.depth = depth
        }

        // A clone with no checkout still has to write the working directory for
        // the non-bare case, so the default strategy has to be SAFE rather than
        // NONE — libgit2's own default for git_clone.
        cloneOptions.checkout_opts.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

        // The progress box lives exactly as long as the git_clone call. It is
        // created here, its address handed to C, and released when this scope
        // exits — after git_clone has returned, so C can never hold a stale
        // pointer.
        let progressBox = options.onProgress.map(CloneProgressBox.init)
        if let progressBox {
            cloneOptions.fetch_opts.callbacks.payload = Unmanaged.passUnretained(progressBox).toOpaque()
            cloneOptions.fetch_opts.callbacks.transfer_progress = { stats, payload in
                guard let stats, let payload else { return 0 }
                let box = Unmanaged<CloneProgressBox>.fromOpaque(payload).takeUnretainedValue()
                box.onProgress(TransferProgress(stats.pointee))
                // Non-zero would abort the fetch. Cancellation is not this
                // sortie's; returning 0 unconditionally keeps a slow observer
                // from silently killing a clone.
                return 0
            }
        }

        var handle: OpaquePointer?

        // `checkout_branch` is a `const char *` that libgit2 reads during the
        // call. `withCString` keeps the buffer alive for exactly that long;
        // assigning `someSwiftString.cString` to the struct instead would leave a
        // dangling pointer the moment the temporary died.
        func performClone() throws {
            try gitCall("git_clone") {
                git_clone(&handle, url, path, &cloneOptions)
            }
        }

        if let branch = options.checkoutBranch {
            try branch.withCString { cBranch in
                cloneOptions.checkout_branch = cBranch
                try performClone()
            }
        } else {
            try performClone()
        }

        guard let handle else {
            throw GitError(
                operation: "git_clone",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "libgit2 reported success but produced no repository handle"
            )
        }
        // Retain the box until after the call has returned, so the optimiser
        // cannot release it while C still holds its address.
        withExtendedLifetime(progressBox) {}
        return GitRepository(handle: handle, path: path)
    }

    // MARK: - Inspecting

    /// Where HEAD points.
    public struct Head: Sendable, Equatable {
        /// Short branch name, e.g. `"main"`. `nil` when HEAD is detached.
        public let branch: String?
        /// Full reference name, e.g. `"refs/heads/main"`.
        public let referenceName: String
        /// The commit HEAD resolves to, as a 40-character hex SHA.
        public let sha: String
        /// HEAD names a commit directly rather than a branch.
        public var isDetached: Bool { branch == nil }
    }

    /// Resolves HEAD.
    ///
    /// Returns `nil` when HEAD is **unborn** — a repository that has been
    /// initialised but has no commits yet. That is a normal state, not a failure,
    /// and libgit2 reports it as `GIT_EUNBORNBRANCH`; turning it into a thrown
    /// error would make every caller write the same `catch` to handle a new
    /// repository.
    public func head() throws -> Head? {
        let repository = handle
        let reference = try gitHandle(
            "git_repository_head",
            tolerating: [GIT_EUNBORNBRANCH, GIT_ENOTFOUND]
        ) { out in
            git_repository_head(&out, repository)
        }
        guard let reference else { return nil }
        defer { git_reference_free(reference) }

        guard let oid = git_reference_target(reference) else {
            throw GitError(
                operation: "git_reference_target",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "HEAD resolved to a reference with no direct target"
            )
        }

        let referenceName = git_reference_name(reference).map { String(cString: $0) } ?? ""
        let detached = git_repository_head_detached(handle) == 1
        let branch = detached
            ? nil
            : git_reference_shorthand(reference).map { String(cString: $0) }

        return Head(branch: branch, referenceName: referenceName, sha: Self.hex(oid))
    }

    /// Whether the repository has no commits yet.
    public func isHeadUnborn() throws -> Bool {
        try head() == nil
    }

    /// Whether the repository has no working directory.
    public var isBare: Bool {
        git_repository_is_bare(handle) == 1
    }

    /// Whether this repository was created as a shallow clone.
    ///
    /// Expected to be `false` for everything this build produces — see
    /// ``SwiftRepositorio/supportsShallowClone``. Exposed anyway because it is the
    /// only honest way to *check*, and because a repository cloned by some other
    /// tool and then opened here can perfectly well be shallow.
    public var isShallow: Bool {
        git_repository_is_shallow(handle) == 1
    }

    /// The working directory, or `nil` for a bare repository.
    public var workingDirectory: String? {
        git_repository_workdir(handle).map { String(cString: $0) }
    }

    // MARK: - Status

    /// What has changed, relative to HEAD and to the index.
    ///
    /// Honours `.gitignore`: ignored files are never reported, and that is not
    /// configurable — see ``StatusOptions/ignoredFilesAreNeverIncluded``.
    public func status(options: StatusOptions = .default) throws -> RepositoryStatus {
        var statusOptions = git_status_options()
        try gitCall("git_status_options_init") {
            git_status_options_init(&statusOptions, UInt32(GIT_STATUS_OPTIONS_VERSION))
        }
        statusOptions.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        statusOptions.flags = options.libgit2Flags

        let repository = handle
        let list = try withUnsafeMutablePointer(to: &statusOptions) { options in
            try gitHandle("git_status_list_new") { out in
                git_status_list_new(&out, repository, options)
            }
        }
        guard let list else {
            throw GitError(
                operation: "git_status_list_new",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "libgit2 reported success but produced no status list"
            )
        }
        defer { git_status_list_free(list) }

        var entries: [RepositoryStatus.Entry] = []
        let count = git_status_list_entrycount(list)
        entries.reserveCapacity(count)

        for index in 0..<count {
            guard let raw = git_status_byindex(list, index)?.pointee else { continue }
            let decoded = RepositoryStatus.decode(raw.status.rawValue)

            // The path comes from head_to_index for staged changes and from
            // index_to_workdir otherwise. Both deltas can be present; either can
            // be NULL. Preferring index_to_workdir's new_file gives the path as it
            // exists on disk now, which is what a user is looking at.
            let path = Self.path(from: raw.index_to_workdir) ?? Self.path(from: raw.head_to_index)
            guard let path else { continue }

            entries.append(
                RepositoryStatus.Entry(
                    path: path,
                    indexChange: decoded.index,
                    worktreeChange: decoded.worktree,
                    previousPath: Self.renamedFrom(raw),
                    isConflicted: decoded.conflicted
                )
            )
        }

        return RepositoryStatus(entries: entries)
    }

    // MARK: - Helpers

    /// 40-character hex for an OID.
    ///
    /// `git_oid_tostr_s` returns a pointer into a static per-thread buffer that
    /// the next call overwrites, so the string is copied immediately. This is the
    /// same class of hazard as `git_error_last()`.
    static func hex(_ oid: UnsafePointer<git_oid>) -> String {
        guard let cString = git_oid_tostr_s(oid) else { return "" }
        return String(cString: cString)
    }

    /// 40-character hex for an OID held by value.
    static func hexString(_ oid: git_oid) -> String {
        withUnsafePointer(to: oid) { hex($0) }
    }

    private static func path(from delta: UnsafeMutablePointer<git_diff_delta>?) -> String? {
        guard let delta else { return nil }
        if let new = delta.pointee.new_file.path { return String(cString: new) }
        if let old = delta.pointee.old_file.path { return String(cString: old) }
        return nil
    }

    private static func renamedFrom(_ entry: git_status_entry) -> String? {
        for delta in [entry.head_to_index, entry.index_to_workdir] {
            guard let delta else { continue }
            guard delta.pointee.status == GIT_DELTA_RENAMED else { continue }
            if let old = delta.pointee.old_file.path { return String(cString: old) }
        }
        return nil
    }
}
