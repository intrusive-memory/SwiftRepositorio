import Foundation
import Testing

import SwiftRepositorio

/// Staging and committing, with byte fidelity as the central claim.
@Suite("Write paths")
struct WritePathTests {

    /// Any identity will do for tests that are not about identity; what matters is
    /// that one has to be supplied at all.
    private static let ada = Author(
        name: "Ada Lovelace",
        email: "ada@example.invalid",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    // MARK: - Byte fidelity

    /// The exit criterion, in one fixture: CRLF line endings, a UTF-8 BOM, and no
    /// trailing newline, asserted on `Data`.
    ///
    /// Every one of those three is something a well-meaning tool "fixes". A
    /// screenplay saved on Windows has CRLF; a file touched by a Microsoft editor
    /// has a BOM; a file whose last line the user did not terminate has no final
    /// newline, and `String` round-trips through Foundation can silently add one.
    /// Comparing `Data` is the only comparison that can see any of it.
    @Test("CRLF + BOM + no trailing newline survives stage and commit byte-identically")
    func hostileTextRoundTripsByteIdentically() async throws {
        let fixture = try FixtureRepository(name: "bytes")
        defer { fixture.cleanUp() }

        // Assembled from bytes, never from a string literal, so nothing between
        // here and the assertion can normalise it.
        var original = Data([0xEF, 0xBB, 0xBF])                    // UTF-8 BOM
        original.append(contentsOf: Array("INT. OFFICE - DAY".utf8))
        original.append(contentsOf: [0x0D, 0x0A])                  // CRLF
        original.append(contentsOf: Array("Ada types.".utf8))
        original.append(contentsOf: [0x0D, 0x0A])                  // CRLF
        original.append(contentsOf: Array("No trailing newline here".utf8))
        // ...and deliberately nothing after it.

        try fixture.writeBytes(original, to: "scene.fountain")

        let repository = try GitRepository.open(at: fixture.root.path)
        try await repository.stage(paths: ["scene.fountain"])
        let sha = try await repository.commit(
            message: "Add a scene with hostile bytes",
            author: Self.ada,
            committer: Self.ada
        )

        let stored = try BlobReader.bytes(of: "scene.fountain", atCommit: sha, in: fixture.root.path)

        #expect(
            stored == original,
            """
            The committed blob differs from the bytes on disk.
              on disk: \(original.count) bytes, \(Self.describe(original))
              in blob: \(stored.count) bytes, \(Self.describe(stored))
            This is Standing Order 7 broken: a commit must write exactly the bytes \
            the editor saved.
            """
        )

        // Spelled out individually, because a single equality failure would not
        // say which transformation happened, and each of these has a different
        // cause worth naming in the failure.
        #expect(stored.prefix(3) == Data([0xEF, 0xBB, 0xBF]), "the UTF-8 BOM was stripped")
        #expect(Self.occurrences(of: [0x0D, 0x0A], in: stored) == 2, "CRLF was converted to LF")
        #expect(!stored.contains(0x0D) || Self.occurrences(of: [0x0D, 0x0A], in: stored) == 2)
        #expect(stored.last != 0x0A, "a trailing newline was added")
        #expect(stored.count == original.count)
    }

    /// Bytes that are not valid UTF-8 at all.
    ///
    /// A Latin-1 file, or a file that is simply not text, must pass through
    /// untouched. This cannot be expressed as a `String`, which is exactly why the
    /// API takes paths and the assertion takes `Data`: an implementation that
    /// decoded to `String` anywhere in the staging path would corrupt this fixture
    /// with U+FFFD and could not be caught by any string-based test.
    @Test("non-UTF-8 bytes survive stage and commit")
    func invalidUTF8RoundTrips() async throws {
        let fixture = try FixtureRepository(name: "latin1")
        defer { fixture.cleanUp() }

        // 0xE9 is "é" in Latin-1 and an illegal lone continuation lead in UTF-8;
        // 0xFF and 0xFE never appear in valid UTF-8 at all.
        let original = Data([0x43, 0x61, 0x66, 0xE9, 0x0A, 0xFF, 0xFE, 0x00, 0x80])
        #expect(String(data: original, encoding: .utf8) == nil, "the fixture must be invalid UTF-8")

        try fixture.writeBytes(original, to: "latin1.txt")

        let repository = try GitRepository.open(at: fixture.root.path)
        try await repository.stage(paths: ["latin1.txt"])
        let sha = try await repository.commit(
            message: "Add Latin-1 bytes",
            author: Self.ada,
            committer: Self.ada
        )

        let stored = try BlobReader.bytes(of: "latin1.txt", atCommit: sha, in: fixture.root.path)
        #expect(stored == original, "expected \(Self.describe(original)), got \(Self.describe(stored))")
    }

