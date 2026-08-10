---
type: doc
package: SwiftRepositorio
state: current
updated: 2026-08-10
sortie: OPERATION SILENT COURIER — Sortie 1a
---

# Recheck of the two `[UNVERIFIED]` App Store claims

The mission plan's § Decision Brief carries a provenance warning: a research
agent fabricated part of the App Store material and later retracted it. Two
claims were left marked `[UNVERIFIED]` and assigned to Sortie 1 to recheck
before acting:

1. Whether `fork` / `execve` symbol presence carries any App Review or upload
   validation risk.
2. Whether any iOS git client has in fact been rejected — the survey behind
   "none found" was described as incomplete.

Rechecked 2026-08-10. Method: primary sources first (Apple's published
guidelines, the iOS SDK on this machine, upstream project repositories), then
dated developer reports. Every claim below is tied to a source that was actually
fetched. Where nothing was found, this document says "no evidence found" rather
than reasoning toward a conclusion.

> **A note on how the original fabrication probably happened.** Search-engine
> result *summaries* for queries in this area confidently assert things like
> "Apple's automated review system will reject the app for using non-public
> APIs" and "fork/exec would be flagged as non-public symbols." Every forum
> thread those summaries cite was fetched during this recheck, and **none of them
> says that.** The claim is search-engine inference presented as a source. Treat
> any future finding in this area that cannot be traced to a fetched primary page
> as fabricated by default.

---

## Finding 1 — `fork` / `execve` / `posix_spawn` symbol presence

**Verdict: no evidence of App Review or ITMS validation risk from symbol
presence. The plan's decision to disable `GIT_SSH_EXEC` remains correct, but on
runtime-correctness grounds only — the App Store rationale should be dropped, not
softened.**

These are public, SDK-declared, SDK-exported iOS API, which puts them
structurally outside the check they were feared to trip.

| Source | Date | What it says |
|---|---|---|
| `iPhoneOS27.0.sdk/usr/include/unistd.h` (local, Xcode-beta) | verified 2026-08-10 | `execve`, `fork`, `vfork` are declared and annotated **only** `__WATCHOS_PROHIBITED __TVOS_PROHIBITED`. No iOS prohibition, no unavailability. |
| `iPhoneOS27.0.sdk/usr/include/spawn.h` (local) | verified 2026-08-10 | `posix_spawn(...) __API_AVAILABLE(macos(10.5), ios(2.0)) __API_UNAVAILABLE(watchos, tvos)` — explicitly available on iOS since 2.0. |
| `iPhoneOS27.0.sdk/usr/lib/libSystem.B.tbd` (local) | verified 2026-08-10 | The iOS link stub **exports** `_fork`, `_vfork`, `_execve`, `_execv`, `_posix_spawn`, `_posix_spawnp`, `_system`, `_popen`. Ordinary public dynamic imports. |
| <https://developer.apple.com/app-store/review/guidelines/> | fetched 2026-08-10 | 2.5.1 is "Apps may only use public APIs…". The only occurrence of "spawn" on the entire page is **2.4.5(iii)** (Mac App Store), which *permits* spawning and only forbids processes that outlive the app without consent. The phrases "non-public API" and "private API" do not appear. |
| <https://developer.apple.com/forums/thread/747499> | Feb–Mar 2024 | Apple DTS: `fork()` is **not** prohibited in sandboxed macOS apps; recommends `posix_spawn`/`NSTask` because fork-without-exec is unsafe on Apple platforms; iOS apps may not spawn children. A **runtime** statement, not a review statement. |
| <https://developer.apple.com/forums/thread/685544> | Jul 2021 | Quinn, on `forkpty` from a sandboxed Mac App Store app: App Review "wants apps to be functional as is" and requires all bundled code to be sandboxed. The macOS constraint is inheritance of the sandbox, not the symbol. |

What the non-public-symbol scanner actually catches — same mechanism, different
cause — is **name collisions with Apple's internal libraries**:

