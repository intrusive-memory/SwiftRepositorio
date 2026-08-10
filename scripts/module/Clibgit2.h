/*
 * Clibgit2.h — the C module surface SwiftRepositorio imports.
 *
 * This file is COPIED VERBATIM into every slice of Clibgit2.xcframework by
 * scripts/build-xcframework.sh. It is committed (rather than generated inside
 * the build script) so that a later sortie can widen the module surface by
 * editing a header, not by editing a shell script.
 *
 * Deliberately narrow. `git2.h` pulls in the whole public libgit2 API.
 * `libssh2.h` is here for exactly one reason: the runtime assertion that the
 * LINKED libssh2 is >= 1.11.0 must read `libssh2_version()` from the library
 * itself, never from the build script — the build script is the thing that
 * would be wrong.
 *
 * The `git2/sys/*.h` headers (custom transports, custom streams, credential
 * internals) are shipped in the slice's Headers directory but intentionally
 * NOT included here: adding one is a deliberate act by the sortie that needs
 * it. Add the #include below, rebuild the xcframework, and say why in the
 * commit message.
 *
 * OpenSSL headers are NOT shipped at all. libcrypto/libssl are linked into the
 * merged archive but their API is a libgit2/libssh2 implementation detail;
 * exposing <openssl/*.h> to Swift would leak the crypto backend into this
 * package's public surface, which is precisely what a backend swap must not
 * have to renegotiate.
 */

#ifndef CLIBGIT2_MODULE_H
#define CLIBGIT2_MODULE_H

#include "git2.h"
#include "libssh2.h"

#endif /* CLIBGIT2_MODULE_H */
