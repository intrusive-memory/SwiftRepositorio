import Foundation

import Clibgit2

/// Who made a change, and when.
///
/// A value type with no defaults and no empty initialiser. Every commit in this
/// package must name a real identity, and the way that is guaranteed is by making
/// it impossible to express the alternative — see
/// ``GitRepository/commit(message:author:committer:)``.
public struct Author: Sendable, Hashable {

    /// Display name, e.g. `"Ada Lovelace"`.
    public let name: String

    /// Email address, e.g. `"ada@example.com"`.
    public let email: String

    /// When the change was made.
    public let date: Date

    /// The time zone the date is expressed in.
    ///
    /// git stores a commit time as a UTC instant *plus* the author's offset, and
    /// keeps the offset because it is information: a commit made at 23:00 in Tokyo
    /// is a different fact from one made at 14:00 in London, even at the same
    /// instant. Discarding it and writing `+0000` would silently rewrite history's
    /// texture, so the offset is carried rather than normalised.
    public let timeZone: TimeZone

    public init(name: String, email: String, date: Date = Date(), timeZone: TimeZone = .current) {
        self.name = name
        self.email = email
        self.date = date
        self.timeZone = timeZone
    }

    /// Seconds since the epoch, as git stores it.
    var gitTime: git_time_t {
        git_time_t(date.timeIntervalSince1970)
    }

    /// UTC offset in **minutes**, as git stores it.
    ///
    /// `TimeZone` reports seconds; libgit2 wants minutes. Zones with sub-minute
    /// historical offsets exist (LMT before standard time), and integer division
    /// truncates them — acceptable, because git's own format cannot represent
    /// them either.
    var gitOffsetInMinutes: Int32 {
        Int32(timeZone.secondsFromGMT(for: date) / 60)
    }

    /// Runs `body` with a libgit2 signature, freeing it afterwards.
    ///
    /// Scoped rather than returned: `git_signature` is heap-allocated by libgit2
    /// and must be freed with `git_signature_free`, and a function that returned
    /// the pointer would be handing callers an ownership obligation the type
    /// system does not express.
    func withSignature<T>(_ body: (UnsafePointer<git_signature>?) throws -> T) throws -> T {
        var signature: UnsafeMutablePointer<git_signature>?
        try gitCall("git_signature_new") {
            git_signature_new(&signature, name, email, gitTime, gitOffsetInMinutes)
        }
        defer { git_signature_free(signature) }
        return try body(UnsafePointer(signature))
    }
}