| Source | Date | What it says |
|---|---|---|
| <https://developer.apple.com/forums/thread/770867>, <https://developer.apple.com/forums/thread/770871> | Dec 2024 | Rejection text: "references non-public symbols … `_lzma_code`, `_lzma_end`". Community fix: link your own static archive. The stated criterion — "if the SDK headers don't expose the functions, consider them private" — **admits** fork/execve/posix_spawn, which do have SDK headers. |
| <https://developer.apple.com/forums/thread/88193> | Sep 2017 | Mangled WebRTC C++ symbols flagged; diagnosis is collision with Apple internals, fixed by namespacing. |
| <https://developer.apple.com/forums/thread/814799> | Feb 2026 | Developer rejected under 2.5.1 for `_SecCertificateIsValid`, which `nm`/`otool`/`strings` show is **not in the binary**. No DTS reply. |

Corroborating negative evidence from a large, well-documented port:

| Source | Date | What it says |
|---|---|---|
| <https://github.com/python/cpython/issues/120522> | Jun 2024 | CPython's real automated rejection was **2.5.2**, triggered by the literal *string* `itms-services` in `urllib/parse.py`. Not fork/exec. |
| `Mac/Resources/app-store-compliance.patch` (CPython 3.14) | fetched 2026-08-10 | The entire App Store compliance patch removes `'itms-services'` and one test. It **does not touch** fork, exec, execve, posix_spawn, or subprocess. |
| <https://peps.python.org/pep-0730/> | — | On iOS `fork` and `spawn` "both exist in the iOS API; however, if they are invoked, the invoking iOS process stops, and the new process doesn't start." A runtime claim; no review claim. |
| CPython `configure.ac` (main) | fetched 2026-08-10 | iOS disables `_posixsubprocess` / `_multiprocessing` with the comment "subprocess and multiprocessing are not supported (no fork syscall)". Reason given is **runtime capability**, not review. |

**Not found**, after searching Apple's forums, GitHub and Stack Overflow: any
report of any app rejected or ITMS-flagged specifically for `fork`, `execve`,
`vfork`, `posix_spawn`, `system` or `popen`.

**Honest limits.** No shipping App Store binary containing those symbols was
inspected — Working Copy's binary and its libgit2 configuration are not publicly
inspectable, and <https://workingcopy.app/> (fetched 2026-08-10) lists no
open-source acknowledgements. And thread 814799 shows the detector is opaque and
can flag symbols that are demonstrably absent, so "structurally impossible" is
the reasonable read but not a guarantee.

### Consequence for this package

The plan already disabled `GIT_SSH_EXEC` "on correctness grounds", leaving the
review question open. That was the right call and it is now closed in the
direction of *no App Store risk*. The correctness ground is unchanged and
sufficient: on iOS the transport fails silently at runtime, and on sandboxed
macOS a spawned `ssh` inherits the sandbox and cannot reach `~/.ssh` anyway.

The build still removes the symbols outright (README § Why `GIT_SSH_EXEC` is
off), for three reasons that survive this finding: the mission's exit criterion
asks for their absence; the detector is opaque enough that fewer third-party
symbols is cheap insurance; and making the file compile only under
`GIT_SSH_EXEC` converts a future silent regression into a link error.

### Correction to the plan's premise

The plan states that `process.o` "should not be pulled into a static link" with
`USE_SSH=libssh2`. Verified against libgit2 1.9.6 source, the *archive* claim is
false and the *link* claim is true:

- `src/util/CMakeLists.txt` does `file(GLOB UTIL_SRC_OS unix/*.c unix/*.h)` for
  every non-Windows platform, and `src/util/unix/process.c` has no `#ifdef`
  guard. Raw `fork()` (line ~374) and `execve()` (line ~409) are compiled into
  `libgit2.a` on every Apple build, exec transport or not. This was confirmed
  independently by two sources during this recheck.
- Nothing references them once `ssh_exec.c` is out: `git_process_start`'s only
  callers are `ssh_exec.c` (inside `#ifdef GIT_SSH_EXEC`), `src/cli/cmd_commit.c`
  (`BUILD_CLI=OFF`) and the test suite (`BUILD_TESTS=OFF`).
  `ssh_libssh2.c` includes `process.h` but only calls
  `git_process__is_cmdline_option()`, a `GIT_INLINE` in the header — no link
  dependency.

