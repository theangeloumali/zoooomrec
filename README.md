# zoooomrec

Open-source zoomable screen recording — record your screen, get automatic smooth zoom-ins on your clicks, export polished demo MP4s.

[![CI](https://github.com/zoooomrec/zoooomrec/actions/workflows/ci.yml/badge.svg)](https://github.com/zoooomrec/zoooomrec/actions/workflows/ci.yml)

## Status

Phase 0 spike — macOS CLI proof of concept; not yet an app. There is no GUI, no editor, and no packaged app bundle yet. What exists is a Swift command-line tool that records the screen and renders auto-zoomed output.

## How it works

- **Capture**: records a full-resolution video plus an input-event stream (clicks and cursor movement) as you work.
- **Auto-zoom**: analyzes click clusters to auto-generate zoom segments — no manual timeline editing.
- **Render**: applies a spring-eased, GPU-accelerated zoom over the source footage to produce the final demo video.

A recording is stored as a `.zoooomrec` bundle — a directory holding `recording.mp4` (the raw capture), `events.jsonl` (the input-event stream), and `project.json` (metadata and derived zoom segments).

## Requirements

- macOS 13+
- Xcode or the Command Line Tools with Swift 5.9+

## Build

```sh
swift build -c release
```

## Usage

The fast path — record until you press the stop hotkey, then auto-render:

```sh
.build/release/zoooomrec record --output demo.zoooomrec
```

With no `--duration`, this records until you press `⌃⌥S` (or Ctrl+C), then automatically renders the finished zoomed video to a sibling `demo.mp4` — no separate edit or render step.

For scripted or fixed-duration captures, record for a set time and render explicitly:

```sh
.build/release/zoooomrec record --output demo.zoooomrec --duration 10
.build/release/zoooomrec render demo.zoooomrec --output demo-zoomed.mp4
```

### `record` flags

- `--output <path>` — destination `.zoooomrec` bundle (required).
- `--duration <sec>` — record for a fixed number of seconds. Omit to record until the stop hotkey.
- `--zoom-scale <x>` — zoom magnification (default `2.0`).
- `--no-render` — skip the automatic render and leave just the `.zoooomrec` bundle.
- `--open` — open the rendered MP4 when done.

### Live hotkey zoom

While recording, drive the zoom live from the keyboard:

| Hotkey | Action |
| --- | --- |
| `⌃⌥Z` (Control-Option-Z) | Zoom in at the cursor (press again to move the zoom to a new spot) |
| `⌃⌥X` (Control-Option-X) | Zoom out |
| `⌃⌥S` (Control-Option-S) | Stop recording |

Hotkeys require **Accessibility** permission (**System Settings → Privacy & Security → Accessibility**) in addition to Screen Recording. Without it, recording still works, but hotkeys and click-based auto-zoom fall back to cursor-follow only.

Zoom now feels smoother — a softer spring with a ~1s glide — and it follows the cursor while zoomed.

### Permissions

- The first `record` run requires **Screen Recording** permission. macOS will prompt you (or silently deny) the first time — grant it under **System Settings → Privacy & Security → Screen Recording** for your terminal app, then re-run the command.
- Click-driven auto-zoom works best when **Input Monitoring** is also granted (same Privacy & Security section). Without it, zoom falls back to following cursor movement only.

## Roadmap

macOS app with an editor UI → iOS → Android → Windows. Full plan: [docs/plans/zoooomrec-cross-platform-zoomable-screen-recorder-master-plan-2026-07-07.md](docs/plans/zoooomrec-cross-platform-zoomable-screen-recorder-master-plan-2026-07-07.md).

## License

[Apache-2.0](LICENSE).
