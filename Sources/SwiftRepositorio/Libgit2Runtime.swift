import Clibgit2

/// The libgit2 global lifecycle. Initialised exactly once, never shut down.
///
/// ## Why once, and how "once" is achieved
///
/// `git_libgit2_init()` must run before any other libgit2 call. It is
/// reference-counted and thread-safe, so calling it repeatedly is not an error —
/// but relying on that means the count is whatever the call pattern happened to
/// make it, and the matching `git_libgit2_shutdown()` count becomes a thing to
/// get right. A Swift `static let` is lazily initialised through `swift_once`,
/// which gives exactly-once semantics with no lock of our own and no counting.
///
/// ## Why `git_libgit2_shutdown()` is never called
///
/// Deliberate, not an oversight. Shutdown tears down libgit2's global state —
/// the ODB backends, the mmap window pool, the cached configuration. Any
/// `git_repository`, `git_reference` or `git_status_list` still alive at that
/// moment becomes a dangling handle, and there is no way for this type to know
/// whether one is: handles live in ``GitRepository`` actors whose lifetimes
/// belong to callers. The realistic options were a global registry of every live
/// handle, or accepting that the library lives as long as the process. The second
/// is what every libgit2 application does, and the cost is a few hundred
/// kilobytes that the OS reclaims at exit.
///
/// If a future sortie genuinely needs shutdown — a test that wants a pristine
/// global cache, say — it needs a design that can prove no handles are live, not
/// a call added here.
///
/// ## Threading, and why nothing else is required
///
/// libgit2's `docs/threading.md` requires the *application* to set up locking for
/// the cryptographic library when it is older OpenSSL: "OpenSSL is thread-safe
/// starting at version 1.1.0. If your copy of libgit2 is linked against that
/// version, you do not need to take any further steps." This package links
/// **OpenSSL 3.5.7** (`scripts/versions.sh`), so no locking callbacks are needed
/// and `git_openssl_set_locking()` is not called — it exists only for < 1.1.0 and
/// is documented as a no-op when OpenSSL arrives via libssh2 anyway.
///
/// That is the whole crypto-threading obligation, discharged. It is recorded here
/// rather than in a comment on a call site because the next person to wonder
/// will come looking at initialisation.
///
/// ## Seam for Sorties 4 and 12
///
/// Two things belong here and are deliberately absent until there is a network
/// call to hang them on:
///
/// - **The trust store.** With `USE_HTTPS=OpenSSL`, certificate verification uses
///   OpenSSL's compiled-in `OPENSSLDIR`, which does not exist inside an app
///   sandbox, so HTTPS fails with a certificate error unrelated to the network.
///   The fix is either `git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, …)`
///   pointing at a shipped bundle, or validating in libgit2's
///   `certificate_check` callback via Security.framework. Whichever is chosen, it
///   is a **global** option and its natural home is this initialiser. See
///   README § The trust store problem.
/// - **Host key verification** (Sortie 12) is per-connection, not global, so it
///   does *not* belong here — noted so nobody adds it to init by symmetry.
enum Libgit2Runtime {

    /// Runs `git_libgit2_init()` on first touch, exactly once per process.
    private static let initialized: Int32 = {
        let count = git_libgit2_init()
        // A failure here means libgit2 could not set up its global state, and
        // every subsequent call would fail in a less legible way. There is no
        // recovery and nothing to report to — the error is not thread-local yet
        // because there is no thread-local state to hold it.
        precondition(
            count >= 0,
            """
            git_libgit2_init() failed with \(count). libgit2's global state could \
            not be initialised, so no repository operation can work.
            """
        )
        return count
    }()

    /// Idempotent, cheap after the first call, and safe from any thread.
    ///
    /// Called by ``gitCall(_:tolerating:_:)``, which every libgit2 call in this
    /// package goes through — so ordering is guaranteed rather than remembered.
    static func ensureInitialized() {
        _ = initialized
    }
}

extension SwiftRepositorio {

    /// Whether this build's libgit2 implements **shallow** clone and fetch.
    ///
    /// `true`, with one transport-shaped exception. libgit2 1.9.6 negotiates
    /// `deepen` over the smart transports, so `CloneOptions.depth` is real for the
    /// HTTPS and SSH paths the product clones over. The **local** transport
    /// refuses it outright.
    ///
    /// | Path | What `depth` does |
    /// |---|---|
    /// | HTTPS / SSH (smart transport) | negotiated; errors if the server does not advertise the `shallow` capability |
    /// | any local path or `file://`, **whatever `localStrategy`** | **refused** — `GIT_ENOTSUPPORTED`, "shallow fetch is not supported by the local transport" |
    ///
    /// ## The property that matters more than the flag
    ///
    /// **libgit2 never silently ignores `depth`.** Either it negotiates a shallow
    /// fetch, or it returns an error. There is no configuration in which a
    /// depth-limited clone quietly downloads the full history.
    ///
    /// That was worth establishing by experiment rather than by reading, and the
    /// reading got it wrong first: `git_clone__should_clone_local` sends a plain
    /// local path down the object-database *copy* path, and `clone_local_into`
    /// never reads `depth` — which looked like a silent-ignore trap. It is not,
    /// because `clone_local_into` still calls `git_remote_fetch` afterwards to set
    /// up refs, and that fetch goes through the local transport, which refuses. The
    /// test in `GitRepositoryTests` asserts this for every `localStrategy` so the
    /// conclusion is measured rather than inferred.
    ///
    /// ## Consequence for the clone size guard
    ///
    /// The requirements document worried that `depth` might be absent and that
    /// § Clone's size guard would need a pre-flight host-API size check instead.
    /// The answer is better than feared: because failure is loud, a `depth`-based
    /// guard on a *remote* clone cannot silently do nothing — it either shallow-
    /// clones or errors, and an error is actionable. A pre-flight size check is
    /// still the more informative guard, since it can refuse before any bytes move,
    /// but it is no longer required for correctness.
    ///
    /// One thing this constant does not prove: the smart-transport path is
    /// source-verified (`smart_protocol.c` handles `wants->depth > 0`,
    /// `GIT_PKT_SHALLOW`, `GIT_PKT_UNSHALLOW`) and the plumbing from
    /// ``CloneOptions/depth`` to the transport is proven by the local transport's
    /// refusal arriving at all — but no test here clones from a live remote,
    /// because this suite has no network and must not gain one.
    public static let supportsShallowClone = true
}
