import Clibgit2

/// Progress of the object transfer during a clone or fetch.
///
/// A snapshot, copied out of libgit2's `git_indexer_progress` — the C struct is
/// owned by libgit2 and reused between callbacks, so it must not be retained.
public struct TransferProgress: Sendable, Equatable {
    /// Objects the remote said it will send.
    public let totalObjects: Int
    /// Objects received so far.
    public let receivedObjects: Int
    /// Objects already present locally, so not sent.
    public let localObjects: Int
    /// Deltas resolved so far.
    public let indexedDeltas: Int
    /// Total deltas to resolve.
    public let totalDeltas: Int
    /// Bytes received.
    public let receivedBytes: Int

    /// Fraction complete in `0...1`, counting both receive and delta-resolution.
    ///
    /// `nil` when the remote has not yet said how much there is, which is the
    /// state at the start of every clone — a progress bar that renders `nil` as
    /// `0` will sit at zero and then jump, so treat it as indeterminate.
    public var fractionCompleted: Double? {
        guard totalObjects > 0 else { return nil }
        let received = Double(receivedObjects) / Double(totalObjects)
        guard totalDeltas > 0 else { return received }
        // Receiving and delta resolution are sequential phases of roughly
        // comparable cost, so each gets half the bar.
        return received * 0.5 + (Double(indexedDeltas) / Double(totalDeltas)) * 0.5
    }

    init(_ stats: git_indexer_progress) {
        totalObjects = Int(stats.total_objects)
        receivedObjects = Int(stats.received_objects)
        localObjects = Int(stats.local_objects)
        indexedDeltas = Int(stats.indexed_deltas)
        totalDeltas = Int(stats.total_deltas)
        receivedBytes = Int(stats.received_bytes)
    }
}

/// How to clone.
public struct CloneOptions: Sendable {

    /// Branch to check out. `nil` uses the remote's default branch.
    public var checkoutBranch: String?

    /// Create a repository with no working directory.
    public var bare: Bool

    /// Truncate history to this many commits.
    ///
    /// ## Read this before using it
    ///
    /// ``SwiftRepositorio/supportsShallowClone`` is `false` for this build. Setting
    /// `depth` here is accepted by libgit2 and **silently produces a full clone**
    /// — see README § Shallow clone. It is exposed because the plan asks for the
    /// `git_clone_options` surface to be reachable, and because the day libgit2
    /// gains the capability this becomes correct without an API change.
    ///
    /// It must **not** be used as a size guard today. A guard that appears to work
    /// and does not is worse than no guard.
    public var depth: Int32?

    /// Whether to bypass the git-aware transport for local paths.
    ///
    /// Defaults to ``LocalStrategy/auto``, which is libgit2's own default:
    /// hardlink or copy the object database for a plain path, and use a real
    /// fetch for a `file://` URL. That distinction matters more than it looks —
    /// the object-database copy skips fetch negotiation entirely, so anything
    /// that depends on negotiation (`depth`, refspec filtering) has no effect on
    /// a plain local path no matter what libgit2 supports.
    public var localStrategy: LocalStrategy

    public enum LocalStrategy: Sendable, Equatable {
        /// Bypass the transport for plain paths, fetch for `file://`.
        case auto
        /// Bypass the transport even for `file://`.
        case alwaysLocal
        /// Never bypass — force a real fetch even for a plain path.
        case neverLocal
        /// Bypass, but copy rather than hardlink.
        case localWithoutLinks

        var libgit2Value: git_clone_local_t {
            switch self {
            case .auto: GIT_CLONE_LOCAL_AUTO
            case .alwaysLocal: GIT_CLONE_LOCAL
            case .neverLocal: GIT_CLONE_NO_LOCAL
            case .localWithoutLinks: GIT_CLONE_LOCAL_NO_LINKS
            }
        }
    }

    /// Called as objects arrive.
    ///
    /// ## Which thread, and what you may do on it
    ///
    /// libgit2 invokes this **synchronously, on the thread performing the
    /// clone**, many times a second. It is `@Sendable` because that thread is an
    /// executor thread owned by ``GitRepository``'s actor, not the caller's.
    ///
    /// Do not block in it and do not `await` from it — there is no way to, since
    /// it is not `async`, and that is deliberate. Post the snapshot somewhere and
    /// return. Throwing is not possible either; to cancel a clone, a future
    /// sortie needs libgit2's cancellation path, not an error from here.
    public var onProgress: (@Sendable (TransferProgress) -> Void)?

    public init(
        checkoutBranch: String? = nil,
        bare: Bool = false,
        depth: Int32? = nil,
        localStrategy: LocalStrategy = .auto,
        onProgress: (@Sendable (TransferProgress) -> Void)? = nil
    ) {
        self.checkoutBranch = checkoutBranch
        self.bare = bare
        self.depth = depth
        self.localStrategy = localStrategy
        self.onProgress = onProgress
    }

    public static let `default` = CloneOptions()
}

/// Where the progress closure lives while C holds a pointer to it.
///
/// `git_clone_options.fetch_opts.callbacks.payload` is a `void *`, so the closure
/// has to be reachable through a stable address for the duration of the call.
/// This class provides that address; it is created and destroyed inside a single
/// synchronous `git_clone` call and never escapes it.
final class CloneProgressBox {
    let onProgress: @Sendable (TransferProgress) -> Void
    init(_ onProgress: @escaping @Sendable (TransferProgress) -> Void) {
        self.onProgress = onProgress
    }
}
