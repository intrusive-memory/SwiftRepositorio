import Foundation

import Clibgit2

/// How far apart two commits are.
public struct AheadBehind: Sendable, Equatable {
    /// Commits the local side has that the upstream does not.
    public let ahead: Int
    /// Commits the upstream has that the local side does not.
    public let behind: Int

    public init(ahead: Int, behind: Int) {
        self.ahead = ahead
        self.behind = behind
    }

    /// Nothing to do in either direction.
    public var isUpToDate: Bool { ahead == 0 && behind == 0 }
    /// Strictly behind — the only state a fast-forward is valid from.
    public var canFastForward: Bool { ahead == 0 && behind > 0 }
    /// Both sides have commits the other lacks.
    public var hasDiverged: Bool { ahead > 0 && behind > 0 }
}

/// What a fast-forward pull did.
public enum PullOutcome: Sendable, Equatable {
    /// Already at the upstream's commit.
    case upToDate
    /// The branch moved to `sha`, and the working tree with it.
    case fastForwarded(to: String)
}

/// Why a pull could not be a fast-forward.
public enum PullError: Error, Sendable, Equatable {

    /// Both sides have commits the other does not.
    ///
    /// The working tree and the index are untouched when this is thrown — the check
    /// happens before anything is written. Resolving it means a merge or a rebase,
    /// neither of which this package performs; see the note on
    /// ``GitRepository/fastForwardPull(remote:options:)``.
    case divergent(local: String, remote: String, ahead: Int, behind: Int)

    /// The local branch is ahead only, so there is nothing to pull.
    case localIsAhead(local: String, remote: String, ahead: Int)

    /// HEAD is not on a branch, so there is nothing to move.
    case headIsDetached(sha: String)

    /// HEAD has no commits yet.
    case headIsUnborn

    /// The remote does not have the branch HEAD is on.
    case upstreamNotFound(branch: String, remote: String)
}

extension GitRepository {

    // MARK: - Fetch

    /// Fetches from a remote, updating the remote-tracking refs.
    ///
    /// Nothing local moves: this updates `refs/remotes/<remote>/*` and leaves the
    /// working tree, the index and every local branch alone. Use
    /// ``fastForwardPull(remote:options:)`` to advance a branch afterwards.
    ///
    /// - Parameter remote: Remote name, usually `"origin"`.
    public func fetch(
        remote: String = "origin",
        options: RemoteOptions = .default
    ) throws {
        if options.isCancelled() { throw RemoteOperationError.cancelled }

        let repository = handle
        let remoteHandle = try gitHandle("git_remote_lookup") { out in
            git_remote_lookup(&out, repository, remote)
        }
        guard let remoteHandle else {
            throw GitError(
                operation: "git_remote_lookup",
                code: GIT_ENOTFOUND.rawValue,
                klass: -1,
                message: "no remote named '\(remote)'"
            )
        }
        defer { git_remote_free(remoteHandle) }

        let context = RemoteCallbackContext(options: options)
        var fetchOptions = git_fetch_options()
        try gitCall("git_fetch_options_init") {
            git_fetch_options_init(&fetchOptions, UInt32(GIT_FETCH_OPTIONS_VERSION))
        }
        fetchOptions.callbacks = try context.makeCallbacks()

        do {
            try gitCall("git_remote_fetch") {
                // NULL refspecs means "use the remote's configured refspecs",
                // which for a normal clone is refs/heads/*:refs/remotes/<name>/*.
                // Nothing here constructs a refspec, so nothing here can construct
                // one with a leading '+'.
                git_remote_fetch(remoteHandle, nil, &fetchOptions, "fetch")
            }
        } catch let error as GitError {
            throw context.mapError(error)
        }
        withExtendedLifetime(context) {}
    }

    // MARK: - Push
    //
    // NOTE ON THE ABSENT FORCE FLAG. Nothing public in this package takes a force
    // parameter, and nothing internal constructs a force refspec — the `+` prefix
    // that git's syntax uses to mean "overwrite whatever is there" is never
    // written. `GIT_CHECKOUT_FORCE` is likewise never used; every checkout in this
    // package is `GIT_CHECKOUT_SAFE`, which refuses rather than discards.
    //
    // A force push discards commits that exist only on the remote — someone else's
    // work, usually, and irrecoverably from the client's point of view. A document
    // editor should not be able to do that by passing `true`. Anyone who genuinely
    // needs to rewrite a published branch can do it with a tool built for the job,
    // deliberately, somewhere this package is not involved.

