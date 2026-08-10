import Foundation

import Clibgit2

/// Everything a fetch or push needs from its caller.
public struct RemoteOptions: Sendable {

    /// Supplies credentials. `nil` means unauthenticated access only, which is
    /// enough for a public HTTPS clone and for the local transport.
    public var credentialProvider: (any CredentialProvider)?

    /// Decides whether to trust the host.
    ///
    /// Defaults to ``FailClosedHostVerifier``, which refuses everything. That is
    /// deliberately inconvenient: the safe default for an unknown host is not to
    /// talk to it. The local transport never invokes this, so local operations are
    /// unaffected.
    public var hostVerifier: any HostVerifier

    /// Called as objects move. Fires on the transport's thread — see
    /// ``CloneOptions/onProgress``.
    public var onProgress: (@Sendable (TransferProgress) -> Void)?

    /// The remote's own words: `remote: …` lines from the server.
    ///
    /// Worth surfacing rather than dropping. When a push is rejected for a reason
    /// only the server knows — a protected branch, a pre-receive hook — this is
    /// where the explanation arrives, and it arrives here as well as in the error.
    public var onRemoteMessage: (@Sendable (String) -> Void)?

    /// Returns `true` to abort the operation.
    ///
    /// Defaults to reading `Task.isCancelled`. It is a closure rather than a direct
    /// read so that it can be substituted in tests: cancelling a real `Task`
    /// mid-fetch is a race, and a test that depends on winning it is a test that
    /// fails on a fast machine.
    public var isCancelled: @Sendable () -> Bool

    public init(
        credentialProvider: (any CredentialProvider)? = nil,
        hostVerifier: any HostVerifier = FailClosedHostVerifier(),
        onProgress: (@Sendable (TransferProgress) -> Void)? = nil,
        onRemoteMessage: (@Sendable (String) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) {
        self.credentialProvider = credentialProvider
        self.hostVerifier = hostVerifier
        self.onProgress = onProgress
        self.onRemoteMessage = onRemoteMessage
        self.isCancelled = isCancelled
    }

    public static var `default`: RemoteOptions { RemoteOptions() }
}

/// Why a transport operation stopped.
public enum RemoteOperationError: Error, Sendable, Equatable {

    /// The caller cancelled it.
    ///
    /// Distinct from a `GitError` so a cancelled fetch is never reported to a user
    /// as a failure. libgit2 surfaces an aborted callback as `GIT_EUSER` with no
    /// message, which on its own is indistinguishable from a bug.
    case cancelled

    /// The host could not be authenticated. Carries the verifier's reason.
    case hostRejected(host: String, reason: String)

    /// No credential was available, or every one offered was refused.
    case authenticationFailed(underlying: GitError)
}

/// Holds the Swift side of libgit2's callbacks while C holds a pointer to it.
///
/// One instance per operation, alive for exactly the duration of the synchronous
/// libgit2 call that uses it. Reference-counted rather than a struct because
/// `git_remote_callbacks.payload` is a `void *` and needs a stable address.
///
/// Not `Sendable`, and it does not need to be: libgit2 invokes every callback
/// synchronously on the thread that made the call, which is the actor's executor
/// thread. Nothing here crosses a thread boundary.
final class RemoteCallbackContext {

    let options: RemoteOptions

    /// Set when a callback refuses, so the reason survives.
    ///
    /// libgit2 collapses every non-zero callback return into `GIT_EUSER` and
    /// discards whatever the callback knew. Without somewhere to put it, "the host
    /// fingerprint did not match" becomes "error -7" by the time it reaches a
    /// caller — the same class of information loss the thread-local error rule
    /// exists to prevent, arriving from the other direction.
    var refusal: RemoteOperationError?

    /// Per-URL credential attempt counts, so a provider can be asked to stop.
    private var attempts: [String: Int] = [:]

    init(options: RemoteOptions) {
        self.options = options
    }

    func nextAttempt(for url: String) -> Int {
        let attempt = attempts[url] ?? 0
        attempts[url] = attempt + 1
        return attempt
    }

