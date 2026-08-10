import Clibgit2

/// An error reported by libgit2, with its message captured verbatim.
///
/// ## Why `message` is sacred
///
/// When a push is rejected or a fetch is refused, the only useful information is
/// the text the *remote* sent — "remote: error: GH006 Protected branch update
/// failed", "Permission denied (publickey)". libgit2 hands that through
/// `git_error_last()` and nowhere else. Later sorties have exit criteria that
/// depend on that text reaching the user unaltered, so ``message`` is stored
/// exactly as libgit2 produced it: never prefixed, never truncated, never
/// reworded. Presentation belongs in ``description``.
public struct GitError: Error, Sendable, Equatable, CustomStringConvertible {

    /// The libgit2 function that failed, e.g. `"git_clone"`. Ours, not libgit2's.
    public let operation: String

    /// The libgit2 return code — a `git_error_code` value such as
    /// `GIT_ENOTFOUND` (-3). Compare with the `is…` properties below rather than
    /// with bare integers at call sites.
    public let code: Int32

    /// The `git_error_t` class the message came from (`GIT_ERROR_NET`,
    /// `GIT_ERROR_SSH`, …). `-1` when no error structure was available.
    public let klass: Int32

    /// `git_error_last()->message`, **verbatim**.
    ///
    /// Empty only when libgit2 set a code but no message, which does happen —
    /// see ``hasMessage``. Never synthesised: an empty string here means libgit2
    /// genuinely said nothing, and inventing text would make the emptiness
    /// impossible to detect downstream.
    public let message: String

    /// Whether libgit2 actually provided a message.
    public var hasMessage: Bool { !message.isEmpty }

    public init(operation: String, code: Int32, klass: Int32, message: String) {
        self.operation = operation
        self.code = code
        self.klass = klass
        self.message = message
    }

    public var description: String {
        let detail = hasMessage ? message : "(libgit2 set no message)"
        return "\(operation) failed with code \(code): \(detail)"
    }

    // MARK: - Codes worth naming
    //
    // Call sites branch on meaning, not on magic numbers. The ones here are the
    // codes this package's flows actually have to distinguish; the rest stay as
    // `code`.

    /// `GIT_ENOTFOUND` — no such object, reference, or path.
    public var isNotFound: Bool { code == GIT_ENOTFOUND.rawValue }
    /// `GIT_EEXISTS` — something is already there.
    public var isAlreadyExists: Bool { code == GIT_EEXISTS.rawValue }
    /// `GIT_EUNBORNBRANCH` — HEAD names a branch with no commits yet. A freshly
    /// initialised repository is in this state, and it is not a malfunction.
    public var isUnbornBranch: Bool { code == GIT_EUNBORNBRANCH.rawValue }
    /// `GIT_EBAREREPO` — the operation needs a working directory.
    public var isBareRepository: Bool { code == GIT_EBAREREPO.rawValue }
    /// `GIT_EAUTH` — authentication was refused. Sortie 4's territory.
    public var isAuthenticationFailure: Bool { code == GIT_EAUTH.rawValue }
    /// `GIT_ECERTIFICATE` — the server's certificate was rejected. See
    /// README § The trust store problem; under OpenSSL this can also mean the
    /// trust store was never found rather than that the certificate is bad.
    public var isCertificateRejected: Bool { code == GIT_ECERTIFICATE.rawValue }
    /// `GIT_ENOTSUPPORTED` — libgit2 was built without support for what was
    /// asked. How an unsupported shallow fetch reports itself.
    public var isNotSupported: Bool { code == GIT_ENOTSUPPORTED.rawValue }
    /// `GIT_ETIMEOUT`.
    public var isTimeout: Bool { code == GIT_TIMEOUT.rawValue }
}

// MARK: - The C call boundary