    /// Pushes a branch to a remote.
    ///
    /// ## There is no way to make this overwrite anything
    ///
    /// The refspec is built here, from the branch name, and it never carries the
    /// leading `+` that git's syntax uses to mean "overwrite whatever is there".
    /// The remote's own check then applies: a push that is not a fast-forward is
    /// rejected by the server, and this method surfaces that rejection.
    ///
    /// No parameter changes that. There is no flag, no option struct field, and no
    /// second method — a caller who wants to discard commits on a remote has to do
    /// it with a different tool, deliberately, somewhere this package is not
    /// involved. Losing someone else's commits is not a thing a document editor
    /// should be able to do by passing `true`.
    ///
    /// - Parameters:
    ///   - remote: Remote name.
    ///   - branch: Local branch to push. It is pushed to the same name on the
    ///     remote.
    public func push(
        remote: String = "origin",
        branch: String,
        options: RemoteOptions = .default
    ) throws {
        if options.isCancelled() { throw RemoteOperationError.cancelled }

        let repository = handle
        let remoteHandle = try gitHandle("git_remote_lookup") { out in
            git_remote_lookup(&out, repository, remote)
        }
        guard let remoteHandle else {
            throw GitError(
                operation: "git_remote_lookup",
                code: GIT_ENOTFOUND.rawValue,
                klass: -1,
                message: "no remote named '\(remote)'"
            )
        }
        defer { git_remote_free(remoteHandle) }

        let context = RemoteCallbackContext(options: options)
        var pushOptions = git_push_options()
        try gitCall("git_push_options_init") {
            git_push_options_init(&pushOptions, UInt32(GIT_PUSH_OPTIONS_VERSION))
        }
        pushOptions.callbacks = try context.makeCallbacks()

        // Plain source:destination. Deliberately no '+' prefix — see above.
        let refspec = "refs/heads/\(branch):refs/heads/\(branch)"

        do {
            try Self.withStringArray([refspec]) { array in
                var array = array
                try gitCall("git_remote_push") {
                    git_remote_push(remoteHandle, &array, &pushOptions)
                }
            }
        } catch let error as GitError {
            throw context.mapError(error)
        }
        withExtendedLifetime(context) {}
    }

    // MARK: - Comparing

    /// How far `local` and `upstream` have drifted apart.
    ///
    /// - Parameters:
    ///   - local: A revision — a branch name, a SHA, anything
    ///     `git_revparse_single` accepts.
    ///   - upstream: The revision to compare against.
    public func aheadBehind(local: String, upstream: String) throws -> AheadBehind {
        let repository = handle
        let localOID = try resolveOID(revision: local)
        let upstreamOID = try resolveOID(revision: upstream)

        var ahead = 0
        var behind = 0
        try withUnsafePointer(to: localOID) { localPointer in
            try withUnsafePointer(to: upstreamOID) { upstreamPointer in
                try gitCall("git_graph_ahead_behind") {
                    git_graph_ahead_behind(&ahead, &behind, repository, localPointer, upstreamPointer)
                }
            }
        }
        return AheadBehind(ahead: ahead, behind: behind)
    }

    // MARK: - Fast-forward pull

    /// Fetches, then advances the current branch **only** if it is strictly behind.
    ///
    /// ## No merge, ever
    ///
    /// When both sides have commits the other lacks, this throws
    /// ``PullError/divergent(local:remote:ahead:behind:)`` and changes nothing. It
    /// does not merge, does not rebase, and does not create a merge commit.
    ///
    /// That is a product decision, not a missing feature. A merge can conflict, and
    /// resolving a conflict in a screenplay means a human reading two versions of a
    /// scene and deciding — there is no correct automatic answer, and a
    /// half-resolved merge left in the working tree is worse than a refusal. The
    /// refusal is also *safe*: the check runs before any write, so a throw leaves
    /// the working tree byte-for-byte as it was.
    ///
    /// The fast-forward itself uses `GIT_CHECKOUT_SAFE`, which refuses rather than
    /// discards when the working tree has local modifications that the checkout
    /// would need to overwrite. The stronger checkout strategy exists in libgit2
    /// and is not used anywhere in this package.
    @discardableResult
    public func fastForwardPull(
        remote: String = "origin",
        options: RemoteOptions = .default
    ) throws -> PullOutcome {
        try fetch(remote: remote, options: options)

        guard let head = try head() else { throw PullError.headIsUnborn }
        guard let branch = head.branch else { throw PullError.headIsDetached(sha: head.sha) }

        let trackingRef = "refs/remotes/\(remote)/\(branch)"
        let remoteOID: git_oid
        do {
            remoteOID = try resolveOID(revision: trackingRef)
        } catch let error as GitError where error.isNotFound {
            throw PullError.upstreamNotFound(branch: branch, remote: remote)
        }
        let remoteSHA = Self.hexString(remoteOID)

        let comparison = try aheadBehind(local: head.sha, upstream: remoteSHA)

        if comparison.isUpToDate { return .upToDate }
        if comparison.hasDiverged {
            throw PullError.divergent(
                local: head.sha,
                remote: remoteSHA,
                ahead: comparison.ahead,
                behind: comparison.behind
            )
        }
        if comparison.ahead > 0 {
            throw PullError.localIsAhead(local: head.sha, remote: remoteSHA, ahead: comparison.ahead)
        }

        // Strictly behind: the only state from which advancing the ref is a
        // fast-forward rather than a rewrite.
        try checkoutAndMoveBranch(to: remoteOID, branch: branch, referenceName: head.referenceName)
        return .fastForwarded(to: remoteSHA)
    }