    /// Fills in a `git_remote_callbacks` pointing at this context.
    ///
    /// - Returns: The populated struct. The caller must keep `self` alive for as
    ///   long as the struct is in use — see the `withExtendedLifetime` at every
    ///   call site.
    func makeCallbacks() throws -> git_remote_callbacks {
        var callbacks = git_remote_callbacks()
        try gitCall("git_remote_init_callbacks") {
            git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION))
        }
        callbacks.payload = Unmanaged.passUnretained(self).toOpaque()
        callbacks.transfer_progress = Self.transferProgressCallback
        callbacks.push_transfer_progress = Self.pushTransferProgressCallback
        callbacks.sideband_progress = Self.sidebandCallback
        callbacks.credentials = Self.credentialsCallback
        callbacks.certificate_check = Self.certificateCheckCallback
        return callbacks
    }

    // MARK: - The C callbacks
    //
    // Each is a top-level closure with no captures, so it converts to a C function
    // pointer. Everything they need arrives through `payload`.
    //
    // Split one-per-property rather than assigned inline: as one function this was
    // 98 lines with a cyclomatic complexity of 18, which is too much machinery to
    // read in a single sitting when every branch is a different failure mode.

    private static let transferProgressCallback: git_indexer_progress_cb = { stats, payload in
        guard let context = RemoteCallbackContext.from(payload) else { return 0 }
        if context.options.isCancelled() {
            context.refusal = .cancelled
            // Any non-zero return aborts. libgit2 turns it into GIT_EUSER.
            return -1
        }
        if let stats, let onProgress = context.options.onProgress {
            onProgress(TransferProgress(stats.pointee))
        }
        return 0
    }

    private static let pushTransferProgressCallback: git_push_transfer_progress_cb = { current, total, bytes, payload in
        guard let context = RemoteCallbackContext.from(payload) else { return 0 }
        if context.options.isCancelled() {
            context.refusal = .cancelled
            return -1
        }
        guard let onProgress = context.options.onProgress else { return 0 }
        // Push reports counts, not full indexer statistics, so the unavailable
        // fields are reported as zero rather than invented.
        onProgress(
            TransferProgress(
                totalObjects: Int(total),
                receivedObjects: Int(current),
                localObjects: 0,
                indexedDeltas: 0,
                totalDeltas: 0,
                receivedBytes: Int(bytes)
            )
        )
        return 0
    }

    private static let sidebandCallback: git_transport_message_cb = { text, length, payload in
        guard let context = RemoteCallbackContext.from(payload) else { return 0 }
        if context.options.isCancelled() {
            context.refusal = .cancelled
            return -1
        }
        guard let text, let onRemoteMessage = context.options.onRemoteMessage else { return 0 }
        // Decoded straight from the transport buffer, with replacement rather than
        // failure. The server's bytes are not guaranteed to be UTF-8, and a
        // rejection notice with one mangled character is still readable — whereas a
        // failable conversion would return nil and destroy the only explanation the
        // user is going to get.
        // The rule below prefers the failable `String(bytes:encoding:)`, which is
        // the wrong trade here: it returns nil on invalid UTF-8, and nil means the
        // user never sees the only explanation the server gave them. Replacement
        // characters in a rejection notice are survivable; a discarded notice is
        // not.
        // swiftlint:disable:next optional_data_string_conversion
        let message = String(
            decoding: UnsafeRawBufferPointer(start: text, count: Int(length)),
            as: UTF8.self
        )
        onRemoteMessage(message)
        return 0
    }

    private static let credentialsCallback: git_credential_acquire_cb = { out, url, usernameFromURL, allowedTypes, payload in
        guard let context = RemoteCallbackContext.from(payload) else { return -1 }
        guard let provider = context.options.credentialProvider else {
            // Returning > 0 tells libgit2 no credential was acquired, which lets it
            // report a proper authentication error instead of looping.
            return 1
        }
        let urlString = url.map { String(cString: $0) } ?? ""
        let username = usernameFromURL.map { String(cString: $0) }
        let attempt = context.nextAttempt(for: urlString)

        guard let credential = provider.credential(
            for: urlString,
            username: username,
            allowed: CredentialKinds(rawValue: allowedTypes),
            attempt: attempt
        ) else {
            return 1
        }

        do {
            out?.pointee = try credential.makeLibgit2Credential()
            return 0
        } catch {
            // The credential could not even be constructed — a malformed key, say.
            // libgit2 already holds the message from gitCall's capture.
            return -1
        }
    }

    private static let certificateCheckCallback: git_transport_certificate_check_cb = { cert, valid, host, payload in
        guard let context = RemoteCallbackContext.from(payload) else { return -1 }
        let hostname = host.map { String(cString: $0) } ?? ""
        guard let cert else {
            context.refusal = .hostRejected(
                host: hostname,
                reason: "libgit2 presented no certificate to verify."
            )
            return -1
        }

        switch context.options.hostVerifier.verify(
            certificate: HostCertificate.from(cert),
            host: hostname,
            libgit2ConsidersValid: valid == 1
        ) {
        case .trusted:
            return 0
        case let .rejected(reason):
            context.refusal = .hostRejected(host: hostname, reason: reason)
            // Negative fails the connection. Returning > 0 would mean "I decline to
            // judge, use your own verdict", which for SSH means accepting any host
            // key at all.
            return -1
        case .deferToLibgit2:
            return 1
        }
    }

    private static func from(_ payload: UnsafeMutableRawPointer?) -> RemoteCallbackContext? {
        guard let payload else { return nil }
        return Unmanaged<RemoteCallbackContext>.fromOpaque(payload).takeUnretainedValue()
    }

    /// Re-throws whatever a callback refused with, in preference to libgit2's
    /// `GIT_EUSER`.
    ///
    /// Order matters: a cancelled operation must not be reported as an
    /// authentication failure just because the credential callback also ran.
    func mapError(_ error: GitError) -> any Error {
        if let refusal { return refusal }
        if error.isAuthenticationFailure { return RemoteOperationError.authenticationFailed(underlying: error) }
        return error
    }
}
