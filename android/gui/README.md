# Android / phone GUI target

The GUI renderer is intentionally phone-ready even though the first live surface backend is Debian/X11.

The reusable UI contract lives in `src/gui.zig`:

- layout switches to vertical mode below 720 px;
- bottom navigation replaces the desktop rail;
- scanner fields stack one-per-row with touch-sized controls;
- the software renderer owns gradients, cards, text, and all pixels;
- platform input is normalized into the internal `InputEvent` contract before page logic sees it;
- business actions remain in `src/naza_all.zig`, outside the window backend.

Use this on Debian to exercise the Android-shaped layout now:

```sh
./zig-out/bin/naza-zig gui-phone
```

A native Android backend should provide an `ANativeWindow`/input surface that feeds the same internal events and receives the same software framebuffer. It should preserve the existing Android Keystore gate before exposing UI input. Do not replace the renderer with a WebView or silently fall back to software-only key storage.

The existing Termux target remains the hardened TUI target until that native surface adapter is packaged as an APK/AAB. This directory documents the boundary explicitly so the phone port does not fork or duplicate the UI design.
