# NAZA Pure-Zig

Pure-Zig NAZA with a custom native GUI, secure GGUF handling, crypto utilities, quantum/Clef routing, and fast road/food evidence scans.

## What was implemented

- Custom native Zig desktop GUI + boxed terminal fallback
- Embedded ZigGlyph font/raster system
- Responsive vertical phone layout (`gui-phone`)
- Road-condition scanner
- Food/water scanner
- Fast pure-Zig evidence scanning
- Low/Medium/High risk extraction
- Secure HTTPS GGUF downloader
- SHA-256 model verification
- GGUF inspection
- SHA3-256 and SHAKE256 commands
- ML-KEM and crypto self-tests
- Native CPU optimizations
- Quantized matrix worker pool
- Fused Q3_K dot-product kernel
- 30-profile quantum-inspired RAG ensemble (8-14 qubits)
- Stochastic five-circuit routing with Clef feedback

## Native Zig GUI (Debian first)

The desktop frontend is now a native software-rendered GUI written in Zig. X11 is used only for the Debian window/input surface; there is no GTK, Qt, SDL, Electron, HTML, CSS, JavaScript, or webview UI stack.

The in-house GUI includes:

- animated multi-layer gradients and glow fields;
- Material-inspired elevated cards, pills, navigation, focus states, chips, and touch-sized controls;
- the embedded **ZigGlyph** bitmap/vector-style font engine (no runtime font files or font parsing);
- responsive desktop navigation and a dedicated vertical phone layout;
- Chat/Clef routing, Road Scanner, Food/Water Scanner, Quantum history, and Security Center pages;
- Model Manager with Download + Verify, Verify Local Model, progress and Cancel controls on desktop and phone;
- the same blank-field semantics as the CLI — pressing Enter never invents a scanner default;
- custom software rasterization into a scrubbed framebuffer;
- no clipboard hooks, no drag/drop parser, no remote assets, and no web content surface.

On Debian/Ubuntu, install the X11 development boundary and Zig 0.15.2:

```bash
sudo apt install libx11-dev
zig build
```

Launch the desktop GUI:

```bash
./zig-out/bin/naza-zig gui
```

If `DISPLAY` is available, launching `naza-zig` with no arguments prefers the GUI and falls back to the TUI if the GUI cannot initialize.

Preview the exact narrow vertical/mobile layout on Debian:

```bash
./zig-out/bin/naza-zig gui-phone
```

The layout automatically switches to its phone mode below 720 px wide, so the same renderer is ready for an Android native-surface backend without redesigning every screen.

### GUI hardening

Before accepting GUI input, NAZA disables process dumpability and locks both the live edit buffers and software framebuffer into RAM. If those protections cannot be established, the hardened GUI fails closed instead of silently starting with weaker memory handling. Edit buffers are fixed-capacity and explicitly zeroed when cleared and on shutdown. The GUI does not persist raw prompts.

X11 itself is **not** a strong isolation boundary between programs running as the same Unix user. The custom UI removes large toolkit/browser attack surfaces, but it cannot make the X11 protocol something it is not. For sensitive desktop use, run NAZA in an isolated account/session. The renderer/input contract is intentionally separated so a Wayland or Android surface backend can replace X11 without replacing the UI.

## Build

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/naza-zig-global-cache \
zig build
```

## Android / Termux installation

Install Termux and the matching Termux:API companion from the same trusted
distribution. In Termux, run:

```sh
pkg update -y
pkg install -y git
git clone https://github.com/ornab74/naza-zig.git
cd naza-zig/android/termux
chmod +x install.sh unlock-and-run.sh
bash install.sh
```

The installer:

- installs the signed Termux Zig package and Android build tools;
- creates or reuses the `naza-zig-unlock` Android Keystore alias;
- requires a 2048-bit RSA key with user authentication and secure-hardware
  enforcement;
- pins the checkout to the requested Git ref and builds a `ReleaseSafe`
  `aarch64-linux-android` binary;
- stores the binary and local state under mode-0700 directories; and
- launches only after a fresh Keystore-backed nonce-signing operation.

The installer does not use `termux-fingerprint`. The Android Keystore signing
operation is the only unlock operation. If the device or Termux:API reports
software-only key enforcement, installation stops instead of silently
weakening the protection.

After installation, reopen Termux and run:

```sh
naza
```

For the detailed Android scripts and security notes, see
[`android/termux/README.md`](android/termux/README.md).

## Test

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/naza-zig-global-cache \
.tools/zig-0.15.2/zig build test
```

## Format check

```bash
.tools/zig-0.15.2/zig fmt --check build.zig src/naza_all.zig src/gui.zig
```

