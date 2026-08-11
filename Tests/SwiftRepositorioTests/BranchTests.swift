import Foundation
import Testing

import SwiftRepositorio

/// Local-branch primitives: list, create, switch, and read the current name.
///
/// Every fixture here goes through the package's own public API —
/// `GitRepository.create` plus `stage`/`commit` — rather than
/// `FixtureRepository`'s hand-rolled C, the same choice
/// `GitRepositoryTests.createdRepositoryCanBeClonedFrom` makes and for the same
/// reason: this is exactly the round trip a real caller (Escribir's git-backed
/// document store) exercises, so the test should exercise it too.
@Suite("Branch operations")
struct BranchTests {

    private static let ada = Author(name: "Ada Lovelace", email: "ada@example.invalid")

    // MARK: - Listing

    @Test("a fresh repository with one commit lists just the initial branch")
    func listOnFreshRepositoryHasOnlyTheInitialBranch() async throws {
        let path = Self.temporaryPath("list-fresh")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let repository = try GitRepository.create(at: path, initialBranch: "main")
        try await Self.writeAndCommit("hello\n", to: "README.md", message: "Initial commit", in: repository)

        let branches = try await repository.localBranches()
        #expect(branches == ["main"])
    }

    @Test("creating a branch adds it to the list without switching to it")
    func createAddsToTheListWithoutSwitching() async throws {
        let path = Self.temporaryPath("create-adds")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let repository = try GitRepository.create(at: path, initialBranch: "main")
        try await Self.writeAndCommit("hello\n", to: "README.md", message: "Initial commit", in: repository)

        try await repository.createBranch(named: "feature")

        let branches = try await repository.localBranches()
        #expect(branches == ["feature", "main"], "expected both branches, sorted")
        #expect(
            try await repository.currentBranchName() == "main",
            "createBranch must not move HEAD — the caller sequences create-then-switch"
        )
    }

    // MARK: - Current branch

    @Test("currentBranchName on a freshly created repository equals the initial branch")
    func currentBranchNameOnFreshRepositoryEqualsInitialBranch() async throws {
        let path = Self.temporaryPath("current-fresh")
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Deliberately no commit at all: HEAD is unborn. currentBranchName reads
        // HEAD's symbolic target directly, so it answers correctly even here,
        // unlike head()?.branch which is nil until the first commit exists.
        let repository = try GitRepository.create(at: path, initialBranch: "trunk")

        #expect(try await repository.isHeadUnborn())
        #expect(try await repository.currentBranchName() == "trunk")
    }

    // MARK: - Switching

    @Test("switching branches moves HEAD and preserves an untracked file")
    func switchMovesHeadAndPreservesUntrackedFile() async throws {
        let path = Self.temporaryPath("switch-untracked")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let repository = try GitRepository.create(at: path, initialBranch: "main")
        try await Self.writeAndCommit("hello\n", to: "README.md", message: "Initial commit", in: repository)
        try await repository.createBranch(named: "feature")

        // An untracked file, present in neither main's nor feature's tree.
        let workdir = try #require(await repository.workingDirectory)
        let scratchPath = workdir + "/scratch.txt"
        try "not committed anywhere\n".write(toFile: scratchPath, atomically: true, encoding: .utf8)

        try await repository.switchBranch(to: "feature")

        #expect(try await repository.currentBranchName() == "feature")
        let head = try #require(try await repository.head())
        #expect(head.branch == "feature")
        #expect(head.referenceName == "refs/heads/feature")

        #expect(
            FileManager.default.fileExists(atPath: scratchPath),
            "GIT_CHECKOUT_SAFE must not remove a file that is in neither tree"
        )
        #expect(try String(contentsOfFile: scratchPath, encoding: .utf8) == "not committed anywhere\n")
    }

    @Test("switching onto a branch with a conflicting tracked modification throws")
    func switchWithConflictingModificationThrows() async throws {
        let path = Self.temporaryPath("switch-conflict")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let repository = try GitRepository.create(at: path, initialBranch: "main")
        try await Self.writeAndCommit("one\n", to: "file.txt", message: "Main: one", in: repository)

        // feature starts at the same commit, then moves ahead with a second,
        // different committed version of file.txt.
        try await repository.createBranch(named: "feature")
        try await repository.switchBranch(to: "feature")
        try await Self.writeAndCommit("two\n", to: "file.txt", message: "Feature: two", in: repository)

        // Back to main, at its original content.
        try await repository.switchBranch(to: "main")
        let workdir = try #require(await repository.workingDirectory)
        let filePath = workdir + "/file.txt"
        #expect(try String(contentsOfFile: filePath, encoding: .utf8) == "one\n")

        // An uncommitted edit that main's checkout target ("one") does not
        // predict and feature's target ("two") would have to overwrite.
        try "three (uncommitted)\n".write(toFile: filePath, atomically: true, encoding: .utf8)

        await #expect(throws: GitError.self) {
            try await repository.switchBranch(to: "feature")
        }

        // The refusal must be real: HEAD stays on main and the uncommitted edit
        // survives untouched.
        #expect(try await repository.currentBranchName() == "main")
        #expect(try String(contentsOfFile: filePath, encoding: .utf8) == "three (uncommitted)\n")
    }

    @Test("switching to a branch that does not exist throws, with the name in the message")
    func switchToUnknownBranchThrows() async throws {
        let path = Self.temporaryPath("switch-unknown")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let repository = try GitRepository.create(at: path, initialBranch: "main")
        try await Self.writeAndCommit("hello\n", to: "README.md", message: "Initial commit", in: repository)

        do {
            try await repository.switchBranch(to: "does-not-exist")
            Issue.record("expected switching to a missing branch to throw")
        } catch let error as GitError {
            #expect(error.isNotFound)
            #expect(error.message.contains("does-not-exist"))
        }
    }

    // MARK: - Validation

    @Test("creating a branch with an empty name throws")
    func createWithEmptyNameThrows() async throws {
        let path = Self.temporaryPath("create-empty")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let repository = try GitRepository.create(at: path, initialBranch: "main")
        try await Self.writeAndCommit("hello\n", to: "README.md", message: "Initial commit", in: repository)

        await #expect(throws: GitError.self) {
            try await repository.createBranch(named: "")
        }
        // The refusal must not have created anything.
        #expect(try await repository.localBranches() == ["main"])
    }

    @Test("switching to an empty branch name throws")
    func switchWithEmptyNameThrows() async throws {
        let path = Self.temporaryPath("switch-empty")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let repository = try GitRepository.create(at: path, initialBranch: "main")
        try await Self.writeAndCommit("hello\n", to: "README.md", message: "Initial commit", in: repository)

        await #expect(throws: GitError.self) {
            try await repository.switchBranch(to: "")
        }
    }

    // MARK: - Helpers

    private static func temporaryPath(_ name: String) -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftRepositorioTests-\(UUID().uuidString)")
            .appendingPathComponent(name)
            .path
    }

    /// Writes a file into `repository`'s working directory, stages it, and
    /// commits — the same create → write → stage → commit round trip
    /// `GitRepositoryTests.createdRepositoryCanBeClonedFrom` uses, factored out
    /// because every test in this file needs it at least once.
    @discardableResult
    private static func writeAndCommit(
        _ contents: String,
        to relativePath: String,
        message: String,
        in repository: GitRepository
    ) async throws -> String {
        let workdir = try #require(await repository.workingDirectory)
        try contents.write(
            toFile: workdir + "/" + relativePath, atomically: true, encoding: .utf8)
        try await repository.stage(paths: [relativePath])
        return try await repository.commit(message: message, author: Self.ada, committer: Self.ada)
    }
}
