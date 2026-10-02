# Security audit and toolchain record

Date: 2026-09-19

## Scope

This review covered the Zig installation used by this workspace and the security-sensitive surfaces in `src/naza_all.zig`: model download and verification, GGUF bounds, hashing/KDF helpers, authenticated local records, ML-KEM, ML-DSA, secret cleanup, and tensor-size arithmetic. It is a focused source audit and test pass, not a formal cryptographic proof or independent certification.

No background review agents were used. The old `/usr/local/zig-0.15.2/zig` executable and its downloaded archive were confirmed absent. The container's read-only `/usr/local` mount still contains an empty `zig-0.15.2` directory and a broken `/usr/local/bin/zig` symlink; neither contains executable code.

## Verified Zig installation

- Version: Zig 0.15.2 for x86_64 Linux
- Metadata source: `https://ziglang.org/download/index.json`
- Archive source: `https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz`
- Expected and observed archive size: 53,733,924 bytes
- Expected and observed archive SHA-256: `02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239`
- Extracted compiler SHA-256: `2858dc89dbbfdd08cceda1b841e7fd0a793a1a67b49f150bc3d0d1de44ed7f51`
- Install path: `.tools/zig-0.15.2` (excluded by `.gitignore`)

Before extraction, every archive member was required to remain under `zig-x86_64-linux-0.15.2/`; absolute paths, parent traversal, and archive links were rejected. Extraction did not preserve archive ownership or permissions, and group/world write permission was removed from the installed tree.

## Downloader controls

The pinned GGUF downloader now:

- accepts only HTTPS on exact `huggingface.co`/`hf.co` hosts or their dot-delimited subdomains;
- rejects URL userinfo and non-443 ports and validates every redirect hop;
- requests identity encoding and rejects encoded responses;
- bounds declared and streamed content to 8 GiB;
- limits destination path length and rejects non-regular existing destinations;
- creates an exclusive mode-0600 staging file beside the destination;
- hashes while streaming and compares against the pinned SHA-256;
- uses hard-link publication to avoid overwriting an existing destination;
- cleans staged or newly published data on errors; and
- re-verifies the published regular file with an independent bounded read.

The downloader does not provide resumable downloads. A stale `.part` file causes a safe failure and must be inspected or removed manually.

## Findings and remediation

1. **ML-DSA signer/verifier mismatch — remediated by failing closed.** A new sign/verify test proved that ML-DSA-44 signatures produced by the implementation were rejected by its verifier. All ML-DSA parameter sets are now classified `partial`, `pqcCallable` returns false, and the public `Signature` facade returns `error.AlgorithmNotCallable`. The internal arithmetic remains for repair and research only.
2. **HKDF-SHA256 maximum-length overflow — fixed.** Expanding exactly 255 blocks incremented an 8-bit counter after the final block and trapped in safe builds. The increment now wraps only after producing a block, and RFC 5869 plus maximum-length tests cover the boundary.
3. **Unchecked tensor-size multiplication — fixed on mixed-linear paths.** Attacker-controlled dimensions could overflow intermediate `usize` arithmetic and cause a panic or incorrect length comparison. Checked multiplication now returns `error.TensorTooLarge`, with overflow regression tests.
4. **Secret lifetime in ML-KEM — hardened.** Temporary error polynomials, secret vectors, shared-secret derivation blocks, plaintext polynomials, and ephemeral sampling data now use deferred volatile zeroization, including error exits.
5. **Mutable CI action tags — fixed.** Checkout is pinned to the immutable v4.2.2 commit. The third-party Zig setup action was removed; CI downloads the official archive over HTTPS, verifies the same pinned SHA-256 before extraction, removes group/world write permission, and exposes only that verified toolchain.

## Remaining cryptographic limitations

- ML-KEM is `implemented_unverified`: local round-trip and modified-ciphertext implicit-rejection tests pass, but official FIPS 203 known-answer vectors have not been run.
- ML-DSA is disabled and must not be used until signer/verifier interoperability is repaired and official FIPS 204 vectors pass.
- The custom SHA-3/SHAKE implementation passes the included known-answer tests, while HMAC-SHA256 and HKDF-SHA256 pass RFC vectors. These results do not replace independent side-channel review.
- `ctEqual`, `ctCompareMask`, and volatile zeroization are written without secret-dependent early exits, but compiler- and platform-level constant-time behavior has not been formally verified.
- File deletion cannot guarantee physical erasure on copy-on-write filesystems, flash storage, snapshots, or backups.

## Verification commands

```text
.tools/zig-0.15.2/zig fmt --check build.zig src/naza_all.zig
.tools/zig-0.15.2/zig build test --summary all
.tools/zig-0.15.2/zig build run -- selftest
.tools/zig-0.15.2/zig build test -Doptimize=ReleaseSafe --summary all
```

## Native GUI security boundary (2026-10 hardening pass)

The Debian GUI deliberately does **not** introduce a general-purpose UI toolkit or browser runtime. `src/gui.zig` owns rasterization, gradients, component drawing, hit testing, editable buffers, and the embedded ZigGlyph font. The only desktop foreign-code boundary is Xlib for creating the window, receiving input events, and presenting the software framebuffer.

Hardening applied before GUI input is accepted:

- `PR_SET_DUMPABLE=0`; failure aborts the hardened GUI startup.
- Live chat/scanner/Clef edit buffers are `mlock`ed; failure aborts startup.
- The software framebuffer is also `mlock`ed so rendered prompt text is not intentionally eligible for swap; resize re-locks the replacement framebuffer and fails closed on error.
- Fixed-capacity edit buffers avoid allocator churn for live prompt text.
- Explicit volatile zeroization clears edit buffers and framebuffer memory on teardown.
- No clipboard, DnD, remote font, image decoder, HTML, CSS, JavaScript, extension/plugin, or webview surface exists in the GUI.
- Raw prompts are not added to the Clef/quantum history file.

Residual risk: classic X11 is not a strong same-user isolation boundary. Another malicious X11 client under the same account may be able to observe input or window contents regardless of NAZA's internal renderer. This project therefore does **not** claim that X11 becomes "hyper secure" merely because the application code is hardened. Use a dedicated account/session for sensitive desktop operation. The UI event/surface contract is separated from application actions so a Wayland or Android native-surface backend can replace X11 without changing the page/layout engine.
