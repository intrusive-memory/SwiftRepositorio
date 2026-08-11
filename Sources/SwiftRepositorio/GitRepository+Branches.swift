import Foundation

import Clibgit2

/// Local-branch primitives: list, create, switch, and read the current name.
///
/// Escribir's Source Control ▸ Switch Branch menu needs these as building blocks;
/// the app-side orchestrator owns the policy (refusing to switch out of a dirty
/// tree, sequencing create-then-checkout) and calls straight through to what is
/// here. Nothing in this file makes a policy decision on the caller's behalf
/// beyond the one structural guarantee the whole package makes everywhere else:
/// no force, ever — see the note on ``GitRepository/push(remote:branch:options:)``
/// in `GitRepository+Remote.swift`. `switchBranch(to:)` uses `GIT_CHECKOUT_SAFE`,
/// the same idiom ``GitRepository``'s private `checkoutAndMoveBranch` uses for a
/// fast-forward pull, and for the same reason: a working tree libgit2 would have
/// to discard local edits from is refused rather than overwritten.
extension GitRepository {

    // MARK: - Listing

    /// Local branch short names (e.g. `"main"`, `"feature/x"`), sorted.
    ///
    /// Walks `git_branch_iterator_new(GIT_BRANCH_LOCAL)` to `GIT_ITEROVER`. Each
    /// reference the iterator hands back is freed before the next one is
    /// requested — nothing here holds more than one branch reference open at a
    /// time.
    ///
    /// Sorted rather than iteration order, which libgit2 does not document or
    /// guarantee: a menu built from this list should not silently reorder itself
    /// between runs for reasons that have nothing to do with the repository.
    ///
    /// An unborn repository — created but with no commits yet — has no entries
    /// under `refs/heads/` at all, so this returns `[]` until the first commit
    /// exists. That is a real, normal state, not a failure; see
    /// ``currentBranchName()`` for the one query that *does* work before the
    /// first commit.
    public func localBranches() throws -> [String] {
        let repository = handle

        let iterator = try gitHandle("git_branch_iterator_new") { out in
            git_branch_iterator_new(&out, repository, GIT_BRANCH_LOCAL)
        }
        guard let iterator else {
            throw GitError(
                operation: "git_branch_iterator_new",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "libgit2 reported success but produced no iterator"
            )
        }
        defer { git_branch_iterator_free(iterator) }

        var names: [String] = []
        while true {
            // `git_branch_next` writes the branch's kind (local vs. remote-
            // tracking) alongside the reference. The iterator is scoped to
            // GIT_BRANCH_LOCAL above, so this is always GIT_BRANCH_LOCAL back —
            // captured because `git_branch_next` requires the out-parameter, not
            // because this method needs the value.
            var branchType = GIT_BRANCH_LOCAL
            let reference = try gitHandle(
                "git_branch_next",
                tolerating: [GIT_ITEROVER]
            ) { out in
                git_branch_next(&out, &branchType, iterator)
            }
            // GIT_ITEROVER is how the iterator says "done", not "broken" — same
            // convention as the revwalk in the test target's CommitCounter.
            guard let reference else { break }
            defer { git_reference_free(reference) }

            // `git_branch_name`'s out-pointer is owned by `reference` and must
            // not be freed separately; it is only valid until `reference` is
            // freed, which is why the copy into a Swift `String` happens before
            // the `defer` above runs.
            var namePointer: UnsafePointer<CChar>?
            try gitCall("git_branch_name") {
                git_branch_name(&namePointer, reference)
            }
            guard let namePointer else {
                throw GitError(
                    operation: "git_branch_name",
                    code: GIT_ERROR.rawValue,
                    klass: -1,
                    message: "libgit2 reported success but produced no branch name"
                )
            }
            names.append(String(cString: namePointer))
        }
        return names.sorted()
    }

    // MARK: - Current branch

