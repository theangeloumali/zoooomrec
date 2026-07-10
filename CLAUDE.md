# zoooomrec — instructions for AI agents and contributors

**Before writing any code, read [`docs/BACKLOG.md`](./docs/BACKLOG.md).** It is the single source of truth for what is done, what is left, and what to work on next. If you finish a ticket, tick it there **in the same commit**.

## Required reading, in order

1. [`docs/BACKLOG.md`](./docs/BACKLOG.md) — status of every ticket (`ZR-###`). Start here.
2. [`docs/plans/zoooomrec-data-model-erd-and-as-built-architecture-2026-07-07.md`](./docs/plans/zoooomrec-data-model-erd-and-as-built-architecture-2026-07-07.md) — the `.zoooomrec` bundle contract. **Binding on every platform.**
3. [`docs/plans/zoooomrec-cross-platform-zoomable-screen-recorder-master-plan-2026-07-07.md`](./docs/plans/zoooomrec-cross-platform-zoomable-screen-recorder-master-plan-2026-07-07.md) — phasing and platform strategy.

## What this project is

An open-source (Apache-2.0) zoomable screen recorder. Record the screen; get smooth, spring-eased zoom-ins — either automatically from your clicks, or deliberately from hotkeys pressed while recording. macOS first; iOS, Android, Windows on the roadmap.

## Architecture invariants (do not break these)

- **Zoom is post-production, never burned in at capture.** The full-resolution recording is always preserved so it can be re-rendered with different zooms or a different spring feel.
- **`ZoomTypes` and `ZoomEngine` must stay platform-free.** No AppKit, AVFoundation, UIKit, or any OS API. They are pure value types and math, and that purity is exactly what makes the iOS/Android ports cheap. Enforced at review.
- **Dependencies flow downward only:** `CLI`/`App` → `CaptureEngine`/`RenderEngine` → `ZoomEngine` → `ZoomTypes`. `ZoomTypes` depends on nothing.
- **Coordinates** are capture-space **pixels**, top-left origin (not points, not normalised).
- **Timestamps** are seconds relative to the **first video frame's presentation time**, never process start.
- **`events.jsonl` is forward-compatible:** unknown `kind` values are skipped, never fatal. This is how event kinds get added without breaking old readers.
- **Zoom-lane precedence:** `manifest.segments` (explicit edits) > hotkey markers (`zoom_in`/`zoom_out`) > click auto-zoom.
- Any breaking change to the bundle format **must** bump `manifest.version`.

## Working agreements

- **Tests are mandatory for `ZoomEngine`.** It is pure logic; there is no excuse. 25 tests currently pass.
- **No new public API on `ZoomTypes` / `ZoomEngine`** without a maintainer sign-off — every platform port compiles against them.
- No `TODO` without an owner and a date (or a linked issue). No commented-out code. No stub functions in production paths.
- Prefer extending an existing type over forking a parallel one. Search before you create.
- Verify before claiming done: run it, don't just compile it. Screen-recording changes need a real recording, not a unit test.

## Build, test, run

```bash
swift build -c release

# Tests need FULL Xcode — XCTest is absent from CommandLineTools (see ZR-900).
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test

# Menu-bar app (inherits the terminal's Screen Recording + Accessibility grants)
swift run zoooomrec app

# One-shot: record until ⌃⌥S, then auto-render a sibling MP4
.build/release/zoooomrec record --output demo.zoooomrec

# End-to-end proof (records the real screen, posts real hotkeys, asserts SSIM)
bash Scripts/e2e-demo.sh
```

Hotkeys while recording: **⌃⌥Z** zoom in (press again to move the zoom) · **⌃⌥X** zoom out · **⌃⌥S** stop.

## Known traps (learned the hard way)

- `swift test` failing with `unable to resolve module dependency: 'XCTest'` means `xcode-select` points at CommandLineTools. Not a code regression. See `ZR-900`.
- The recorder captures the **main display only**. A cursor on a secondary monitor produces negative coordinates that clamp to the frame edge (`ZR-905`).
- The cursor is currently **burned into** `recording.mp4` (`showsCursor = true`), so a smoothed synthetic cursor is structurally impossible until `ZR-101` lands.
- E2E SSIM assertions must prove zoom **release** by _relative recovery_, not pixel-identity — the release spring is deliberately slow and screen content moves between frames.
- A `.zoooomrec` recorded with no `--duration` blocks until ⌃⌥S or SIGINT. Scripts must always have a stop path.
