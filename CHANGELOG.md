# Changelog

## Unreleased

- No scroll bars in lists (with "Always show" they took space and changed the lists' width).
- The file's properties (codec, kbps, Hz, channel, W, F) have room for two lines, kept even when no file is open, so the layout doesn't move and nothing is cut. A line breaks only after a comma, never inside a property.

## 1.0

First release: Spek 0.8.5 rewritten as a native macOS app.

- Same layout, keys (c s f w l u p), analysis, window functions and palettes as Spek; the keys are also in the Spectrogram menu, and their values in Settings, remembered between launches.
- macOS window with unified toolbar (Open, Save, Help), light and dark mode, system fonts, rounded spectrogram frame; one column per pixel on Retina screens.
- Parallel decoding with a minimal bundled FFmpeg, FFTs with Accelerate, decoded samples kept in memory: a 5-minute file in about 0.15 s, and key presses or resizes recompute without decoding again.
- No update check, nothing goes online.