/// Calls a libgit2 function and, on failure, captures `git_error_last()` before
/// anything else can happen.
///
/// ## This function is synchronous on purpose, and that is the whole design
///
/// `git_error_last()` is **thread-local** — libgit2's `docs/threading.md` states
/// it outright: "The error message is thread-local. The `git_error_last()` call
/// must happen on the same thread as the error in order to get the message …
/// if you use something like GCD on macOS (where code is executed on an
/// arbitrary thread), the code must make sure to retrieve the error code on the
/// thread where the error happened."
///
/// Swift concurrency is exactly the hazard that warning describes. An `async`
/// function may resume on a different thread than it suspended on, so this shape:
///
/// ```swift
/// let rc = await someIsolatedCall()      // may hop threads on resume
/// if rc < 0 { throw readErrorLast() }    // reads a DIFFERENT thread's error
/// ```
///
/// silently produces empty or, worse, unrelated error messages. It fails as a
/// missing diagnostic rather than as a crash, which is why it survives review.
///
/// The defence here is structural rather than advisory: this function is
/// **not** `async` and takes a **non-async, non-escaping** closure. There is no
/// syntax for a suspension point between `body()` returning and
/// `git_error_last()` being read — the compiler refuses to let one exist. Every
/// libgit2 call in this package goes through here, so the discipline holds by
/// construction and cannot be forgotten by the next sortie.
///
/// - Parameters:
///   - operation: Name of the C function, for the error.
///   - tolerating: Non-zero codes that are expected outcomes rather than
///     failures — `GIT_ENOTFOUND` when probing, `GIT_ITEROVER` when draining an
///     iterator. These are returned to the caller instead of thrown.
///   - body: The C call. Must be synchronous, and must not suspend — which it
///     cannot, being non-`async`.
/// - Returns: The libgit2 return code: `0`, or one of `tolerating`.
@discardableResult
func gitCall(
    _ operation: String,
    tolerating: [git_error_code] = [],
    _ body: () -> Int32
) throws -> Int32 {
    Libgit2Runtime.ensureInitialized()

    let code = body()
    if code >= 0 { return code }
    if tolerating.contains(where: { $0.rawValue == code }) { return code }

    // Same thread as `body()`, guaranteed. Nothing between them can suspend.
    throw captureLastError(operation: operation, code: code)
}

/// Calls a libgit2 function that **produces a handle**, with the same
/// same-thread error capture as ``gitCall(_:tolerating:_:)``.
///
/// ## Why this exists rather than callers declaring their own `var`
///
/// Almost every libgit2 constructor has the shape
/// `int git_thing_new(git_thing **out, …)`, so the obvious spelling is a local
/// `var out: OpaquePointer?` passed as `&out` inside the `gitCall` closure. Under
/// Swift 6 region isolation that does not compile inside an actor:
///
/// ```
/// error: sending 'reference' risks causing data races
/// note: 'reference' is captured by an actor-isolated closure. actor-isolated
///       uses in closure may race against later actor-isolated uses
/// ```
///
/// `OpaquePointer` is not `Sendable`, so once the local is captured by the
/// closure the compiler will not let it be read afterwards. Moving the `var`
/// *inside* this function removes the capture entirely — the pointer comes back
/// as an ordinary return value. The compiler was right to complain, and the
/// resulting API is the better one: it also removes the "reported success but
/// produced no handle" guard that every call site would otherwise repeat.
///
/// - Returns: The handle, or `nil` when `body` returned one of `tolerating`.
func gitHandle(
    _ operation: String,
    tolerating: [git_error_code] = [],
    _ body: (inout OpaquePointer?) -> Int32
) throws -> OpaquePointer? {
    Libgit2Runtime.ensureInitialized()

    var out: OpaquePointer?
    let code = body(&out)

    if code < 0 {
        if tolerating.contains(where: { $0.rawValue == code }) { return nil }
        // Same thread as `body()`. See gitCall's documentation.
        throw captureLastError(operation: operation, code: code)
    }

    guard let out else {
        // A zero return with a NULL out-parameter is a libgit2 contract violation,
        // not something a caller can handle. Reporting it as an error beats
        // an unchecked unwrap into a crash a user would see as a hang.
        throw GitError(
            operation: operation,
            code: GIT_ERROR.rawValue,
            klass: -1,
            message: "libgit2 reported success but produced no handle"
        )
    }
    return out
}

/// Reads `git_error_last()` into an owned Swift value.
///
/// Must only ever be called on the thread that produced the error — see
/// ``gitCall``, which is the only intended caller. The returned `GitError` owns
/// its string, so it is safe to carry across threads afterwards; the
/// thread-locality applies to *reading*, not to what has been read.
private func captureLastError(operation: String, code: Int32) -> GitError {
    guard let error = git_error_last() else {
        // libgit2 can return a failure code without setting a message. Recording
        // that honestly beats inventing text that looks like the library's own.
        return GitError(operation: operation, code: code, klass: -1, message: "")
    }
    // `String(cString:)` copies. The libgit2 buffer is thread-local storage and
    // may be overwritten by the next libgit2 call on this thread, so holding the
    // pointer instead of copying would be a use-after-free in slow motion.
    let message = error.pointee.message.map { String(cString: $0) } ?? ""
    return GitError(operation: operation, code: code, klass: error.pointee.klass, message: message)
}