    /// The short name of the branch HEAD is on, or `nil` when HEAD is detached.
    ///
    /// ## Why this reads HEAD's symbolic target directly, rather than reusing
    /// ``head()``
    ///
    /// ``head()`` answers "what commit and branch is checked out", and reports
    /// `nil` for an unborn repository because there is no commit to describe —
    /// that is the right answer to *that* question. This asks a narrower one:
    /// "what branch name would the next commit land on", which is answerable the
    /// moment `git_repository_init_ext` writes `HEAD` — before any commit exists
    /// — because `HEAD` is a symbolic reference to `refs/heads/<name>` from the
    /// start, whether or not `refs/heads/<name>` itself exists yet. `git
    /// symbolic-ref HEAD` and `git rev-parse --abbrev-ref HEAD` both answer this
    /// way on a fresh repository; this mirrors that rather than piggy-backing on
    /// commit resolution.
    ///
    /// Detachment is read the same way `head()` reads it, via the reference's
    /// *type*: `GIT_REFERENCE_DIRECT` means HEAD points straight at a commit,
    /// which is what a detached checkout looks like, and this returns `nil` for
    /// it rather than attempting to name a branch that HEAD is not on.
    public func currentBranchName() throws -> String? {
        let repository = handle

        let reference = try gitHandle("git_reference_lookup(HEAD)") { out in
            git_reference_lookup(&out, repository, "HEAD")
        }
        guard let reference else {
            // Nothing is `tolerating` above, so this branch is unreachable in
            // practice — HEAD always exists once a repository has been created
            // or opened — but a nil handle paired with a success code is a
            // libgit2 contract violation, not a legitimate "detached" answer,
            // so it is reported as the error it would be rather than folded
            // into the same `nil` this method uses for detached HEAD.
            throw GitError(
                operation: "git_reference_lookup(HEAD)",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "libgit2 reported success but produced no HEAD reference"
            )
        }
        defer { git_reference_free(reference) }

        guard git_reference_type(reference) == GIT_REFERENCE_SYMBOLIC else {
            // HEAD names a commit directly: detached.
            return nil
        }

        guard let targetPointer = git_reference_symbolic_target(reference) else {
            return nil
        }
        let target = String(cString: targetPointer)

        let prefix = "refs/heads/"
        guard target.hasPrefix(prefix) else {
            // HEAD is symbolic but not aimed at a local branch (e.g. mid-rebase
            // machinery some other tool left behind). Nothing this package
            // writes produces that, but reading it should not crash on it.
            return nil
        }
        return String(target.dropFirst(prefix.count))
    }

    // MARK: - Creating

    /// Creates a branch at HEAD's commit, without checking it out.
    ///
    /// The caller sequences create-then-switch itself — this does one thing.
    /// Combining the two into a single call would mean a checkout failure (a
    /// dirty working tree, say) left a caller unsure whether the branch had been
    /// created; keeping them separate makes that always unambiguous, and lets
    /// the app's dirty-tree refusal run *before* anything is created at all.
    ///
    /// - Parameter name: The new branch's name. `git_branch_create` validates it
    ///   (the same rules `git_tag_create` documents) and this does not duplicate
    ///   that logic — an empty string is rejected here only because libgit2
    ///   itself does not reliably distinguish "empty" from other malformed input
    ///   with a message worth showing a user.
    public func createBranch(named name: String) throws {
        guard !name.isEmpty else {
            throw GitError(
                operation: "git_branch_create",
                code: GIT_EINVALIDSPEC.rawValue,
                klass: -1,
                message: "branch name must not be empty"
            )
        }

        let repository = handle
        // Reuses the same revparse-based OID resolution `aheadBehind` and
        // `fastForwardPull` use in GitRepository+Remote.swift. "HEAD" fails
        // naturally (GIT_ENOTFOUND / unborn) on a repository with no commits
        // yet — there is no commit to branch from, so nothing here needs to
        // special-case that state separately.
        let headOID = try resolveOID(revision: "HEAD")

        let commit = try withUnsafePointer(to: headOID) { pointer in
            try gitHandle("git_commit_lookup") { out in
                git_commit_lookup(&out, repository, pointer)
            }
        }
        guard let commit else {
            throw GitError(
                operation: "git_commit_lookup",
                code: GIT_ENOTFOUND.rawValue,
                klass: -1,
                message: "HEAD's commit could not be looked up"
            )
        }
        defer { git_commit_free(commit) }

        // `force: 0` — always. See the note on the absent force flag in
        // GitRepository+Remote.swift: this package writes no `1` anywhere.
        // git_branch_create refuses when `name` already exists rather than
        // overwriting it, which is the correct behaviour here too.
        let branchReference = try gitHandle("git_branch_create(\(name))") { out in
            git_branch_create(&out, repository, name, commit, 0)
        }
        if let branchReference { git_reference_free(branchReference) }
    }

