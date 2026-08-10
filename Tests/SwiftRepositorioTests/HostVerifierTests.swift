import Foundation
import Testing

import SwiftRepositorio

/// The host-verification contract, tested directly.
///
/// ## Why these are unit tests rather than transport tests
///
/// The local transport never invokes `certificate_check` — there is no host and no
/// certificate to check — so no fixture-based fetch or push can exercise this. The
/// alternatives were a live TLS connection, which this suite must not have, or
/// testing the protocol against the certificates libgit2 would hand it. The second
/// is the one that can actually assert the thing that matters: that the default
/// refuses.
@Suite("Host verification")
struct HostVerifierTests {

    /// A plausible-looking SSH host key certificate.
    private static func sshCertificate(sha256: Data?) -> HostCertificate {
        .sshHostKey(sha256: sha256, sha1: nil, rawHostKey: nil)
    }

    private static let knownDigest = Data(repeating: 0xAB, count: 32)
    private static let otherDigest = Data(repeating: 0xCD, count: 32)

    // MARK: - The default fails closed

    /// Exit criterion: the default implementation returns failure for an
    /// unrecognised fingerprint.
    @Test("the default verifier rejects an unrecognised host key")
    func defaultRejectsUnknownHostKey() {
        let verdict = FailClosedHostVerifier().verify(
            certificate: Self.sshCertificate(sha256: Self.otherDigest),
            host: "github.com",
            libgit2ConsidersValid: false
        )

        guard case let .rejected(reason) = verdict else {
            Issue.record("the default verifier must reject, got \(verdict)")
            return
        }
        #expect(reason.contains("github.com"))
        #expect(!reason.isEmpty, "a rejection has to say why or the user cannot act on it")
    }

    /// The dangerous case, and the reason `.deferToLibgit2` is never the default.
    ///
    /// libgit2 has no host-key database, so for SSH it reports `valid` as false and
    /// has no opinion to defer to. A verifier that deferred would accept **any**
    /// key from anyone — and would then hand the user's private key to whoever
    /// answered.
    @Test("the default verifier rejects even when libgit2 says the certificate is valid")
    func defaultRejectsEvenWhenLibgit2SaysValid() {
        let verdict = FailClosedHostVerifier().verify(
            certificate: Self.sshCertificate(sha256: Self.knownDigest),
            host: "github.com",
            libgit2ConsidersValid: true
        )
        guard case .rejected = verdict else {
            Issue.record("the default must not trust libgit2's verdict for it, got \(verdict)")
            return
        }
    }

    @Test(
        "the default verifier rejects every certificate kind",
        arguments: [
            HostCertificate.x509(der: Data([0x30, 0x82])),
            HostCertificate.sshHostKey(sha256: nil, sha1: nil, rawHostKey: nil),
            HostCertificate.unrecognised(kind: 99),
        ]
    )
    func defaultRejectsEveryKind(certificate: HostCertificate) {
        let verdict = FailClosedHostVerifier().verify(
            certificate: certificate,
            host: "example.com",
            libgit2ConsidersValid: true
        )
        guard case .rejected = verdict else {
            Issue.record("expected rejection for \(certificate), got \(verdict)")
            return
        }
    }

    @Test("the default verifier never returns .deferToLibgit2")
    func defaultNeverDefers() {
        // Deferring is the one answer that would silently accept an SSH host key.
        // Asserted separately from the rejections above because a future refactor
        // that "simplified" the default to `.deferToLibgit2` would still be
        // returning a valid HostVerification and would pass a looser test.
        let verdict = FailClosedHostVerifier().verify(
            certificate: Self.sshCertificate(sha256: Self.knownDigest),
            host: "github.com",
            libgit2ConsidersValid: true
        )
        #expect(verdict != .deferToLibgit2)
    }

    // MARK: - Pinned fingerprints

    @Test("a pinned verifier trusts a matching SHA-256 digest")
    func pinnedVerifierTrustsAMatch() {
        let verifier = PinnedFingerprintVerifier(
            fingerprints: ["github.com": [Self.knownDigest]]
        )
        let verdict = verifier.verify(
            certificate: Self.sshCertificate(sha256: Self.knownDigest),
            host: "github.com",
            libgit2ConsidersValid: false
        )
        #expect(verdict == .trusted)
    }

    @Test("a pinned verifier rejects a digest it does not know")
    func pinnedVerifierRejectsAMismatch() {
        let verifier = PinnedFingerprintVerifier(
            fingerprints: ["github.com": [Self.knownDigest]]
        )
        let verdict = verifier.verify(
            certificate: Self.sshCertificate(sha256: Self.otherDigest),
            host: "github.com",
            libgit2ConsidersValid: false
        )
        guard case let .rejected(reason) = verdict else {
            Issue.record("expected rejection, got \(verdict)")
            return
        }
        // The reason has to name the possibilities, because the user is the only
        // one who can tell a key rotation from an attack.
        #expect(reason.contains("unrecognised host key"))
    }

    @Test("a pinned verifier rejects a host it has no entry for")
    func pinnedVerifierRejectsUnknownHost() {
        let verifier = PinnedFingerprintVerifier(
            fingerprints: ["github.com": [Self.knownDigest]]
        )
        let verdict = verifier.verify(
            certificate: Self.sshCertificate(sha256: Self.knownDigest),
            host: "gitlab.com",
            libgit2ConsidersValid: true
        )
        guard case let .rejected(reason) = verdict else {
            Issue.record("expected rejection, got \(verdict)")
            return
        }
        #expect(reason.contains("gitlab.com"))
    }

