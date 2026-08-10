import Clibgit2

/// What changed, as Swift values rather than a bitmask.
///
/// libgit2 reports status as `git_status_t` flags where index and worktree state
/// are packed into one integer. Handing that to a UI means every call site
/// re-learns which bit means what, and gets `GIT_STATUS_WT_NEW` (untracked)
/// confused with `GIT_STATUS_INDEX_NEW` (staged addition) at least once. This
/// type does the decoding in one place.
public struct RepositoryStatus: Sendable, Equatable {

    /// How a single path differs, on one side of the index.
    public enum Change: Sendable, Equatable, CaseIterable {
        /// New in the index relative to HEAD — a staged addition.
        case added
        /// Contents differ.
        case modified
        /// Gone.
        case deleted
        /// Moved, with libgit2's rename detection having matched it up.
        case renamed
        /// Same path, different type — file became a symlink, say.
        case typeChanged
        /// Present on disk and not in the index: **untracked**. Reported only on
        /// the worktree side, never the index side.
        case untracked
        /// Exists but could not be read.
        case unreadable
    }

    /// One path, with its index-side and worktree-side change.
    ///
    /// Both sides can be populated at once, and that is not a quirk: a file that
    /// was staged and then edited again is `indexChange == .modified` *and*
    /// `worktreeChange == .modified`. Collapsing that to one value is what makes
    /// a commit UI lie about what it is about to commit.
    public struct Entry: Sendable, Equatable, Hashable {
        /// Repository-relative path, as libgit2 reports it.
        public let path: String
        /// Change staged in the index relative to HEAD. `nil` when unstaged.
        public let indexChange: Change?
        /// Change on disk relative to the index. `nil` when the worktree matches.
        public let worktreeChange: Change?
        /// The path this entry was renamed from, when known.
        public let previousPath: String?
        /// Both sides of a merge conflict are present.
        public let isConflicted: Bool

        public init(
            path: String,
            indexChange: Change? = nil,
            worktreeChange: Change? = nil,
            previousPath: String? = nil,
            isConflicted: Bool = false
        ) {
            self.path = path
            self.indexChange = indexChange
            self.worktreeChange = worktreeChange
            self.previousPath = previousPath
            self.isConflicted = isConflicted
        }

        /// Whether this entry has anything staged for the next commit.
        public var isStaged: Bool { indexChange != nil }
    }

    /// Every reported path, in libgit2's order.
    ///
    /// Ignored files are **not** here. See ``GitRepository/status(options:)``.
    public let entries: [Entry]

    public init(entries: [Entry]) {
        self.entries = entries
    }

    /// Nothing staged, nothing changed on disk, nothing untracked.
    public var isClean: Bool { entries.isEmpty }

    /// Tracked files whose contents differ from the index — the plain
    /// "modified" set, excluding untracked files and staged-only changes.
    public var modified: [Entry] { entries.filter { $0.worktreeChange == .modified } }

    /// Files on disk that git is not tracking.
    public var untracked: [Entry] { entries.filter { $0.worktreeChange == .untracked } }

    /// Everything with an index-side change: what a commit would include.
    public var staged: [Entry] { entries.filter(\.isStaged) }

    /// Paths with unresolved merge conflicts.
    public var conflicted: [Entry] { entries.filter(\.isConflicted) }

    // MARK: - Decoding

    /// One path's decoded state.
    ///
    /// A named type rather than a 3-tuple: the members are not interchangeable and
    /// a tuple would let a call site swap index for worktree silently, which is
    /// exactly the confusion this decoding exists to prevent.
    struct Decoded {
        let index: Change?
        let worktree: Change?
        let conflicted: Bool
    }

    /// Index-side flags, in precedence order.
    ///
    /// Order is the semantics: libgit2 can set several bits at once, and the first
    /// match wins. Expressing that as data rather than as an `else if` chain keeps
    /// the precedence visible and reviewable in one place.
    private static let indexFlags: [(git_status_t, Change)] = [
        (GIT_STATUS_INDEX_NEW, .added),
        (GIT_STATUS_INDEX_MODIFIED, .modified),
        (GIT_STATUS_INDEX_DELETED, .deleted),
        (GIT_STATUS_INDEX_RENAMED, .renamed),
        (GIT_STATUS_INDEX_TYPECHANGE, .typeChanged),
    ]

    /// Worktree-side flags, in precedence order.
    ///
    /// `GIT_STATUS_WT_NEW` maps to `.untracked`, not `.added` — the index-side
    /// spelling of "new" means staged, and conflating the two is the single most
    /// common status bug.
    private static let worktreeFlags: [(git_status_t, Change)] = [
        (GIT_STATUS_WT_NEW, .untracked),
        (GIT_STATUS_WT_MODIFIED, .modified),
        (GIT_STATUS_WT_DELETED, .deleted),
        (GIT_STATUS_WT_RENAMED, .renamed),
        (GIT_STATUS_WT_TYPECHANGE, .typeChanged),
        (GIT_STATUS_WT_UNREADABLE, .unreadable),
    ]

    /// Splits a `git_status_t` bitmask into index-side and worktree-side changes.
    ///
    /// `GIT_STATUS_IGNORED` is intentionally unrepresented in ``Change``: this
    /// package never asks libgit2 for ignored files, so a case for one would be a
    /// case that never occurs.
    static func decode(_ flags: UInt32) -> Decoded {
        func firstMatch(in table: [(git_status_t, Change)]) -> Change? {
            table.first { flags & $0.0.rawValue != 0 }?.1
        }
        return Decoded(
            index: firstMatch(in: indexFlags),
            worktree: firstMatch(in: worktreeFlags),
            conflicted: flags & GIT_STATUS_CONFLICTED.rawValue != 0
        )
    }
}

/// How to ask for status.
public struct StatusOptions: Sendable, Equatable {

    /// Report files git is not tracking. On by default — a commit UI that cannot
    /// see new files is not useful.
    public var includeUntracked: Bool

    /// Descend into untracked directories and list their contents individually.
    ///
    /// On by default. With it off, libgit2 reports the *directory* as one
    /// untracked entry, which reads as "one new thing" when it might be four
    /// hundred. On, the count means what a user would expect.
    public var recurseUntrackedDirectories: Bool

    /// Detect renames between HEAD and the index.
    public var detectRenames: Bool

    /// Ignored files are never included, and this is not configurable.
    ///
    /// `.gitignore` exists to keep build products and secrets out of the user's
    /// field of view, and a status list that surfaces them anyway defeats it. If
    /// some future feature genuinely needs to see ignored paths — an "add
    /// anyway" affordance — it should be a separate, explicitly named call rather
    /// than a flag that could be flipped by accident here.
    public static let ignoredFilesAreNeverIncluded = true

    public init(
        includeUntracked: Bool = true,
        recurseUntrackedDirectories: Bool = true,
        detectRenames: Bool = true
    ) {
        self.includeUntracked = includeUntracked
        self.recurseUntrackedDirectories = recurseUntrackedDirectories
        self.detectRenames = detectRenames
    }

    public static let `default` = StatusOptions()

    /// The libgit2 flag word for these options.
    var libgit2Flags: UInt32 {
        var flags: UInt32 = 0
        if includeUntracked { flags |= GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue }
        if recurseUntrackedDirectories { flags |= GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue }
        if detectRenames {
            flags |= GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
            flags |= GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR.rawValue
        }
        // GIT_STATUS_OPT_INCLUDE_IGNORED is deliberately never set. See
        // `ignoredFilesAreNeverIncluded`.
        return flags
    }
}
