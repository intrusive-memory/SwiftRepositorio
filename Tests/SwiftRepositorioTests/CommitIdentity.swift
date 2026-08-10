import Foundation

import Clibgit2

/// Reads back what a commit actually recorded about who made it.
///
/// In the test target for the same reason as ``BlobReader``: Sortie 3's public
/// surface is `stage` and `commit`, and reading commit metadata is not in it.
/// This exists so the "both identities are required" API can be shown to actually
/// *store* both, rather than accepting two and writing one.
enum CommitIdentity {

    struct Recorded {
        let authorName: String
        let authorEmail: String
        let authorOffsetInMinutes: Int32
        let committerName: String
        let committerEmail: String
        let committerOffsetInMinutes: Int32
        let message: String
    }

    static func read(atCommit sha: String, in repositoryPath: String) throws -> Recorded {
        _ = git_libgit2_init()

        var repository: OpaquePointer?
        guard git_repository_open(&repository, repositoryPath) == 0, let repository else {
            throw FixtureError(operation: "git_repository_open", code: -1, message: repositoryPath)
        }
        defer { git_repository_free(repository) }

        var oid = git_oid()
        guard git_oid_fromstr(&oid, sha) == 0 else {
            throw FixtureError(operation: "git_oid_fromstr", code: -1, message: sha)
        }

        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repository, &oid) == 0, let commit else {
            throw FixtureError(operation: "git_commit_lookup", code: -1, message: sha)
        }
        defer { git_commit_free(commit) }

        guard let author = git_commit_author(commit), let committer = git_commit_committer(commit) else {
            throw FixtureError(operation: "git_commit_author", code: -1, message: sha)
        }

        return Recorded(
            authorName: string(author.pointee.name),
            authorEmail: string(author.pointee.email),
            authorOffsetInMinutes: author.pointee.when.offset,
            committerName: string(committer.pointee.name),
            committerEmail: string(committer.pointee.email),
            committerOffsetInMinutes: committer.pointee.when.offset,
            message: git_commit_message(commit).map { String(cString: $0) } ?? ""
        )
    }

    private static func string(_ pointer: UnsafeMutablePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }
}
