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

Record your screen to a `.zoooomrec` bundle:

```sh
.build/release/zoooomrec record --output demo.zoooomrec --duration 10
```

Render a zoomed demo MP4 from a recording:

```sh
.build/release/zoooomrec render demo.zoooomrec --output demo-zoomed.mp4
```

### Permissions

- The first `record` run requires **Screen Recording** permission. macOS will prompt you (or silently deny) the first time — grant it under **System Settings → Privacy & Security → Screen Recording** for your terminal app, then re-run the command.
- Click-driven auto-zoom works best when **Input Monitoring** is also granted (same Privacy & Security section). Without it, zoom falls back to following cursor movement only.

## Roadmap

macOS app with an editor UI → iOS → Android → Windows. Full plan: [docs/plans/zoooomrec-cross-platform-zoomable-screen-recorder-master-plan-2026-07-07.md](docs/plans/zoooomrec-cross-platform-zoomable-screen-recorder-master-plan-2026-07-07.md).

## License

[Apache-2.0](LICENSE).
