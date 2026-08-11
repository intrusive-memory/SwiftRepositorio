import Foundation
import Synchronization
import Testing

import Clibgit2
import SwiftRepositorio

/// Read paths against real repositories built in a temporary directory.
///
/// No network anywhere in this suite. Every fixture is created by libgit2 in
/// `NSTemporaryDirectory()`, so the tests are deterministic, run offline, and
/// exercise the same transports a local clone uses in the app.
@Suite("Repository read paths")
struct GitRepositoryTests {

    // MARK: - Open

    @Test("opens a repository created by libgit2")
    func opensAFixture() throws {
        let (fixture, _) = try FixtureRepository.withInitialCommit()
        defer { fixture.cleanUp() }

        let repository = try GitRepository.open(at: fixture.root.path)
        #expect(repository.path == fixture.root.path)
    }

    @Test("opening a path that is not a repository fails with a message")
    func openingANonRepositoryFails() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftRepositorioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        do {
            _ = try GitRepository.open(at: empty.path)
            Issue.record("expected git_repository_open to fail on a directory with no repository")
        } catch let error as GitError {
            #expect(error.isNotFound, "expected GIT_ENOTFOUND, got code \(error.code)")
            // The point of the whole error-capture design. If the thread-local
            // read were happening on the wrong thread this would be empty, and
            // the failure would be a missing diagnostic rather than a crash —
            // which is exactly why it needs a test rather than a code review.
            #expect(
                error.hasMessage,
                """
                libgit2 reported \(error.code) with no message. Either git_error_last() \
                was read on a different thread than the failing call, or a suspension \
                point crept between them. See GitError.swift.
                """
            )
            #expect(error.operation == "git_repository_open")
        }
    }

    @Test("discover finds a repository from a subdirectory, and nothing from elsewhere")
    func discoverWalksUp() throws {
        let (fixture, _) = try FixtureRepository.withInitialCommit()
        defer { fixture.cleanUp() }
        try fixture.write("x\n", to: "nested/deeper/file.txt")

        let found = try GitRepository.discover(
            from: fixture.root.appendingPathComponent("nested/deeper").path
        )
        #expect(found != nil, "discover should walk up to the repository root")

        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftRepositorioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        #expect(try GitRepository.discover(from: elsewhere.path) == nil)
    }

    // MARK: - Create

    /// A freshly created repository has an unborn HEAD, exactly like a fresh
    /// `git_repository_init` — the same state `FixtureRepository(name:)`'s
    /// hand-rolled `git_repository_init_ext` call produced before `create(at:bare:initialBranch:)`
    /// existed to replace it for callers outside this package.
    @Test("create produces an empty repository with an unborn HEAD")
    func createProducesAnEmptyRepositoryWithUnbornHead() async throws {
        let path = Self.temporaryPath("created")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let repository = try GitRepository.create(at: path)

        #expect(try await repository.head() == nil)
        #expect(try await repository.isHeadUnborn())
        #expect(await repository.isBare == false)
        #expect(await repository.workingDirectory != nil)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// `create(at:)` makes the destination directory itself, including missing
    /// parent directories — a caller building a fixture under a fresh temporary
    /// directory should not have to `mkdir -p` it first.
    @Test("create makes missing parent directories")
    func createMakesMissingParentDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftRepositorioTests-\(UUID().uuidString)")
        let path = root.appendingPathComponent("nested/two/levels/deep").path
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try GitRepository.create(at: path)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("a bare create has no working directory")
    func bareCreateHasNoWorkingDirectory() async throws {
        let path = Self.temporaryPath("created-bare")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let repository = try GitRepository.create(at: path, bare: true)
        #expect(await repository.isBare)
        #expect(await repository.workingDirectory == nil)
    }

    /// `initialBranch` cannot be observed before the first commit — `head()`
    /// reports `nil` for an unborn HEAD by design (see ``headIsNilWhenUnborn()``
    /// above) rather than revealing the branch a first commit would land on. So
    /// this proves the parameter the only way it is observable: commit through the
    /// created repository's own write API (Sortie 3) and read HEAD back.
    @Test("create's initialBranch names the branch the first commit lands on")
    func createInitialBranchNamesTheFirstCommit() async throws {
        let path = Self.temporaryPath("created-trunk")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let repository = try GitRepository.create(at: path, initialBranch: "trunk")
        let workdir = try #require(await repository.workingDirectory)
        try "hello\n".write(
            toFile: workdir + "/greeting.txt", atomically: true, encoding: .utf8)
        try await repository.stage(paths: ["greeting.txt"])
        let author = Author(name: "SwiftRepositorio Tests", email: "tests@example.invalid")
        let sha = try await repository.commit(message: "Initial commit", author: author, committer: author)

        let head = try #require(try await repository.head())
        #expect(head.branch == "trunk")
        #expect(head.referenceName == "refs/heads/trunk")
        #expect(head.sha == sha)
    }

    /// The end-to-end fixture-building round trip this method exists for:
    /// create → write a real file → stage → commit → open a clone from it. Every
    /// step goes through this package's own public API, with no `Process`, no
    /// committed fixture bytes, and no dependency on a `git` binary being present.
    @Test("a created-then-committed repository clones like any other")
    func createdRepositoryCanBeClonedFrom() async throws {
        let sourcePath = Self.temporaryPath("created-source")
        defer { try? FileManager.default.removeItem(atPath: sourcePath) }

        let source = try GitRepository.create(at: sourcePath)
        let workdir = try #require(await source.workingDirectory)
        try "# Fixture\n".write(toFile: workdir + "/README.md", atomically: true, encoding: .utf8)
        try await source.stage(paths: ["README.md"])
        let author = Author(name: "SwiftRepositorio Tests", email: "tests@example.invalid")
        let sourceSHA = try await source.commit(
            message: "Initial commit", author: author, committer: author)

        let destinationPath = Self.temporaryPath("created-clone")
        defer { try? FileManager.default.removeItem(atPath: destinationPath) }

        let clone = try GitRepository.clone(from: sourcePath, to: destinationPath)
        let head = try #require(try await clone.head())
        #expect(head.sha == sourceSHA)
        #expect(head.branch == "main")
    }

    // MARK: - Head

    @Test("head returns the branch and the SHA of the commit")
    func headReportsBranchAndSHA() async throws {
        let (fixture, sha) = try FixtureRepository.withInitialCommit()
        defer { fixture.cleanUp() }

        let repository = try GitRepository.open(at: fixture.root.path)
        let head = try await repository.head()

        let resolved = try #require(head, "a fixture with one commit must have a resolvable HEAD")
        #expect(resolved.sha == sha)
        #expect(resolved.branch == "main")
        #expect(resolved.referenceName == "refs/heads/main")
        #expect(!resolved.isDetached)
        #expect(resolved.sha.count == 40, "expected a full hex OID, got \(resolved.sha)")
    }

    @Test("head is nil on a repository with no commits, rather than throwing")
    func headIsNilWhenUnborn() async throws {
        let fixture = try FixtureRepository(name: "empty")
        defer { fixture.cleanUp() }

        let repository = try GitRepository.open(at: fixture.root.path)
        // GIT_EUNBORNBRANCH is a normal state for a freshly initialised
        // repository, so it must not surface as an error every caller has to
        // catch.
        #expect(try await repository.head() == nil)
        #expect(try await repository.isHeadUnborn())
    }

    // MARK: - Clone

    @Test("cloning a local fixture reproduces the source's HEAD SHA")
    func cloneReproducesHeadSHA() async throws {
        let (source, sourceSHA) = try FixtureRepository.withInitialCommit()
        defer { source.cleanUp() }

        let destination = Self.temporaryPath("clone")
        defer { try? FileManager.default.removeItem(atPath: destination) }

        let clone = try GitRepository.clone(from: source.root.path, to: destination)
        let head = try #require(try await clone.head())

        #expect(head.sha == sourceSHA, "the clone's HEAD must be the commit the source is on")
        #expect(head.branch == "main")

        // A working copy, not just an object database: the file has to be on disk.
        let checkedOut = URL(fileURLWithPath: destination).appendingPathComponent("README.md")
        #expect(
            FileManager.default.fileExists(atPath: checkedOut.path),
            "GIT_CHECKOUT_SAFE should have written the working directory"
        )
        #expect(await clone.isBare == false)
        #expect(await clone.workingDirectory != nil)
    }

    @Test("a bare clone has the same HEAD and no working directory")
    func bareCloneHasNoWorkingDirectory() async throws {
        let (source, sourceSHA) = try FixtureRepository.withInitialCommit()
        defer { source.cleanUp() }

        let destination = Self.temporaryPath("bare")
        defer { try? FileManager.default.removeItem(atPath: destination) }

        let clone = try GitRepository.clone(
            from: source.root.path,
            to: destination,
            options: CloneOptions(bare: true)
        )
        let head = try #require(try await clone.head())
        #expect(head.sha == sourceSHA)
        #expect(await clone.isBare)
        #expect(await clone.workingDirectory == nil)
    }

    @Test("checkoutBranch selects a branch other than the default")
    func cloneChecksOutTheRequestedBranch() async throws {
        let (source, _) = try FixtureRepository.withInitialCommit()
        defer { source.cleanUp() }

        // A second branch pointing at the same commit is enough: the assertion is
        // about which ref HEAD ends up on, not about divergent history.
        try source.createBranch("feature")

        let destination = Self.temporaryPath("branch")
        defer { try? FileManager.default.removeItem(atPath: destination) }

        let clone = try GitRepository.clone(
            from: source.root.path,
            to: destination,
            options: CloneOptions(checkoutBranch: "feature")
        )
        let head = try #require(try await clone.head())
        #expect(head.branch == "feature")
    }

    @Test("the transfer-progress callback is invoked during a real fetch")
    func progressCallbackFires() async throws {
        let (source, _) = try FixtureRepository.withInitialCommit()
        defer { source.cleanUp() }

        let destination = Self.temporaryPath("progress")
        defer { try? FileManager.default.removeItem(atPath: destination) }

        // `.neverLocal` forces the git-aware transport. With the default
        // `.auto`, libgit2 copies the object database for a plain local path and
        // never fetches, so no transfer progress is reported at all — the
        // callback would appear broken when it is the strategy that skipped it.
        let recorder = ProgressRecorder()
        _ = try GitRepository.clone(
            from: source.root.path,
            to: destination,
            options: CloneOptions(
                localStrategy: .neverLocal,
                onProgress: { progress in recorder.record(progress) }
            )
        )

        #expect(recorder.count > 0, "transfer_progress should have fired at least once")
        let last = try #require(recorder.last)
        #expect(last.totalObjects > 0)
        #expect(last.receivedObjects <= last.totalObjects)
    }

    // MARK: - Status

    /// The exit criterion, verbatim: one modified, one untracked, one ignored →
    /// exactly one modified and one untracked entry.
    @Test("status honours .gitignore and classifies each change")
    func statusClassifiesChanges() async throws {
        let fixture = try FixtureRepository(name: "status")
        defer { fixture.cleanUp() }

        try fixture.write("original\n", to: "tracked.txt")
        try fixture.write("build/\nignored.log\n", to: ".gitignore")
        try fixture.commit("Initial commit", adding: ["tracked.txt", ".gitignore"])

        try fixture.write("changed\n", to: "tracked.txt")   // modified
        try fixture.write("new\n", to: "untracked.txt")     // untracked
        try fixture.write("noise\n", to: "ignored.log")     // ignored
        try fixture.write("noise\n", to: "build/output.o")  // ignored, in a dir

        let repository = try GitRepository.open(at: fixture.root.path)
        let status = try await repository.status()

        #expect(status.modified.map(\.path) == ["tracked.txt"])
        #expect(status.untracked.map(\.path) == ["untracked.txt"])
        #expect(
            status.entries.count == 2,
            """
            expected exactly the modified and the untracked file; got \
            \(status.entries.map(\.path)). Anything else means .gitignore was not \
            honoured.
            """
        )
        #expect(!status.entries.contains { $0.path.contains("ignored.log") })
        #expect(!status.entries.contains { $0.path.hasPrefix("build/") })
        #expect(!status.isClean)
    }

    @Test("status on an untouched checkout is clean")
    func statusIsCleanWhenNothingChanged() async throws {
        let (fixture, _) = try FixtureRepository.withInitialCommit()
        defer { fixture.cleanUp() }

        let repository = try GitRepository.open(at: fixture.root.path)
        let status = try await repository.status()
        #expect(status.isClean, "unexpected entries: \(status.entries.map(\.path))")
        #expect(status.modified.isEmpty)
        #expect(status.untracked.isEmpty)
    }

    @Test("a staged change is reported on the index side")
    func stagedChangeIsReportedAsStaged() async throws {
        let fixture = try FixtureRepository(name: "staged")
        defer { fixture.cleanUp() }

        try fixture.write("one\n", to: "a.txt")
        try fixture.commit("Initial commit", adding: ["a.txt"])

        try fixture.write("two\n", to: "a.txt")
        try fixture.stage("a.txt")

        let repository = try GitRepository.open(at: fixture.root.path)
        let status = try await repository.status()

        let entry = try #require(status.entries.first { $0.path == "a.txt" })
        #expect(entry.indexChange == .modified)
        #expect(entry.isStaged)
        #expect(status.staged.map(\.path) == ["a.txt"])
        // Staged but not further edited, so nothing on the worktree side — this
        // is the distinction a single collapsed status value destroys.
        #expect(entry.worktreeChange == nil)
        #expect(status.modified.isEmpty)
    }

    // MARK: - Shallow clone

    /// The empirical basis for ``SwiftRepositorio/supportsShallowClone``.
    ///
    /// Parameterised over every `localStrategy` because the first version of this
    /// test assumed the object-copy path would silently ignore `depth` — reading
    /// `clone_local_into`, which never touches it. That was wrong: the copy path
    /// still calls `git_remote_fetch` to set up refs, and the local transport
    /// refuses there. Covering all four strategies is what turned a plausible
    /// inference into a measurement.
    @Test(
        "depth is refused by every local strategy, never silently ignored",
        arguments: [
            CloneOptions.LocalStrategy.auto,
            .alwaysLocal,
            .neverLocal,
            .localWithoutLinks,
        ]
    )
    func depthIsRefusedByEveryLocalStrategy(strategy: CloneOptions.LocalStrategy) throws {
        let (source, _) = try FixtureRepository.withInitialCommit()
        defer { source.cleanUp() }

        let destination = Self.temporaryPath("shallow-\(strategy)")
        defer { try? FileManager.default.removeItem(atPath: destination) }

        do {
            _ = try GitRepository.clone(
                from: source.root.path,
                to: destination,
                options: CloneOptions(depth: 1, localStrategy: strategy)
            )
            Issue.record(
                """
                \(strategy) accepted depth=1. If libgit2 has gained shallow support \
                on this path, SwiftRepositorio.supportsShallowClone's documentation \
                and README § Shallow clone both need updating — and a depth-based \
                size guard becomes testable locally, which it currently is not.
                """
            )
        } catch let error as GitError {
            // GIT_ENOTSUPPORTED from src/libgit2/transports/local.c:310, the only
            // place libgit2 refuses shallow. That it arrives at all proves `depth`
            // is plumbed from CloneOptions through git_fetch_options into the
            // transport: a dropped value would have produced a silent full clone.
            #expect(error.isNotSupported, "expected GIT_ENOTSUPPORTED (-39), got \(error.code)")
            #expect(
                error.message == "shallow fetch is not supported by the local transport",
                """
                libgit2's message changed: "\(error.message)". Verbatim text is \
                load-bearing for later sorties, so a change is worth noticing here.
                """
            )
        }
    }

    /// Without `depth`, every local strategy clones normally — the control for the
    /// test above, so its refusals cannot be blamed on the strategy itself.
    @Test(
        "every local strategy clones a full history when no depth is requested",
        arguments: [
            CloneOptions.LocalStrategy.auto,
            .alwaysLocal,
            .neverLocal,
            .localWithoutLinks,
        ]
    )
    func everyLocalStrategyClonesWithoutDepth(strategy: CloneOptions.LocalStrategy) async throws {
        let (source, _) = try FixtureRepository.withInitialCommit()
        defer { source.cleanUp() }
        try source.write("second\n", to: "second.txt")
        try source.commit("Second", adding: ["second.txt"])
        try source.write("third\n", to: "third.txt")
        let tip = try source.commit("Third", adding: ["third.txt"])

        let destination = Self.temporaryPath("full-\(strategy)")
        defer { try? FileManager.default.removeItem(atPath: destination) }

        let clone = try GitRepository.clone(
            from: source.root.path,
            to: destination,
            options: CloneOptions(localStrategy: strategy)
        )

        let head = try #require(try await clone.head())
        #expect(head.sha == tip)
        #expect(await clone.isShallow == false)
        #expect(try CommitCounter.countFromHead(at: destination) == 3)
    }

    @Test("supportsShallowClone reflects a capability, not a per-transport guarantee")
    func shallowConstantIsACapabilityFlag() {
        // Documented `true`: the smart transports negotiate deepen. The local
        // transport's refusal above is not a counter-example to the capability, it
        // is the reason the flag needs its documentation read.
        #expect(SwiftRepositorio.supportsShallowClone)
    }

    // MARK: - Helpers

    private static func temporaryPath(_ name: String) -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftRepositorioTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
            .path
    }
}

/// Collects progress callbacks fired from libgit2's thread.
///
/// A `Mutex` rather than an actor, because the callback is synchronous C and
/// cannot `await`. Deliberately not `@unchecked Sendable` over an `NSLock`: the
/// package's own `.swiftlint.yml` makes that annotation an error, and the rule
/// applies to test code too. `Synchronization.Mutex` is `Sendable` on its own
/// terms, so no safety has to be asserted by hand.
final class ProgressRecorder: Sendable {
    private let snapshots = Mutex<[TransferProgress]>([])

    func record(_ progress: TransferProgress) {
        snapshots.withLock { $0.append(progress) }
    }

    var count: Int { snapshots.withLock(\.count) }
    var last: TransferProgress? { snapshots.withLock(\.last) }
}
