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