    /// Checks out a commit's tree, then points the branch at it.
    ///
    /// Order matters: the checkout happens first, so a checkout that refuses leaves
    /// the reference where it was. Moving the ref first and then failing to check
    /// out would leave the working tree describing one commit while HEAD claimed
    /// another — a state that reads as uncommitted changes to every subsequent
    /// status call.
    private func checkoutAndMoveBranch(
        to oid: git_oid,
        branch: String,
        referenceName: String
    ) throws {
        let repository = handle

        let commit = try withUnsafePointer(to: oid) { pointer in
            try gitHandle("git_commit_lookup") { out in
                git_commit_lookup(&out, repository, pointer)
            }
        }
        guard let commit else {
            throw GitError(
                operation: "git_commit_lookup",
                code: GIT_ENOTFOUND.rawValue,
                klass: -1,
                message: "the fetched commit could not be looked up"
            )
        }
        defer { git_commit_free(commit) }

        var checkoutOptions = git_checkout_options()
        try gitCall("git_checkout_options_init") {
            git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        }
        // SAFE updates files that have not been touched locally and refuses when
        // it would have to discard a local edit. That refusal is the desired
        // behaviour: the user's unsaved work outranks the remote's history.
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

        try gitCall("git_checkout_tree") {
            git_checkout_tree(repository, commit, &checkoutOptions)
        }

        let reference = try gitHandle("git_reference_lookup") { out in
            git_reference_lookup(&out, repository, referenceName)
        }
        guard let reference else {
            throw GitError(
                operation: "git_reference_lookup",
                code: GIT_ENOTFOUND.rawValue,
                klass: -1,
                message: "branch '\(branch)' disappeared during the pull"
            )
        }
        defer { git_reference_free(reference) }

        let moved = try withUnsafePointer(to: oid) { pointer in
            try gitHandle("git_reference_set_target") { out in
                git_reference_set_target(&out, reference, pointer, "pull: fast-forward")
            }
        }
        if let moved { git_reference_free(moved) }
    }

    // MARK: - Helpers

    /// Resolves any revision string to an OID.
    func resolveOID(revision: String) throws -> git_oid {
        let repository = handle
        let object = try gitHandle("git_revparse_single(\(revision))") { out in
            git_revparse_single(&out, repository, revision)
        }
        guard let object else {
            throw GitError(
                operation: "git_revparse_single",
                code: GIT_ENOTFOUND.rawValue,
                klass: -1,
                message: "could not resolve '\(revision)'"
            )
        }
        defer { git_object_free(object) }
        guard let oid = git_object_id(object) else {
            throw GitError(
                operation: "git_object_id",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "'\(revision)' resolved to an object with no id"
            )
        }
        return oid.pointee
    }

    /// Runs `body` with a `git_strarray` over `strings`.
    ///
    /// The array borrows the strings' buffers, so everything has to stay alive for
    /// the duration of the call — which nesting inside a closure guarantees and a
    /// returned struct would not.
    static func withStringArray<T>(
        _ strings: [String],
        _ body: (git_strarray) throws -> T
    ) throws -> T {
        let cStrings: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }

        return try cStrings.withUnsafeBufferPointer { buffer in
            let array = git_strarray(
                strings: UnsafeMutablePointer(mutating: buffer.baseAddress),
                count: strings.count
            )
            return try body(array)
        }
    }
}
