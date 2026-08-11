---
type: doc
package: SwiftRepositorio
state: current
updated: 2026-08-10
---

# Licences

Every component compiled into `Clibgit2.xcframework`, and its licence. Verified
by reading the source at the pinned revisions, not from memory — the "how this
was determined" column says which file.

`SwiftRepositorio`'s own Swift code carries the package's licence; everything
below arrives through the xcframework.

## What is actually linked

`libClibgit2.a` in each slice is four static archives merged with
`libtool -static`. Some libgit2 dependencies are *present in its source tree* but
**not** compiled under this build's flags, and those are listed separately below
so nobody attributes an obligation this binary does not carry.

| Component | Version | Licence | How this was determined |
|---|---|---|---|
| **libgit2** | 1.9.6 | **GPL-2.0-only WITH a linking exception** | `COPYING` |
| **libssh2** | 1.11.1 | BSD-3-Clause | `COPYING` |
| **OpenSSL** (libssl + libcrypto) | 3.5.7 | Apache-2.0 | `LICENSE.txt` |
| **PCRE2** (bundled in libgit2 as `deps/pcre2`) | as vendored by libgit2 1.9.6 | BSD-3-Clause, with one exemption for certain binary redistributions | `deps/pcre2/LICENCE.md` |
| **llhttp** (bundled as `deps/llhttp`) | as vendored | MIT — © Fedor Indutny, 2018 | `deps/llhttp/LICENSE-MIT` |
| **LibXDiff** (bundled as `deps/xdiff`) | as vendored, from core git | **LGPL-2.1-or-later** — © 2003 Davide Libenzi | header of `deps/xdiff/xdiff.h` |
| **SHA-1DC** (`src/util/hash/sha1dc`) | as vendored | MIT — © 2017 Marc Stevens, Dan Shumow | header of `src/util/hash/sha1dc/sha1.c` |

Presence confirmed by object file, not by assumption: `deps/llhttp`,
`deps/pcre2`, `deps/xdiff`, `hash/collisiondetect` and `hash/sha1dc` all produce
`.o` files in the build tree.

### Present in libgit2's tree but NOT compiled here

| Component | Why it is absent |
|---|---|
| `deps/zlib`, `deps/chromium-zlib` | `USE_BUNDLED_ZLIB=OFF` — the SDK's zlib is linked instead, so no zlib source ships inside this archive |
| `deps/ntlmclient` | `USE_NTLMCLIENT=OFF` |
| `deps/winhttp` | Windows only |
| `src/util/hash/rfc6234` | `USE_SHA256=OpenSSL`, so libgit2's builtin SHA-256 is not built (see README § Why SHA-256 comes from OpenSSL) |

Apple's `libz` and `libiconv` are linked from the SDK as system libraries and are
covered by the Apple SDK licence; no Apple code is redistributed inside the
xcframework.

## libgit2's linking exception, verbatim

This exception is the reason this package is viable at all, so it is quoted in
full rather than paraphrased. From libgit2's `COPYING`:

> **LINKING EXCEPTION**
>
> In addition to the permissions in the GNU General Public License, the authors
> give you unlimited permission to link the compiled version of this library into
> combinations with other programs, and to distribute those combinations without
> any restriction coming from the use of this file. (The General Public License
> restrictions do apply in other respects; for example, they cover modification
> of the file, and distribution when not linked into a combined executable.)

`COPYING` also states that the only valid version of the GPL for libgit2 is v2
specifically — not v2.2, not v3.

Two consequences worth stating plainly:

1. **Linking is permitted; modifying without publishing is not.** The exception
   covers linking, and explicitly does *not* cover modification. This build makes
   one scripted change to libgit2 source — `src/util/unix/process.c` is moved
   behind `#ifdef GIT_SSH_EXEC` (README § Why `GIT_SSH_EXEC` is off). That
   modification therefore stays in this repository, in the open, as the
   transformation applied by `scripts/build-xcframework.sh`. It is not a private
   patch and must not become one.