    /// The hostile-configuration test: `core.autocrlf = true`, the setting that
    /// exists to do exactly the transformation this package forbids.
    ///
    /// This is the test that makes the byte-fidelity claim mean something. Passing
    /// with default configuration only proves the defaults are harmless; passing
    /// with the conversion explicitly switched on proves the staging path does not
    /// consult it. `git_index_add_bypath` would fail this test — it runs libgit2's
    /// filter chain, which reads this very key.
    @Test("line endings survive even with the conversion setting switched on")
    func autocrlfConfigurationCannotAffectTheBlob() async throws {
        let fixture = try FixtureRepository(name: "hostile-config")
        defer { fixture.cleanUp() }

        try fixture.setConfig("core.autocrlf", "true")
        try fixture.setConfig("core.eol", "crlf")
        // A .gitattributes demanding text normalisation, which is the other half of
        // the filter chain's input.
        try fixture.writeBytes(Data("* text=auto eol=lf\n".utf8), to: ".gitattributes")

        let crlf = Data([0x61, 0x0D, 0x0A, 0x62, 0x0D, 0x0A, 0x63])  // a\r\nb\r\nc
        try fixture.writeBytes(crlf, to: "windows.txt")

        let repository = try GitRepository.open(at: fixture.root.path)
        try await repository.stage(paths: ["windows.txt", ".gitattributes"])
        let sha = try await repository.commit(
            message: "Add CRLF under hostile config",
            author: Self.ada,
            committer: Self.ada
        )

        let stored = try BlobReader.bytes(of: "windows.txt", atCommit: sha, in: fixture.root.path)
        #expect(
            stored == crlf,
            """
            With core.autocrlf=true, core.eol=crlf and a text=auto attribute, the \
            blob came back as \(Self.describe(stored)) instead of \
            \(Self.describe(crlf)). Something in the staging path is consulting the \
            filter configuration — see the note on stage(paths:).
            """
        )
        #expect(Self.occurrences(of: [0x0D, 0x0A], in: stored) == 2)
    }

    @Test("an empty file commits as an empty blob, not a missing one")
    func emptyFileRoundTrips() async throws {
        let fixture = try FixtureRepository(name: "empty-file")
        defer { fixture.cleanUp() }

        try fixture.writeBytes(Data(), to: "empty.txt")

        let repository = try GitRepository.open(at: fixture.root.path)
        try await repository.stage(paths: ["empty.txt"])
        let sha = try await repository.commit(
            message: "Add an empty file",
            author: Self.ada,
            committer: Self.ada
        )

        let stored = try BlobReader.bytes(of: "empty.txt", atCommit: sha, in: fixture.root.path)
        #expect(stored.isEmpty)
        #expect(stored == Data())
    }

    @Test("a lone CR is not treated as a line ending", arguments: [
        Data([0x61, 0x0D, 0x62]),            // a\rb — classic Mac line ending
        Data([0x0D]),                        // just CR
        Data([0x0A, 0x0D]),                  // LF then CR, reversed
        Data([0x0D, 0x0D, 0x0A]),            // CR CR LF
    ])
    func loneCarriageReturnsSurvive(original: Data) async throws {
        let fixture = try FixtureRepository(name: "cr")
        defer { fixture.cleanUp() }

        try fixture.writeBytes(original, to: "cr.txt")

        let repository = try GitRepository.open(at: fixture.root.path)
        try await repository.stage(paths: ["cr.txt"])
        let sha = try await repository.commit(
            message: "CR fixture",
            author: Self.ada,
            committer: Self.ada
        )

        let stored = try BlobReader.bytes(of: "cr.txt", atCommit: sha, in: fixture.root.path)
        #expect(stored == original, "expected \(Self.describe(original)), got \(Self.describe(stored))")
    }

    // MARK: - Staging behaviour

    @Test("staging makes the change appear on the index side of status")
    func stagingShowsUpInStatus() async throws {
        let fixture = try FixtureRepository(name: "stage-status")
        defer { fixture.cleanUp() }

        try fixture.writeBytes(Data("one\n".utf8), to: "a.txt")

        let repository = try GitRepository.open(at: fixture.root.path)
        // Before staging: untracked.
        var status = try await repository.status()
        #expect(status.untracked.map(\.path) == ["a.txt"])
        #expect(status.staged.isEmpty)

        try await repository.stage(paths: ["a.txt"])

        // After staging: an index-side addition, nothing untracked.
        status = try await repository.status()
        #expect(status.untracked.isEmpty)
        #expect(status.staged.map(\.path) == ["a.txt"])
        #expect(status.staged.first?.indexChange == .added)
    }

    @Test("staging only the named paths leaves the others alone")
    func stagingIsExplicit() async throws {
        let fixture = try FixtureRepository(name: "explicit")
        defer { fixture.cleanUp() }

        try fixture.writeBytes(Data("a\n".utf8), to: "a.txt")
        try fixture.writeBytes(Data("b\n".utf8), to: "b.txt")

        let repository = try GitRepository.open(at: fixture.root.path)
        try await repository.stage(paths: ["a.txt"])

        let status = try await repository.status()
        #expect(status.staged.map(\.path) == ["a.txt"])
        #expect(
            status.untracked.map(\.path) == ["b.txt"],
            "b.txt must still be untracked — there is no recursive staging"
        )
    }

    @Test("staging a directory is refused rather than recursing")
    func stagingADirectoryIsRefused() async throws {
        let fixture = try FixtureRepository(name: "dir")
        defer { fixture.cleanUp() }

        try fixture.writeBytes(Data("x\n".utf8), to: "folder/inside.txt")

        let repository = try GitRepository.open(at: fixture.root.path)
        await #expect(throws: GitError.self) {
            try await repository.stage(paths: ["folder"])
        }
    }

    @Test("staging a symbolic link is refused rather than following it")
    func stagingASymlinkIsRefused() async throws {
        let fixture = try FixtureRepository(name: "symlink")
        defer { fixture.cleanUp() }

        try fixture.writeBytes(Data("target contents\n".utf8), to: "target.txt")
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appendingPathComponent("link.txt"),
            withDestinationURL: fixture.root.appendingPathComponent("target.txt")
        )

        let repository = try GitRepository.open(at: fixture.root.path)
        do {
            try await repository.stage(paths: ["link.txt"])
            Issue.record("expected staging a symlink to be refused")
        } catch let error as GitError {
            // Refusing beats committing the target's bytes under the link's name,
            // which would be a silent data error.
            #expect(error.isNotSupported)
            #expect(error.message.contains("symbolic link"))
        }
    }

    @Test("staging a path that does not exist throws")
    func stagingAMissingPathThrows() async throws {
        let fixture = try FixtureRepository(name: "missing")
        defer { fixture.cleanUp() }

        let repository = try GitRepository.open(at: fixture.root.path)
        await #expect(throws: (any Error).self) {
            try await repository.stage(paths: ["nope.txt"])
        }
    }

    @Test("the executable bit is preserved through the commit")
    func executableBitIsPreserved() async throws {
        let fixture = try FixtureRepository(name: "exec")
        defer { fixture.cleanUp() }

        try fixture.writeBytes(Data("#!/bin/sh\necho hi\n".utf8), to: "script.sh")
        let script = fixture.root.appendingPathComponent("script.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let repository = try GitRepository.open(at: fixture.root.path)
        try await repository.stage(paths: ["script.sh"])
        let sha = try await repository.commit(
            message: "Add a script",
            author: Self.ada,
            committer: Self.ada
        )

        // 0o100755 — git keeps exactly one permission bit, and this is it.
        #expect(try BlobReader.mode(of: "script.sh", atCommit: sha, in: fixture.root.path) == 0o100755)
    }

    // MARK: - Commit behaviour

    @Test("commit returns the SHA that HEAD now points at")
    func commitReturnsTheNewHeadSHA() async throws {
        let fixture = try FixtureRepository(name: "commit-head")
        defer { fixture.cleanUp() }

        try fixture.writeBytes(Data("hello\n".utf8), to: "hello.txt")

        let repository = try GitRepository.open(at: fixture.root.path)
        try await repository.stage(paths: ["hello.txt"])
        let sha = try await repository.commit(
            message: "First",
            author: Self.ada,
            committer: Self.ada
        )

        #expect(sha.count == 40)
        let head = try #require(try await repository.head())
        #expect(
            head.sha == sha,
            "commit must move HEAD — a commit that does not is dangling and gc will delete it"
        )
        #expect(head.branch == "main")
    }

    @Test("a second commit chains onto the first")
    func commitsChain() async throws {
        let fixture = try FixtureRepository(name: "chain")
        defer { fixture.cleanUp() }

        let repository = try GitRepository.open(at: fixture.root.path)

        try fixture.writeBytes(Data("one\n".utf8), to: "a.txt")
        try await repository.stage(paths: ["a.txt"])
        let first = try await repository.commit(message: "One", author: Self.ada, committer: Self.ada)

        try fixture.writeBytes(Data("two\n".utf8), to: "b.txt")
        try await repository.stage(paths: ["b.txt"])
        let second = try await repository.commit(message: "Two", author: Self.ada, committer: Self.ada)

        #expect(first != second)
        #expect(try CommitCounter.countFromHead(at: fixture.root.path) == 2)
        // The first commit's file must still be in the second commit's tree.
        let carried = try BlobReader.bytes(of: "a.txt", atCommit: second, in: fixture.root.path)
        #expect(carried == Data("one\n".utf8))
    }

    @Test("the working tree is clean after staging and committing everything")
    func treeIsCleanAfterCommit() async throws {
        let fixture = try FixtureRepository(name: "clean-after")
        defer { fixture.cleanUp() }

        try fixture.writeBytes(Data("content\n".utf8), to: "file.txt")

        let repository = try GitRepository.open(at: fixture.root.path)
        try await repository.stage(paths: ["file.txt"])
        _ = try await repository.commit(message: "Add", author: Self.ada, committer: Self.ada)

        let status = try await repository.status()
        #expect(status.isClean, "unexpected: \(status.entries.map(\.path))")
    }

    @Test("author and committer can differ, and both are recorded")
    func authorAndCommitterAreDistinct() async throws {
        let fixture = try FixtureRepository(name: "two-identities")
        defer { fixture.cleanUp() }

        try fixture.writeBytes(Data("x\n".utf8), to: "x.txt")

        let charles = Author(
            name: "Charles Babbage",
            email: "charles@example.invalid",
            date: Date(timeIntervalSince1970: 1_700_000_500),
            timeZone: TimeZone(secondsFromGMT: 3600)!
        )

        let repository = try GitRepository.open(at: fixture.root.path)
        try await repository.stage(paths: ["x.txt"])
        let sha = try await repository.commit(
            message: "Written by Ada, recorded by Charles",
            author: Self.ada,
            committer: charles
        )

        let recorded = try CommitIdentity.read(atCommit: sha, in: fixture.root.path)
        #expect(recorded.authorName == "Ada Lovelace")
        #expect(recorded.authorEmail == "ada@example.invalid")
        #expect(recorded.committerName == "Charles Babbage")
        // The offset is information, not noise: +0100 must not be normalised to UTC.
        #expect(recorded.committerOffsetInMinutes == 60)
        #expect(recorded.authorOffsetInMinutes == 0)
        #expect(recorded.message == "Written by Ada, recorded by Charles")
    }

    // MARK: - Reporting helpers

    /// A hex dump, because a failure that prints mojibake is a failure you cannot
    /// diagnose. Byte comparisons deserve byte-level reporting.
    private static func describe(_ data: Data) -> String {
        let hex = data.prefix(48).map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > 48 ? "\(hex) …" : hex
    }

    private static func occurrences(of needle: [UInt8], in data: Data) -> Int {
        guard !needle.isEmpty, data.count >= needle.count else { return 0 }
        let bytes = Array(data)
        var count = 0
        for start in 0...(bytes.count - needle.count) where Array(bytes[start..<start + needle.count]) == needle {
            count += 1
        }
        return count
    }
}
