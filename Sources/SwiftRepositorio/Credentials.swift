import Clibgit2

/// A credential this package can hand to libgit2.
///
/// ## Why there is no case that names a file
///
/// Every case here carries **material**, not a path. libgit2 offers
/// `git_credential_ssh_key_new`, which takes the paths of a key pair on disk and
/// reads them itself — and it is deliberately unreachable from this type.
///
/// Two reasons, in order of how much they hurt. First, a sandboxed macOS app
/// cannot read `~/.ssh` at all, so a path-based credential would work in
/// development, fail after sandboxing, and fail in a way that looks like an
/// authentication problem rather than a file-access one. Second, private key
/// material belongs in the Keychain, and the whole point of keeping it there is
/// that it is never a file the app can be made to read. Importing a key is a
/// deliberate, user-initiated act that happens once, elsewhere (Sortie 9); by the
/// time a credential reaches this layer it is bytes in memory.
///
/// So this layer does no disk I/O, and cannot be asked to.
public enum Credential: Sendable {

    /// A username and a secret sent in the clear over TLS.
    ///
    /// For GitHub this is the shape a Personal Access Token takes: the username is
    /// ignored by the server and the token goes in the password field. Named
    /// `plaintextOverTLS` rather than `userpass` so that the call site says out
    /// loud that the secret's only protection is the transport — which is also why
    /// nothing should ever send one over `http://`.
    case plaintextOverTLS(username: String, secret: String)

    /// An SSH key pair held **in memory**.
    ///
    /// - Parameters:
    ///   - username: The SSH user, `"git"` for GitHub.
    ///   - publicKey: OpenSSH public key text. May be empty; libssh2 can derive it
    ///     from the private key, and an imported key does not always come with its
    ///     `.pub`.
    ///   - privateKey: PEM or OpenSSH private key text.
    ///   - passphrase: `nil` for an unencrypted key.
    case sshKeyInMemory(username: String, publicKey: String, privateKey: String, passphrase: String?)

    /// The username only, for the first round of an SSH conversation.
    ///
    /// libssh2 sometimes asks for a username before it will say which
    /// authentication methods it supports, so a provider that cannot answer this
    /// will fail before it gets a chance to offer a key.
    case usernameOnly(String)

    /// Builds the libgit2 credential.
    ///
    /// Called from inside libgit2's own callback, so it must not suspend and must
    /// capture its error on this thread — hence `gitCall`, as everywhere else.
    ///
    /// `public` so a test can prove the constructors this build actually has —
    /// specifically that `git_credential_ssh_key_memory_new` is present, which is
    /// only true when libgit2 was compiled with GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS.
    /// The returned pointer is owned by the caller until libgit2 takes it.
    public func makeLibgit2Credential() throws -> UnsafeMutablePointer<git_credential>? {
        var credential: UnsafeMutablePointer<git_credential>?
        switch self {
        case let .plaintextOverTLS(username, secret):
            try gitCall("git_credential_userpass_plaintext_new") {
                git_credential_userpass_plaintext_new(&credential, username, secret)
            }
        case let .sshKeyInMemory(username, publicKey, privateKey, passphrase):
            // git_credential_ssh_key_memory_new exists only when libgit2 was built
            // with GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS, which requires a libssh2 that
            // exports libssh2_userauth_publickey_frommemory. Both are asserted at
            // build time — scripts/verify-no-spawn.sh check C requires the symbol,
            // and check D requires the define — so reaching this line means the
            // capability is present rather than hoped for.
            try gitCall("git_credential_ssh_key_memory_new") {
                git_credential_ssh_key_memory_new(
                    &credential,
                    username,
                    publicKey.isEmpty ? nil : publicKey,
                    privateKey,
                    passphrase
                )
            }
        case let .usernameOnly(username):
            try gitCall("git_credential_username_new") {
                git_credential_username_new(&credential, username)
            }
        }
        return credential
    }
}

/// What libgit2 says it will accept for a given request.
public struct CredentialKinds: OptionSet, Sendable, CustomStringConvertible {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let plaintextOverTLS = CredentialKinds(rawValue: GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue)
    /// An SSH key **from disk** — never offered by this package. Present so a
    /// provider can recognise it in `allowed` and decline.
    public static let sshKeyFromDisk = CredentialKinds(rawValue: GIT_CREDENTIAL_SSH_KEY.rawValue)
    public static let sshKeyInMemory = CredentialKinds(rawValue: GIT_CREDENTIAL_SSH_MEMORY.rawValue)
    public static let sshInteractive = CredentialKinds(rawValue: GIT_CREDENTIAL_SSH_INTERACTIVE.rawValue)
    public static let usernameOnly = CredentialKinds(rawValue: GIT_CREDENTIAL_USERNAME.rawValue)
    public static let systemDefault = CredentialKinds(rawValue: GIT_CREDENTIAL_DEFAULT.rawValue)

    public var description: String {
        var names: [String] = []
        if contains(.plaintextOverTLS) { names.append("plaintextOverTLS") }
        if contains(.sshKeyFromDisk) { names.append("sshKeyFromDisk") }
        if contains(.sshKeyInMemory) { names.append("sshKeyInMemory") }
        if contains(.sshInteractive) { names.append("sshInteractive") }
        if contains(.usernameOnly) { names.append("usernameOnly") }
        if contains(.systemDefault) { names.append("systemDefault") }
        return names.isEmpty ? "[]" : "[\(names.joined(separator: ", "))]"
    }
}

/// Supplies credentials on demand.
///
/// ## Called from libgit2's thread, possibly repeatedly
///
/// libgit2 calls this from inside the transport, synchronously, and **will call it
/// again** if the credential is rejected — its own documentation warns that "it's
/// easy to get in a loop if you fail to stop providing the same incorrect
/// credentials". A provider that keeps returning the same rejected token will spin
/// until the server gives up.
///
/// Implementations must therefore track their own attempts and return `nil` once
/// they have nothing new to offer. ``attempt`` is passed in so a provider does not
/// have to keep that state itself: it starts at 0 and increments per request for
/// the same URL.
///
/// It is not `async`, and cannot be. The call arrives from C on the transport's
/// thread with no way to suspend, which means a provider that needs to prompt a
/// human has to have done so already — the credential must be in hand before the
/// fetch or push starts.
public protocol CredentialProvider: Sendable {

    /// - Parameters:
    ///   - url: The resource being authenticated to.
    ///   - username: A username embedded in the URL, if there was one.
    ///   - allowed: What libgit2 will accept for this request.
    ///   - attempt: 0 for the first request for this URL, incrementing thereafter.
    /// - Returns: A credential, or `nil` to stop trying.
    func credential(
        for url: String,
        username: String?,
        allowed: CredentialKinds,
        attempt: Int
    ) -> Credential?
}

/// Offers one credential once, then gives up.
///
/// The right default for a token or a key that either works or does not. Because
/// it returns `nil` on the second request, a rejected credential produces one
/// clean authentication failure instead of a retry loop.
public struct SingleCredentialProvider: CredentialProvider {
    private let credential: Credential

    public init(_ credential: Credential) {
        self.credential = credential
    }

    public func credential(
        for url: String,
        username: String?,
        allowed: CredentialKinds,
        attempt: Int
    ) -> Credential? {
        // libssh2 may ask for the username before it will negotiate anything else.
        // Answering that is not an attempt at authentication, so it does not count
        // against the one-shot budget.
        if allowed == .usernameOnly, case let .sshKeyInMemory(username, _, _, _) = credential {
            return .usernameOnly(username)
        }
        return attempt == 0 ? credential : nil
    }
}