2. **Re-confirm the exception on every version bump.** It is a grant from the
   libgit2 authors, present in the file, not a property of the GPL. Read `COPYING`
   at the new tag rather than assuming it carried over.

## ⚠️ LibXDiff is LGPL-2.1, and the linking exception does not cover it

This needs a decision above this package's pay grade, so it is written down rather
than smoothed over.

**The facts.** `deps/xdiff` is LibXDiff by Davide Libenzi, licensed
**LGPL-2.1-or-later** (verified in the header of `deps/xdiff/xdiff.h`; there is no
separate `LICENSE` file in that directory, and libgit2's own docs describe it as
"xdiff code taken from core Git"). It is **not optional** — libgit2 1.9.6 has no
`USE_XDIFF` switch (the line is commented out in `CMakeLists.txt`), and its
objects are in our archive. libgit2's linking exception is a grant from *the
libgit2 authors*; Libenzi is not one of them, so it does not extend to his code.

**Why it matters here.** LGPL-2.1 §6 permits combining the library into a
proprietary work, but for **static** linking it attaches conditions — in practice
either shipping the object code plus whatever is needed to relink the work against
a modified library, or shipping the library dynamically. This package links
statically, into an App Store binary, which is the awkward case. It is the same
question every LGPL-static-linking App Store app faces.

**Context that should temper the alarm, without settling it.** Every libgit2
consumer is in this position — GitHub Desktop, Xcode's own source control, and
every iOS git client on the App Store all link the same xdiff. So this is a
well-trodden path rather than a novel exposure, and no libgit2 consumer is known
to have been troubled by it.

**What this package can and cannot do.** It can keep the facts visible, which is
what this section is. It cannot decide the compliance posture. Options, for
whoever does:

- Rely on the same reading the rest of the libgit2 ecosystem relies on, and record
  that decision explicitly somewhere durable.
- Satisfy LGPL-2.1 §6(a) affirmatively by publishing the object files and relink
  instructions for the xcframework — cheap for this package, since
  `scripts/build-xcframework.sh` already reproduces the archive from pinned
  source, and `artifacts/BUILD-PROVENANCE.txt` records the exact inputs.
- Take legal advice.

I am not a lawyer and this is not advice. Flagging it is the correct action; a
`LICENSES.md` that listed xdiff as "BSD-ish" alongside the others would have been
the failure.

**Resolution (2026-08-11, decided by the app's owner — Escribir D-9):** attribution
plus an affirmative relink offer. Escribir's About panel carries the LGPL-2.1 notice
(LibXDiff, © 2003 Davide Libenzi) and points here: this repository IS the offer — the
LGPL-covered source is vendored in the pinned upstream tarballs, `scripts/build-xcframework.sh`
byte-reproduces the shipped archive from them, and `artifacts/BUILD-PROVENANCE.txt`
records the exact inputs. Anyone wishing to modify LibXDiff and relink can rebuild the
xcframework with this pipeline and swap it into the package. Strict LGPL §6(b)
(shipping Clibgit2 as a dynamic framework) was considered and not adopted; it remains
the escalation path if the posture ever needs hardening.

## Export

A bundled crypto library means the **app** carries the paperwork, not the package:
`ITSAppUsesNonExemptEncryption = YES`, plus the one-time French encryption
declaration if it ships in France. `SwiftRepositorio` ships no app and files
nothing itself.

## What is deliberately not here

**wolfSSL.** It is the only libssh2 crypto backend besides OpenSSL that supports
ed25519, and it is GPL with no linking exception — non-viable for a closed-source
App Store binary. Recorded so nobody reaches for it the next time the OpenSSL CVE
treadmill gets tiresome; swapping to it would make the whole app GPL.

**mbedTLS.** Viable licence (Apache-2.0), but its libssh2 backend defines
`LIBSSH2_ED25519 0` — no ed25519 anywhere in the SSH path. That is a product
decision (D-6 chose OpenSSL partly to keep it), not a licence one.
