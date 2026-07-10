# Contributing to zoooomrec

Thanks for helping build an open-source zoomable screen recorder. zoooomrec is a Phase 0 spike — a macOS-first Swift package — so contributions are focused on the CLI and the core engines below.

## Build and test

```sh
swift build
swift test
```

`swift test` runs the unit suites. ZoomEngine is the fully unit-tested core; add or update tests there whenever you change zoom or timeline logic.

> **Toolchain:** `swift test` needs **full Xcode** — `XCTest` does not ship with the Command Line Tools. If you see `unable to resolve module dependency: 'XCTest'`, point at Xcode rather than debugging your code:
>
> ```bash
> DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
> # or permanently: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
> ```
>
> `swift build` works fine on Command Line Tools alone. Tracked as `ZR-900` in [docs/BACKLOG.md](docs/BACKLOG.md).

## End-to-end demo

`bash Scripts/e2e-demo.sh` proves the whole pipeline on a REAL screen recording: it records the screen, generates on-screen activity, renders the zoomed MP4, and asserts (via ffmpeg SSIM) that the zoom actually happened. It runs two scenarios — auto-zoom from clicks, and live ⌃⌥ hotkey zoom — writing the MP4s to `recordings/`.

The activity is driven by the `E2EDemo` helper executable (`Sources/E2EDemo`), which posts synthetic input via `CGEvent` and therefore needs **Accessibility** trust (posting events is an Accessibility capability, distinct from the recorder's listen-only Input Monitoring tap). Every subcommand degrades to a passive sleep when untrusted, so the script never crashes:

| Subcommand                                          | What it does                                                                                                                                                                                      |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `E2EDemo drive --seconds <N>`                       | Glides the cursor around the main display and posts real left-clicks at 25% / 50% / 75% of the timeline, so the recorder captures click activity.                                                 |
| `E2EDemo patch <bundle.zoooomrec> --min-clicks <N>` | Reads the bundle's `events.jsonl` and, if it holds fewer than `<N>` real clicks, **injects** synthetic `left_click` events at 25% / 50% / 75% of the duration so auto-zoom is guaranteed to fire. |
| `E2EDemo hotkeys --seconds <N>`                     | Posts real ⌃⌥Z / ⌃⌥X keystrokes mid-recording to exercise the live manual-zoom path end-to-end.                                                                                                   |
| `E2EDemo stoptest`                                  | Posts a single ⌃⌥S keystroke to exercise the live stop hotkey.                                                                                                                                    |

Honest caveat: scenario 1's auto-zoom proof does not depend on the recorder capturing real clicks. The `patch` step **injects** synthetic clicks whenever fewer than three real ones were captured (e.g. on an untrusted machine or in CI), so the zoom you see may be driven by injected clicks rather than captured ones. Scenario 2's markers, by contrast, are the real ⌃⌥Z / ⌃⌥X keystrokes captured live.

## Module map

The package is split into small, single-responsibility targets:

- **ZoomTypes** — shared models and the fixed contract between every other module. Treat these types as the stable interface; changing them ripples everywhere.
- **ZoomEngine** — pure auto-zoom + spring-timeline logic. No platform dependencies, fully unit-tested. This is where zoom math lives.
- **CaptureEngine** — ScreenCaptureKit screen + input capture.
- **RenderEngine** — the AVFoundation / CoreImage zoom renderer that composites the final video.
- **ZoooomrecCLI** — a thin command-line layer wiring the engines together (`record`, `render`).

## Code rules

- No TODO comments without an owner and date — e.g. `// TODO(alex, 2026-08-01): handle empty event stream`. Untagged TODOs will be rejected in review.
- No commented-out code — git is the archive. Delete it.
- Public API changes to **ZoomTypes** or **ZoomEngine** require a maintainer sign-off before merge. These are the shared contract and the tested core; changes there affect every module and consumer.
- Keep engines platform-agnostic where the module boundary implies it (ZoomTypes and ZoomEngine must not import capture/render frameworks).

## Sign-off (DCO)

We use the [Developer Certificate of Origin](https://developercertificate.org/). Every commit must carry a `Signed-off-by` line certifying you wrote the change or have the right to submit it:

```
Signed-off-by: Your Name <you@example.com>
```

Add it automatically with:

```sh
git commit -s
```

Commits without a valid `Signed-off-by` line will not be merged.