## Run the TUI

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/naza-zig-global-cache \
.tools/zig-0.15.2/zig build run -- tui
```

Or:

```bash
./zig-out/bin/naza-zig tui
```

Select:

```text
3) Road Scanner
```

Enter the scanner fields you have. Press Enter to leave any field genuinely blank; no road or food/water defaults are injected.

Chat, road scanning, and food/water scanning now run the verified local GGUF model by default. They do not access GPS, live traffic, weather, satellites, or sensors. GUI inference runs in a separate process with a Stop button, bounded output, and a five-minute deadline. Prompts travel through stdin and are not saved in temporary files or process arguments.

The GUI scanner accepts only an exact `Low`, `Medium`, or `High` model reply. Missing models, inference failures, and invalid replies produce an explicit error; they never default to `Medium`. Blank fields remain blank.

Chat routes through the same 30-circuit ensemble as the Python reference. Use `/quantum` to inspect circuit history and `/clef <0-100>` to score the latest unrated attempt. Ensemble state is stored locally in `clef_quantum_history.json`; raw prompts are not persisted there.

The currently pinned 111 MB model generated incoherent text in live tests with both the Zig executor and the Python llama.cpp reference. Successful execution does not establish useful model quality or a reliable food/water assessment. A suitable replacement model requires its own reviewed download source and SHA-256 pin; this implementation preserves the existing pin.

## Secure model download

Pinned model:

```text
llama3-small-Q3_K_M.gguf
```

SHA-256:

```text
8e4f4856fb84bafb895f1eb08e6c03e4be613ead2d942f91561aeac742a619aa
```

Download:

```bash
mkdir -p models

ZIG_GLOBAL_CACHE_DIR=/tmp/naza-zig-global-cache \
.tools/zig-0.15.2/zig build run -- \
download models/llama3-small-Q3_K_M.gguf
```

Verify:

```bash
ZIG_GLOBAL_CACHE_DIR=/tmp/naza-zig-global-cache \
.tools/zig-0.15.2/zig build run -- \
verify models/llama3-small-Q3_K_M.gguf
```

The downloader:

- Requires HTTPS
- Validates redirects
- Restricts the model host
- Displays download progress
- Uses a mode-0600 staging file
- Verifies SHA-256 before publishing
- Never overwrites an existing destination

In the GUI, open **Models** (or **Model Manager** from Home). Downloading runs in a separate copy of the same executable, without a shell. The window stays responsive, Cancel stops the process and removes its private staging directory, and a 15-minute deadline bounds the operation. The destination is fixed to `models/llama3-small-Q3_K_M.gguf` under the launch directory. Working/model directories must be owned by the current user and must not be writable by other users; a symlinked model directory is refused. Downloads and verification are capped at 512 MiB. An existing file is preserved: use Verify, or move it explicitly before downloading again.

The Python references now share `secure_files.py`, `secure_model.py`, and `secure_rekey.py`. Keys and staged files use mode 0600; plaintext SQLite work lives in unique mode-0700 temporary directories with context-managed cleanup. Model loading uses a verified private snapshot. Key rotation retains encrypted originals in a private recovery journal and restores them at the next startup if interrupted. Existing key files with group/world permissions are refused; inspect and restrict their permissions before reuse. Passphrase mode remains compatible with the original stored derived key format, so it does not require a passphrase at each startup.

Run the offline Python security regression tests with `python3 -m unittest discover -s tests -v`. These use controlled HTTP responses, not a live model download. A real HTTPS download and live X11 interaction have not been validated in this workspace; desktop and phone rendering are checked by the software-renderer tests.

## Test local inference

The same inference entry point used by the GUI can be run without a display:

```bash
printf 'Hello! What is two plus two?' | ./zig-out/bin/naza-zig infer chat 32
printf 'Raw chicken left in the sun for two days.' | ./zig-out/bin/naza-zig infer food 16
```

The token limit must be between 1 and 256; stdin prompts are limited to 8192 bytes. These commands display raw generated model text, so invalid scanner replies can be inspected. The GUI additionally validates the risk label.

## Other commands

Show model information:

```bash
.tools/zig-0.15.2/zig build run -- model
```

Inspect GGUF metadata:

```bash
.tools/zig-0.15.2/zig build run -- \
gguf models/llama3-small-Q3_K_M.gguf
```

List PQC algorithms:

```bash
.tools/zig-0.15.2/zig build run -- pqc
```

Run self-test:

```bash
.tools/zig-0.15.2/zig build run -- selftest
```

## Disclaimer

This is experimental decision-support software. It does not provide live road conditions or prove real-world safety. Verify results independently.
