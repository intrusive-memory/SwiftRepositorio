import Foundation

import Clibgit2

/// What libgit2 is presenting for approval.
public enum HostCertificate: Sendable {

    /// An X.509 certificate from a TLS connection, DER-encoded.
    case x509(der: Data)

    /// An SSH host key, with whichever digests libgit2 computed for it.
    ///
    /// `sha256` is the one to compare. GitHub publishes SHA-256 fingerprints, and
    /// SHA-1 has been unsuitable for this purpose for years — it is carried only
    /// because libgit2 still reports it and refusing to expose it would push
    /// callers towards `nil`-handling rather than towards the better digest.
    case sshHostKey(sha256: Data?, sha1: Data?, rawHostKey: Data?)

    /// A certificate kind this package does not model.
    ///
    /// Present so an unknown future `git_cert_t` arrives as an explicit unknown
    /// rather than being silently mapped onto something a verifier might approve.
    case unrecognised(kind: Int32)
}

/// The verifier's answer.
public enum HostVerification: Sendable, Equatable {
    /// Proceed.
    case trusted
    /// Refuse the connection.
    case rejected(reason: String)
    /// Defer to libgit2's own judgement — whatever OpenSSL concluded.
    ///
    /// For TLS this means "accept if the chain validated". For SSH it means
    /// **accept anything**, because libgit2 has no host-key knowledge of its own,
    /// which is why ``FailClosedHostVerifier`` never returns it.
    case deferToLibgit2
}

/// Decides whether to trust the host on the other end.
///
/// This is the seam that Sortie 12 (host-key verification and trust persistence)
/// plugs into, and it is also where the OpenSSL trust-store gap gets closed. That
/// gap, from § The trust store problem in the README: with `USE_HTTPS=OpenSSL`,
/// certificate verification consults OpenSSL's compiled-in `OPENSSLDIR`, which
/// does not exist inside an app sandbox — so `valid` arrives `false` for perfectly
/// good certificates and the real chain validation has to happen here, against
/// Security.framework. Until that lands, ``deferToLibgit2`` is not a safe answer
/// for TLS in a sandboxed build, and the default verifier does not give it.
public protocol HostVerifier: Sendable {

    /// - Parameters:
    ///   - certificate: What the host presented.
    ///   - host: The hostname libgit2 connected to.
    ///   - libgit2ConsidersValid: libgit2's own conclusion. For TLS this is
    ///     OpenSSL's chain verdict — and see the note above about why it is
    ///     unreliable in a sandbox. For SSH it is meaningless: libgit2 has nothing
    ///     to compare a host key against, so this is effectively always false.
    /// - Returns: Whether to proceed.
    func verify(
        certificate: HostCertificate,
        host: String,
        libgit2ConsidersValid: Bool
    ) -> HostVerification
}

/// The default verifier: refuses every host it has not been told about.
///
/// ## Fails closed, and has nothing to open with
///
/// This type holds no fingerprints and no trust store, so it rejects everything.
/// That is not a placeholder — it is the correct default for a type whose job is
/// to authenticate a host it knows nothing about. The alternative default,
/// "proceed and let libgit2 decide", accepts **any** SSH host key from anyone,
/// because libgit2 has no host-key database: a machine-in-the-middle presenting
/// its own key would be trusted silently, and the user's private key would then be
/// offered to it.
///
/// Trust-on-first-use is the usual answer to that and is deliberately not here.
/// TOFU needs somewhere durable to remember the key, a way to notice when it
/// changes, and a way to tell the user — which is Sortie 12's design problem, not
/// something to approximate with a dictionary that vanishes when the process
/// exits.
///
/// Supply a verifier that knows GitHub's published fingerprints (see
/// ``PinnedFingerprintVerifier``) or one backed by real trust storage.
public struct FailClosedHostVerifier: HostVerifier {

    public init() {}

    public func verify(
        certificate: HostCertificate,
        host: String,
        libgit2ConsidersValid: Bool
    ) -> HostVerification {
        .rejected(
            reason: """
                No host verifier is configured, so '\(host)' cannot be authenticated. \
                Connections are refused rather than trusted by default: accepting an \
                unverified SSH host key would mean offering the user's private key to \
                whoever answered. Supply a HostVerifier with the expected \
                fingerprints.
                """
        )
    }
}