    // MARK: - Switching

    /// Checks out `name`'s tree and moves HEAD to it.
    ///
    /// Mirrors ``GitRepository``'s private `checkoutAndMoveBranch(to:branch:
    /// referenceName:)` (`GitRepository+Remote.swift`), which the fast-forward
    /// pull path uses: checkout first, move the ref second. A checkout that
    /// refuses leaves HEAD exactly where it was; moving HEAD first and then
    /// failing to check out would leave the working tree describing one commit
    /// while HEAD claimed another, which every subsequent `status()` call would
    /// then report as a pile of uncommitted changes that do not actually exist.
    ///
    /// ## `GIT_CHECKOUT_SAFE`, not `GIT_CHECKOUT_FORCE`
    ///
    /// Exactly the idiom that method uses, and for the same reason: a file with
    /// local, uncommitted changes that the checkout would need to overwrite makes
    /// libgit2 refuse rather than discard it. That refusal is surfaced here
    /// faithfully, as a `GitError`, with no attempt to soften or reinterpret it —
    /// the app's own dirty-tree pre-check is belt, this is braces. Nothing in
    /// this package ever constructs `GIT_CHECKOUT_FORCE`.
    ///
    /// - Parameter name: A local branch's short name, e.g. `"main"`. Resolved as
    ///   `refs/heads/<name>`; a name with no matching local branch throws
    ///   `GIT_ENOTFOUND`.
    public func switchBranch(to name: String) throws {
        guard !name.isEmpty else {
            throw GitError(
                operation: "git_repository_set_head",
                code: GIT_EINVALIDSPEC.rawValue,
                klass: -1,
                message: "branch name must not be empty"
            )
        }

        let repository = handle
        let referenceName = "refs/heads/\(name)"

        let reference = try gitHandle("git_reference_lookup") { out in
            git_reference_lookup(&out, repository, referenceName)
        }
        guard let reference else {
            throw GitError(
                operation: "git_reference_lookup",
                code: GIT_ENOTFOUND.rawValue,
                klass: -1,
                message: "no local branch named '\(name)'"
            )
        }
        defer { git_reference_free(reference) }

        guard let oid = git_reference_target(reference) else {
            throw GitError(
                operation: "git_reference_target",
                code: GIT_ERROR.rawValue,
                klass: -1,
                message: "branch '\(name)' resolved to a reference with no direct target"
            )
        }

        let commit = try gitHandle("git_commit_lookup") { out in
            git_commit_lookup(&out, repository, oid)
        }
        guard let commit else {
            throw GitError(
                operation: "git_commit_lookup",
                code: GIT_ENOTFOUND.rawValue,
                klass: -1,
                message: "branch '\(name)'s commit could not be looked up"
            )
        }
        defer { git_commit_free(commit) }

        var checkoutOptions = git_checkout_options()
        try gitCall("git_checkout_options_init") {
            git_checkout_options_init(&checkoutOptions, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
        }
        // SAFE updates files untouched locally and refuses when it would have to
        // discard a local edit — see the note above.
        checkoutOptions.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue

        try gitCall("git_checkout_tree") {
            git_checkout_tree(repository, commit, &checkoutOptions)
        }

        // Only reached once the checkout has actually succeeded.
        try gitCall("git_repository_set_head") {
            git_repository_set_head(repository, referenceName)
        }
    }
}
