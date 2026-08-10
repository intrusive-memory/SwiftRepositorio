import Foundation
import Synchronization
import Testing

import SwiftRepositorio

/// Fetch, push and fast-forward pull, against a local **bare** repository standing
/// in for a server.
///
/// No network anywhere. A bare repo on disk exercises the real transport code —
/// refspec construction, the callback bridge, ref advancement — with no
/// credentials and no TLS, which is also why none of these tests touch
/// ``HostVerifier``: the local transport never asks. That protocol is tested
/// directly in ``HostVerifierTests``.
@Suite("Remote operations")
struct RemoteTests {

    private static let ada = Author(
        name: "Ada Lovelace",
        email: "ada@example.invalid",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    /// A bare "server" plus a working clone with `origin` pointing at it.
    private struct Setup {
        let server: FixtureRepository
        let working: FixtureRepository
        let repository: GitRepository

        func cleanUp() {
            working.cleanUp()
            server.cleanUp()
        }
    }

    /// Builds a bare remote and a working repository whose first commit has been
    /// pushed to it, so both sides start in agreement.
    private static func makeSetup() async throws -> Setup {
        let server = try FixtureRepository(name: "server", bare: true)
        let working = try FixtureRepository(name: "working")

        try working.writeBytes(Data("first\n".utf8), to: "a.txt")
        let repository = try GitRepository.open(at: working.root.path)
        try await repository.stage(paths: ["a.txt"])
        _ = try await repository.commit(message: "First", author: ada, committer: ada)

        try working.addRemote("origin", url: server.root.path)
        try await repository.push(remote: "origin", branch: "main")

        return Setup(server: server, working: working, repository: repository)
    }

    /// Reads a ref straight out of the bare repository, which is the only way to
    /// know the *server* moved rather than the client believing it did.
    private static func serverSHA(_ setup: Setup, ref: String = "refs/heads/main") throws -> String {
        try RefReader.target(of: ref, in: setup.server.root.path)
    }

    // MARK: - Push

    /// Exit criterion: push succeeds and the remote's ref advances.
    @Test("push advances the bare remote's ref to the local commit")
    func pushAdvancesTheRemoteRef() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        let firstRemote = try Self.serverSHA(setup)
        let localFirst = try #require(try await setup.repository.head()).sha
        #expect(firstRemote == localFirst, "the setup push should already have matched the refs")

        // A second commit, then a second push.
        try setup.working.writeBytes(Data("second\n".utf8), to: "b.txt")
        try await setup.repository.stage(paths: ["b.txt"])
        let secondSHA = try await setup.repository.commit(
            message: "Second",
            author: Self.ada,
            committer: Self.ada
        )
        try await setup.repository.push(remote: "origin", branch: "main")

        let secondRemote = try Self.serverSHA(setup)
        #expect(
            secondRemote == secondSHA,
            """
            after pushing \(secondSHA) the remote is at \(secondRemote).
            The ref did not advance, so the push did not take effect on the server.
            """
        )
        #expect(secondRemote != firstRemote)
    }

    @Test("pushing an unknown remote name reports it, with a message")
    func pushToUnknownRemoteFails() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        do {
            try await setup.repository.push(remote: "nowhere", branch: "main")
            Issue.record("expected a missing remote to be an error")
        } catch let error as GitError {
            #expect(error.isNotFound)
            #expect(error.message.contains("nowhere"))
        }
    }

    @Test("push reports progress")
    func pushReportsProgress() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        try setup.working.writeBytes(Data("more\n".utf8), to: "c.txt")
        try await setup.repository.stage(paths: ["c.txt"])
        _ = try await setup.repository.commit(message: "Third", author: Self.ada, committer: Self.ada)

        let recorder = ProgressRecorder()
        try await setup.repository.push(
            remote: "origin",
            branch: "main",
            options: RemoteOptions(onProgress: { recorder.record($0) })
        )
        #expect(recorder.count > 0, "push_transfer_progress should have fired")
    }

    // MARK: - Fetch

    @Test("fetch updates the remote-tracking ref and leaves the local branch alone")
    func fetchUpdatesTrackingRefOnly() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        // A second clone commits and pushes, so the server moves ahead of `working`.
        let other = try Self.cloneAndAdvance(setup, name: "other", file: "fromOther.txt")

        let beforeHead = try #require(try await setup.repository.head()).sha
        try await setup.repository.fetch(remote: "origin")
        let afterHead = try #require(try await setup.repository.head()).sha

        #expect(afterHead == beforeHead, "fetch must not move the local branch")
        // But the tracking ref must now be the server's commit.
        let tracking = try RefReader.target(
            of: "refs/remotes/origin/main",
            in: setup.working.root.path
        )
        #expect(tracking == other)
        // And the working tree is untouched: the other clone's file is not here.
        #expect(
            !FileManager.default.fileExists(
                atPath: setup.working.root.appendingPathComponent("fromOther.txt").path
            ),
            "fetch must not write to the working tree"
        )
    }

    // MARK: - Ahead / behind

    @Test("aheadBehind counts both directions")
    func aheadBehindCountsBothSides() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        _ = try Self.cloneAndAdvance(setup, name: "other", file: "remote1.txt")
        try await setup.repository.fetch(remote: "origin")

        // Behind by one, ahead by none.
        var comparison = try await setup.repository.aheadBehind(
            local: "refs/heads/main",
            upstream: "refs/remotes/origin/main"
        )
        #expect(comparison == AheadBehind(ahead: 0, behind: 1))
        #expect(comparison.canFastForward)
        #expect(!comparison.hasDiverged)

        // A local commit makes it ahead by one as well: divergent.
        try setup.working.writeBytes(Data("local\n".utf8), to: "local.txt")
        try await setup.repository.stage(paths: ["local.txt"])
        _ = try await setup.repository.commit(message: "Local", author: Self.ada, committer: Self.ada)

        comparison = try await setup.repository.aheadBehind(
            local: "refs/heads/main",
            upstream: "refs/remotes/origin/main"
        )
        #expect(comparison == AheadBehind(ahead: 1, behind: 1))
        #expect(comparison.hasDiverged)
        #expect(!comparison.canFastForward)
    }

    @Test("aheadBehind reports zero on both sides when the refs agree")
    func aheadBehindIsZeroWhenInSync() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }
        try await setup.repository.fetch(remote: "origin")

        let comparison = try await setup.repository.aheadBehind(
            local: "refs/heads/main",
            upstream: "refs/remotes/origin/main"
        )
        #expect(comparison.isUpToDate)
    }

    // MARK: - Fast-forward pull

    @Test("fastForwardPull advances the branch and the working tree when strictly behind")
    func fastForwardPullAdvances() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        let remoteSHA = try Self.cloneAndAdvance(setup, name: "other", file: "pulled.txt")

        let outcome = try await setup.repository.fastForwardPull(remote: "origin")
        #expect(outcome == .fastForwarded(to: remoteSHA))

        let head = try #require(try await setup.repository.head())
        #expect(head.sha == remoteSHA)

        // The checkout must actually have happened — the file has to be on disk.
        let pulled = setup.working.root.appendingPathComponent("pulled.txt")
        #expect(FileManager.default.fileExists(atPath: pulled.path))
        #expect(try Data(contentsOf: pulled) == Data("from other\n".utf8))

        let status = try await setup.repository.status()
        #expect(status.isClean, "after a fast-forward the tree should be clean: \(status.entries.map(\.path))")
    }

    @Test("fastForwardPull reports up-to-date when nothing moved")
    func fastForwardPullUpToDate() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        #expect(try await setup.repository.fastForwardPull(remote: "origin") == .upToDate)
    }

    /// Exit criterion: divergence throws `.divergent` and the working tree is
    /// unchanged afterwards — asserted byte for byte.
    @Test("divergent history throws .divergent and leaves the working tree byte-identical")
    func divergentPullChangesNothing() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        // The server moves.
        let remoteSHA = try Self.cloneAndAdvance(setup, name: "other", file: "theirs.txt")

        // And so does this clone, differently.
        try setup.working.writeBytes(Data("mine, unsaved\n".utf8), to: "mine.txt")
        try await setup.repository.stage(paths: ["mine.txt"])
        let localSHA = try await setup.repository.commit(
            message: "Mine",
            author: Self.ada,
            committer: Self.ada
        )

        // Photograph the whole working tree before the attempt.
        let before = try Self.snapshot(of: setup.working.root)
        let headBefore = try #require(try await setup.repository.head()).sha

        do {
            _ = try await setup.repository.fastForwardPull(remote: "origin")
            Issue.record("expected divergent history to throw")
        } catch let error as PullError {
            guard case let .divergent(local, remote, ahead, behind) = error else {
                Issue.record("expected .divergent, got \(error)")
                return
            }
            #expect(local == localSHA)
            #expect(remote == remoteSHA)
            #expect(ahead == 1)
            #expect(behind == 1)
        }

        // Nothing may have moved. This is the part that matters: a half-applied
        // pull is worse than a refused one, and "the tree is unchanged" has to mean
        // bytes, not just "status looks similar".
        let after = try Self.snapshot(of: setup.working.root)
        #expect(
            after == before,
            """
            the working tree changed during a refused pull.
              before: \(before.keys.sorted())
              after:  \(after.keys.sorted())
            """
        )
        #expect(try #require(try await setup.repository.head()).sha == headBefore)
        #expect(
            !FileManager.default.fileExists(
                atPath: setup.working.root.appendingPathComponent("theirs.txt").path
            ),
            "the remote's file must not have been checked out"
        )
    }

    @Test("fastForwardPull refuses when the local branch is only ahead")
    func fastForwardPullWhenAheadOnly() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        try setup.working.writeBytes(Data("ahead\n".utf8), to: "ahead.txt")
        try await setup.repository.stage(paths: ["ahead.txt"])
        let localSHA = try await setup.repository.commit(
            message: "Ahead",
            author: Self.ada,
            committer: Self.ada
        )

        do {
            _ = try await setup.repository.fastForwardPull(remote: "origin")
            Issue.record("expected localIsAhead")
        } catch let error as PullError {
            guard case let .localIsAhead(local, _, ahead) = error else {
                Issue.record("expected .localIsAhead, got \(error)")
                return
            }
            #expect(local == localSHA)
            #expect(ahead == 1)
        }
    }

    @Test("fastForwardPull on a repository with no commits reports an unborn head")
    func fastForwardPullUnborn() async throws {
        let server = try FixtureRepository(name: "empty-server", bare: true)
        defer { server.cleanUp() }
        let working = try FixtureRepository(name: "empty-working")
        defer { working.cleanUp() }
        try working.addRemote("origin", url: server.root.path)

        let repository = try GitRepository.open(at: working.root.path)
        do {
            _ = try await repository.fastForwardPull(remote: "origin")
            Issue.record("expected headIsUnborn")
        } catch let error as PullError {
            #expect(error == .headIsUnborn)
        }
    }

    // MARK: - Cancellation

    @Test("a cancelled fetch throws .cancelled rather than a git error")
    func cancelledFetchIsDistinct() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        do {
            try await setup.repository.fetch(
                remote: "origin",
                options: RemoteOptions(isCancelled: { true })
            )
            Issue.record("expected the fetch to be cancelled")
        } catch let error as RemoteOperationError {
            // Cancellation must not look like a failure. libgit2 reports an aborted
            // callback as GIT_EUSER with no message, which on its own is
            // indistinguishable from a bug.
            #expect(error == .cancelled)
        }
    }

    @Test("a cancelled push throws .cancelled and the remote does not move")
    func cancelledPushLeavesTheRemoteAlone() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }

        let before = try Self.serverSHA(setup)

        try setup.working.writeBytes(Data("nope\n".utf8), to: "nope.txt")
        try await setup.repository.stage(paths: ["nope.txt"])
        _ = try await setup.repository.commit(message: "Nope", author: Self.ada, committer: Self.ada)

        do {
            try await setup.repository.push(
                remote: "origin",
                branch: "main",
                options: RemoteOptions(isCancelled: { true })
            )
            Issue.record("expected the push to be cancelled")
        } catch let error as RemoteOperationError {
            #expect(error == .cancelled)
        }

        #expect(try Self.serverSHA(setup) == before, "a cancelled push must not advance the remote")
    }

    /// Cancellation mid-flight, rather than before the first callback.
    ///
    /// The pre-flight check catches an already-cancelled task; this proves the
    /// callback bridge itself aborts, by letting the first progress callback through
    /// and refusing from the second onwards.
    @Test("cancelling from inside a progress callback aborts the transfer")
    func cancellingDuringTransferAborts() async throws {
        let setup = try await Self.makeSetup()
        defer { setup.cleanUp() }
        _ = try Self.cloneAndAdvance(setup, name: "other", file: "big.txt")

        let calls = Counter()
        do {
            try await setup.repository.fetch(
                remote: "origin",
                options: RemoteOptions(isCancelled: { calls.increment() > 1 })
            )
            // A tiny fixture may finish inside one callback, in which case there was
            // never a second chance to cancel. That is a legitimate outcome and not
            // a test failure — asserting otherwise would make this depend on the
            // fixture being slow.
        } catch let error as RemoteOperationError {
            #expect(error == .cancelled)
        }
        #expect(calls.value > 0, "the cancellation check should have been consulted")
    }

    // MARK: - Helpers

    /// Clones the server into a second working copy, commits there, and pushes —
    /// so the server ends up ahead of the original clone.
    ///
    /// - Returns: The SHA the server is now at.
    private static func cloneAndAdvance(
        _ setup: Setup,
        name: String,
        file: String
    ) throws -> String {
        let path = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftRepositorioTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
            .path

        // Synchronous bridge: these helpers run inside an async test but the actor
        // calls need awaiting, so the work is done in a nested task-free way via
        // the fixture's own C helpers instead.
        return try FixtureClone.cloneCommitAndPush(
            from: setup.server.root.path,
            to: path,
            fileName: file,
            contents: Data("from other\n".utf8)
        )
    }

    /// Every regular file in the **working tree**, path → bytes. `.git` excluded.
    ///
    /// The basis of "the working tree is unchanged": bytes, because a pull that
    /// rewrote line endings or truncated a file would leave the file list identical.
    ///
    /// `.git` is excluded by path *component*, not by a string prefix. The first
    /// version stripped `root.path + "/"` from each URL and got nothing done,
    /// because `NSTemporaryDirectory()` hands back `/var/folders/…` while the
    /// enumerator yields the resolved `/private/var/folders/…`. Keys came out as
    /// "/privatea.txt", nothing matched the `.git/` test, and the assertion then
    /// failed on `FETCH_HEAD` and a new packfile — which a fetch is supposed to
    /// write. Comparing components is immune to that, and to any other symlink on
    /// the way to the temp directory.
    private static func snapshot(of root: URL) throws -> [String: Data] {
        let rootComponents = root.resolvingSymlinksInPath().pathComponents
        var result: [String: Data] = [:]

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )
        while let url = enumerator?.nextObject() as? URL {
            let components = url.resolvingSymlinksInPath().pathComponents

            // Everything git owns. A fetch legitimately writes FETCH_HEAD, objects
            // and tracking refs even when the pull that follows refuses, so
            // including them would assert something untrue.
            guard !components.contains(".git") else { continue }

            guard components.count > rootComponents.count else { continue }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")

            guard let isFile = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile,
                  isFile
            else { continue }
            result[relative] = try Data(contentsOf: url)
        }
        return result
    }
}

/// A counter usable from a `@Sendable` closure without asserting unchecked safety.
final class Counter: Sendable {
    private let count = Mutex(0)

    /// Increments and returns the value *before* the increment, so the first call
    /// reports 0.
    @discardableResult
    func increment() -> Int {
        count.withLock { value in
            defer { value += 1 }
            return value
        }
    }

    var value: Int { count.withLock { $0 } }
}