/// Trusts hosts whose SSH host-key SHA-256 fingerprint is on a known list.
///
/// Enough to talk to a host whose fingerprints are published — GitHub's are, at
/// <https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints>
/// — without needing trust persistence. It compares the SHA-256 digest and
/// nothing else, and it refuses anything it has no entry for.
///
/// Not a substitute for Sortie 12: a pinned list cannot notice a legitimate key
/// rotation, so it will start refusing a host that has done nothing wrong. That is
/// the correct failure direction, but it still needs a human answer eventually.
public struct PinnedFingerprintVerifier: HostVerifier {

    /// Host → the set of acceptable SHA-256 host-key digests.
    private let fingerprints: [String: Set<Data>]

    /// - Parameter fingerprints: Raw 32-byte SHA-256 digests, not base64 or hex.
    ///   Callers holding the published `SHA256:…` form should decode it first;
    ///   taking raw bytes here keeps the comparison away from string formatting.
    public init(fingerprints: [String: Set<Data>]) {
        self.fingerprints = fingerprints
    }

    public func verify(
        certificate: HostCertificate,
        host: String,
        libgit2ConsidersValid: Bool
    ) -> HostVerification {
        guard let expected = fingerprints[host], !expected.isEmpty else {
            return .rejected(reason: "No pinned fingerprint for '\(host)'.")
        }
        guard case let .sshHostKey(sha256, _, _) = certificate else {
            return .rejected(
                reason: "'\(host)' presented a certificate that is not an SSH host key."
            )
        }
        guard let sha256 else {
            return .rejected(reason: "'\(host)' presented a host key with no SHA-256 digest.")
        }
        // Constant-time comparison is not needed: the digest is public
        // information, and an attacker learning which byte differed learns nothing
        // they could not compute themselves.
        guard expected.contains(sha256) else {
            return .rejected(
                reason: """
                    '\(host)' presented an unrecognised host key \
                    (SHA256:\(sha256.base64EncodedString())). This is either a key \
                    rotation or a machine-in-the-middle; it is refused either way.
                    """
            )
        }
        return .trusted
    }
}

// MARK: - Bridging libgit2's certificate

extension HostCertificate {

    /// Reads a `git_cert` into owned Swift values.
    ///
    /// Copies everything: the certificate belongs to libgit2 and is valid only for
    /// the duration of the callback, so anything retained beyond it would be a
    /// dangling read at the moment a verifier decided to log it.
    static func from(_ cert: UnsafeMutablePointer<git_cert>) -> HostCertificate {
        switch cert.pointee.cert_type {
        case GIT_CERT_X509:
            let x509 = UnsafeMutableRawPointer(cert).assumingMemoryBound(to: git_cert_x509.self)
            let data = x509.pointee.data.map {
                Data(bytes: $0, count: Int(x509.pointee.len))
            } ?? Data()
            return .x509(der: data)

        case GIT_CERT_HOSTKEY_LIBSSH2:
            let key = UnsafeMutableRawPointer(cert).assumingMemoryBound(to: git_cert_hostkey.self)
            let available = key.pointee.type

            // Each digest is present only if its bit is set in `type`; reading an
            // absent one yields whatever was in the struct, which would be a
            // fingerprint made of uninitialised memory.
            var sha256: Data?
            if available.rawValue & GIT_CERT_SSH_SHA256.rawValue != 0 {
                sha256 = withUnsafeBytes(of: key.pointee.hash_sha256) { Data($0) }
            }
            var sha1: Data?
            if available.rawValue & GIT_CERT_SSH_SHA1.rawValue != 0 {
                sha1 = withUnsafeBytes(of: key.pointee.hash_sha1) { Data($0) }
            }
            var raw: Data?
            if available.rawValue & GIT_CERT_SSH_RAW.rawValue != 0, let hostkey = key.pointee.hostkey {
                raw = Data(bytes: hostkey, count: key.pointee.hostkey_len)
            }
            return .sshHostKey(sha256: sha256, sha1: sha1, rawHostKey: raw)

        default:
            return .unrecognised(kind: Int32(cert.pointee.cert_type.rawValue))
        }
    }
}
