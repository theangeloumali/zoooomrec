# zoooomrec

Open-source zoomable screen recording — record your screen, get automatic smooth zoom-ins on your clicks, export polished demo MP4s.

[![CI](https://github.com/theangeloumali/zoooomrec/actions/workflows/ci.yml/badge.svg)](https://github.com/theangeloumali/zoooomrec/actions/workflows/ci.yml)

## Status

**v0.2, macOS.** Working: a command-line tool, a menu-bar app (`zoooomrec app`), live hotkey zoom while recording, and automatic click-driven zoom. Not yet: an editor UI, audio capture, a synthetic (smoothable) cursor, a signed/notarised `.app` bundle, or any non-macOS platform.

See [`docs/BACKLOG.md`](docs/BACKLOG.md) for exactly what is done and what is left.

## How it works

- **Capture**: records a full-resolution video plus an input-event stream (cursor movement, clicks, keys, and your zoom hotkeys) as you work.
- **Zoom**: either **you drive it** — press `⌃⌥Z` mid-recording to zoom at the cursor — or it is **inferred** from your click clusters. Explicit edits beat hotkeys, hotkeys beat inferred clicks.
- **Render**: applies a spring-eased, GPU-accelerated zoom over the source footage, following the cursor while zoomed, to produce the final demo video. Runs automatically the moment you stop recording.

Zoom is always **post-production, never burned in at capture** — the raw full-resolution recording is preserved, so the same take can be re-rendered with different zooms or a different feel.

A recording is stored as a `.zoooomrec` bundle — a directory holding `recording.mp4` (the raw capture), `events.jsonl` (the input-event stream), and `project.json` (metadata and any explicit zoom segments). That format is the [cross-platform contract](docs/plans/zoooomrec-data-model-erd-and-as-built-architecture-2026-07-07.md).

## Requirements

- macOS 13+
- Xcode or the Command Line Tools with Swift 5.9+

## Build

```sh
swift build -c release
```

## Usage

You built the **release** binary above, so run that same binary throughout. macOS ties every permission grant to a specific binary, so switching between the debug binary (`swift run zoooomrec …`) and the release binary (`.build/release/zoooomrec …`) forces you to re-grant Screen Recording and Input Monitoring each time.

The easiest path — the menu-bar app (Start/Stop, zoom scale, reveal last recording):

```sh
.build/release/zoooomrec app
```

Recordings land in `~/Movies/zoooomrec/`. Or use the CLI directly.

For a real, double-clickable, codesigned `zoooomrec.app` — so macOS attaches the permission grants to the app instead of your terminal — build one around the release binary with:

```sh
bash Scripts/make-app.sh
```

With a stable signing identity the grant persists across rebuilds; ad-hoc signing (the fallback) resets it each build.

The fast CLI path — record until you press the stop hotkey, then auto-render:

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

| Hotkey                   | Action                                                             |
| ------------------------ | ------------------------------------------------------------------ |
| `⌃⌥Z` (Control-Option-Z) | Zoom in at the cursor (press again to move the zoom to a new spot) |
| `⌃⌥X` (Control-Option-X) | Zoom out                                                           |
| `⌃⌥S` (Control-Option-S) | Stop recording                                                     |

Hotkeys and click-based auto-zoom share one listen-only event tap that needs an input-tap permission — see [Permissions](#permissions) below. Without it, recording still works, but both fall back to cursor-follow only.

Zoom now feels smoother — a softer spring with a ~1s glide — and it follows the cursor while zoomed.

### Permissions

- The first `record` run requires **Screen Recording** permission. macOS will prompt you (or silently deny) the first time — grant it under **System Settings → Privacy & Security → Screen Recording** for your terminal app, then re-run the command.
- Both the ⌃⌥ zoom hotkeys and click-driven auto-zoom come from a single **listen-only** event tap. It requires **Input Monitoring** — or **Accessibility**, which is a superset that also grants input monitoring — under the same Privacy & Security section. Grant either one. Without it, zoom falls back to following cursor movement only.

## Roadmap

macOS app with an editor UI → iOS → Android → Windows.

**[`docs/BACKLOG.md`](docs/BACKLOG.md) is the single source of truth** for what is done and what is left — every ticket, every phase, with status. Start there.

Supporting documents:

- [Data model (ERD) + as-built architecture](docs/plans/zoooomrec-data-model-erd-and-as-built-architecture-2026-07-07.md) — the `.zoooomrec` bundle contract, binding on every platform
- [Cross-platform master plan](docs/plans/zoooomrec-cross-platform-zoomable-screen-recorder-master-plan-2026-07-07.md) — phasing, platform strategy, estimates

## Contributing

Read [`AGENTS.md`](AGENTS.md) before writing code — it carries the architecture invariants, working agreements, and the traps we have already paid for. It applies to humans and AI agents alike (`CLAUDE.md` simply points there). Then pick a ticket from [`docs/BACKLOG.md`](docs/BACKLOG.md) and tick it there in the same commit that closes it.

## License

[Apache-2.0](LICENSE).