    @Test("a pinned verifier rejects a host key with no SHA-256 digest")
    func pinnedVerifierRejectsMissingDigest() {
        let verifier = PinnedFingerprintVerifier(
            fingerprints: ["github.com": [Self.knownDigest]]
        )
        let verdict = verifier.verify(
            certificate: Self.sshCertificate(sha256: nil),
            host: "github.com",
            libgit2ConsidersValid: false
        )
        guard case .rejected = verdict else {
            Issue.record("expected rejection when there is nothing to compare, got \(verdict)")
            return
        }
    }

    @Test("a pinned verifier will not accept an X.509 certificate as a host key")
    func pinnedVerifierRejectsWrongCertificateKind() {
        let verifier = PinnedFingerprintVerifier(
            fingerprints: ["github.com": [Self.knownDigest]]
        )
        let verdict = verifier.verify(
            certificate: .x509(der: Self.knownDigest),
            host: "github.com",
            libgit2ConsidersValid: true
        )
        // The digest bytes happen to match the pin, which is exactly the confusion
        // worth ruling out: an X.509 body is not a host-key fingerprint.
        guard case .rejected = verdict else {
            Issue.record("expected rejection for the wrong certificate kind, got \(verdict)")
            return
        }
    }

    @Test("a pinned verifier accepts any of several digests for one host")
    func pinnedVerifierAcceptsRotationSet() {
        // How a real deployment survives a key rotation: pin both keys for the
        // overlap period.
        let verifier = PinnedFingerprintVerifier(
            fingerprints: ["github.com": [Self.knownDigest, Self.otherDigest]]
        )
        #expect(
            verifier.verify(
                certificate: Self.sshCertificate(sha256: Self.otherDigest),
                host: "github.com",
                libgit2ConsidersValid: false
            ) == .trusted
        )
    }

    @Test("an empty pin set for a host is a rejection, not a wildcard")
    func emptyPinSetRejects() {
        let verifier = PinnedFingerprintVerifier(fingerprints: ["github.com": []])
        guard case .rejected = verifier.verify(
            certificate: Self.sshCertificate(sha256: Self.knownDigest),
            host: "github.com",
            libgit2ConsidersValid: true
        ) else {
            Issue.record("an empty set must not mean 'trust anything'")
            return
        }
    }
}

/// The credential surface: what it offers, and what it refuses to.
@Suite("Credentials")
struct CredentialTests {

    @Test("the one-shot provider offers its credential once and then stops")
    func singleProviderStopsAfterOneAttempt() {
        let provider = SingleCredentialProvider(
            .plaintextOverTLS(username: "x-access-token", secret: "ghp_example")
        )

        let first = provider.credential(
            for: "https://github.com/o/r.git",
            username: nil,
            allowed: .plaintextOverTLS,
            attempt: 0
        )
        #expect(first != nil)

        // libgit2's own docs warn that it will keep asking until the callback stops
        // offering: "it's easy to get in a loop if you fail to stop providing the
        // same incorrect credentials". Returning nil is how that loop is avoided.
        let second = provider.credential(
            for: "https://github.com/o/r.git",
            username: nil,
            allowed: .plaintextOverTLS,
            attempt: 1
        )
        #expect(second == nil, "a rejected credential must not be offered again")
    }

    @Test("an SSH provider answers a username-only request without spending its attempt")
    func sshProviderAnswersUsernameRequest() {
        let provider = SingleCredentialProvider(
            .sshKeyInMemory(
                username: "git",
                publicKey: "",
                privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\n",
                passphrase: nil
            )
        )

        // libssh2 asks for the username before it will negotiate anything else.
        // Answering that is not an authentication attempt, and treating it as one
        // would exhaust the budget before a key was ever offered.
        let username = provider.credential(
            for: "git@github.com:o/r.git",
            username: nil,
            allowed: .usernameOnly,
            attempt: 0
        )
        guard case let .usernameOnly(name) = username else {
            Issue.record("expected a usernameOnly credential, got \(String(describing: username))")
            return
        }
        #expect(name == "git")
    }

    @Test("every credential kind builds a libgit2 credential")
    func credentialsConstruct() throws {
        // Proves the memory-based SSH constructor is actually present in this build.
        // git_credential_ssh_key_memory_new only exists when libgit2 was compiled
        // with GIT_SSH_LIBSSH2_MEMORY_CREDENTIALS, which needs a libssh2 exporting
        // libssh2_userauth_publickey_frommemory — both asserted by
        // scripts/verify-no-spawn.sh, and this is the runtime confirmation.
        let credentials: [Credential] = [
            .plaintextOverTLS(username: "user", secret: "token"),
            .usernameOnly("git"),
            .sshKeyInMemory(
                username: "git",
                publicKey: "ssh-ed25519 AAAA test",
                privateKey: "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n",
                passphrase: nil
            ),
        ]

        for credential in credentials {
            let built = try credential.makeLibgit2Credential()
            #expect(built != nil, "\(credential) produced no libgit2 credential")
            if let built {
                // Freed here rather than leaked: libgit2 takes ownership only when a
                // callback hands it back, which is not what happened.
                built.pointee.free?(built)
            }
        }
    }

    @Test("the credential kinds option set decodes libgit2's bitmask")
    func credentialKindsDecode() {
        let both: CredentialKinds = [.plaintextOverTLS, .sshKeyInMemory]
        #expect(both.contains(.plaintextOverTLS))
        #expect(both.contains(.sshKeyInMemory))
        #expect(!both.contains(.sshKeyFromDisk), "a disk-based key is never what this package offers")
        #expect(both.description.contains("plaintextOverTLS"))
    }
}