So the exit criterion as literally worded ("`nm` over the built static library
shows no `execve` reference") **cannot pass against stock libgit2 1.9.6**. This
is why `scripts/build-xcframework.sh` guards the translation unit and why
`scripts/verify-no-spawn.sh` offers `--allow-unreferenced-process` for anyone who
would rather verify the weaker, still-sound property.

---

## Finding 2 — iOS/macOS git client rejections

**Verdict: no documented rejection of any dedicated git client, on either
platform. The plan's "none found" holds after a wider survey — and "none found"
is still the right phrasing, not "none exists".**

The well-documented enforcement events in this neighbourhood were against
**shells and interpreters**, under **guideline 2.5.2**, and both were reversed on
appeal.

| App | Status 2026-08-10 | Evidence |
|---|---|---|
| **iSH** | live (Theodore Dubois, v1.3.2) | <https://mjtsai.com/blog/2020/11/09/ish-and-a-shell-vs-the-app-store/>, <https://appleinsider.com/articles/20/11/09/apple-backtracks-on-app-store-removal-threat-for-unix-shell-ios-apps> — 2020-11-09. Removal notice 2020-10-26 under **§2.5.2**: "not self-contained and has remote package updating functionality"; Apple suggested removing "wget or curl, or other remote network commands". **Appeal accepted 2020-11-09.** (Apple-facing page <https://ish.app/app-store-removal> returns HTTP 403 to automated fetch and could not be quoted directly.) |
| **a-Shell** | live (v2.1.0, 2026-07-01) | Same two sources. Termination notice early Nov 2020 under **§2.5.2**; Apple asked for removal of `curl`, `pip`, `wasm`. Appeal reported granted **2020-11-17**. |
| **Working Copy** | live (v6.9.2, 2026-07-14) | No evidence of any rejection found. Searches of the developer's blog and Mastodon surfaced only his commentary on *other* developers' rejections. |
| **Git2Go** | absent | <https://github.com/nerdishbynature/git2go-com/issues/23> — opened 2019-04-16, "I cann't find it in App Store any more!", **no maintainer reply, no reason given**. Absence is not evidence of rejection. |
| **iOctocat** | absent | <https://github.com/dennisreimann/ioctocat> README states only that the repo contents were removed to stop confusion. **No reason for App Store removal stated.** (An aggregator page claims a 2025-06-03 removal date; low-quality source, not relied on.) |
| **Pocket Git** | not present under that name | No evidence of an iOS rejection found. Could not confirm whether the app in question is the Android one of that name. |
| **Textastic** | live, both stores | No evidence of rejection. |
| **Blink Shell** | live (v18.6.3, 2026-07-14) | No evidence of rejection, despite shipping SSH, Mosh and local UNIX tools. |
| **Panic Transmit (iOS)** | discontinued by Panic, Jan 2018 | <https://www.macstories.net/ios/apple-asks-panic-to-remove-icloud-drive-export-feature-from-transmit-for-ios/>, <https://appleinsider.com/articles/14/12/08/transmit-for-ios-restricted-from-using-icloud-drive-forced-to-delete-all-share-sheet-options> — 2014-12-08. Apple required removal of the iCloud Drive export / Share Sheet under then-rule **2.23** (iOS Data Storage Guidelines). **Not SSH, not OpenSSL, not 2.5.2, not 4.7.** Discontinuation was Panic's own choice (<https://9to5mac.com/2018/01/06/panic-discontinue-transmit-ios/>). Transmit 5 for Mac is currently in the Mac App Store. |
| **Nova, Tower, GitUp, Fork** | undetermined | No evidence of rejection found for any. Mac App Store presence could not be reliably confirmed by the method used, so **absence from a search proves nothing** and must not be reported as a ban. |
| **Counter-datapoint** | live | Sandboxed macOS git GUIs are in the Mac App Store today: Gitfox (v4.8.1, 2026-08-10), TaoGit, EasyGit, SnailGit Lite, Git Browser Lite, and "Source Files: Git Storage" (v2026.31, 2026-07-15). Sandbox + Mac App Store is not a categorical blocker for git. |

### On the three specific hypotheses

- **Shipping OpenSSL** — the one with teeth. See Finding 3.
- **SSH functionality** — **no evidence found** of any rejection for shipping
  SSH. Blink Shell, Termius, Secure ShellFish and Prompt all ship it. This
  confirms the plan's § "SSH carries no distinct App Store risk".
- **Guideline 2.5.2** — real, and the operative risk for anything that looks like
  it runs user-supplied code. Verbatim (fetched 2026-08-10): apps "may not
  download, install, or execute code which introduces or changes features or
  functionality of the app". Note the distinction the guideline itself draws:
  downloading **data** is not downloading code, and cloning a repository is
  data. This is consistent with the plan's reading.
- **Guideline 4.7** — the plan's framing is stale. 4.7's current text covers
  "HTML5 and JavaScript mini apps and mini games, streaming games, chatbots, and
  plug-ins" plus retro console/PC emulators. It contains **no** mention of code
  interpreters, and no evidence was found of any shell, git or editor app being
  rejected under it. 2.5.2 is the guideline that bites.
- **macOS specifics worth knowing**, verbatim 2026-08-10: 2.4.5(ii) single
  self-contained installation bundle, no code or resources in shared locations;
  2.4.5(iii) no auto-launch and no processes outliving the app without consent;
  2.4.5(iv) may not download or install standalone apps, kexts or additional
  code; 2.4.5(v) no root escalation or setuid. Bundling libraries is consistent
  with all of these; downloading a `git` binary at runtime is not.

---

## Finding 3 — new, not in the plan: statically linked OpenSSL symbols

Not one of the two assigned items, but it turned up during the recheck and it
changes the risk picture for decision D-6, so it is recorded here rather than
lost.

| Source | Date | What it says |
|---|---|---|
| <https://developer.apple.com/support/third-party-SDK-requirements/> | fetched 2026-08-10 | **OpenSSL** and **BoringSSL / openssl_grpc** are both on Apple's named list requiring a privacy manifest **and** a signature. Confirms the plan's ITMS-91061 premise. |
| <https://developer.apple.com/forums/thread/799244> | Sep 2025 | An app rejected for "non-public symbols … `_BIO_s_socket`, `_OPENSSL_cleanse`" from **statically linked** gRPC/OpenSSL. Apple Staff asked for the app ID; **no published fix in the thread.** |
| <https://docs.python.org/3/using/ios.html> | fetched 2026-08-10 | Names OpenSSL as a library requiring an `.xcprivacy` manifest, and notes that standard-library code trips automated rules in ways that "appear to be false positives" but cannot be challenged. |

**Why this matters.** It is a *third* OpenSSL risk, distinct from the two the
plan enumerates, and neither existing mitigation touches it:

| Risk | Mitigation | Addresses Finding 3? |
|---|---|---|
| ITMS-90338 (`*context`) | `no-async` at configure time | No |
| ITMS-91061 (privacy manifest) | signed XCFramework, or the app's own manifest | No |
| Non-public symbol names colliding with Apple's internal BoringSSL | symbol prefixing / hidden visibility at OpenSSL build time, or fewer OpenSSL symbols reaching the final link | — |

The plan's Sortie 14 upload criterion already covers this in practice: it is the
same upload validation, and a failure will name the offending symbols. What
changes is the **expected failure mode**. If that upload fails, the most likely
cause per this evidence is not the privacy manifest and not `no-async` — it is
OpenSSL symbol names. The remedy, if it comes to that, is an OpenSSL build with a
symbol prefix (OpenSSL 3 supports building with a custom symbol prefix, and gRPC's
`openssl_grpc` fork exists precisely because of this collision class), which is a
substantially larger change than either mitigation now in the plan.

It is worth pricing that before the upload, not after: it is the single most
likely way Option A's one live App Store risk actually materialises, and it is a
build-pipeline change, which means it lands in this package.
