# zoooomrec — Master Backlog

> **This file is the single source of truth for what is done and what is left.**
> Every contributor and every AI agent reads this **before** writing code. Keep it current: when you finish a ticket, tick it here in the same commit.

**Last verified against the code:** 2026-07-10, commit `6408cb9`.
**Health:** `swift build` clean · **25 unit tests, 0 failures** · live E2E green (2 scenarios).

## Read these first (in order)

1. **This file** — what to work on.
2. [Data model (ERD) + as-built architecture](./plans/zoooomrec-data-model-erd-and-as-built-architecture-2026-07-07.md) — the `.zoooomrec` bundle contract. **Binding on every platform.**
3. [Master plan](./plans/zoooomrec-cross-platform-zoomable-screen-recorder-master-plan-2026-07-07.md) — phasing, platform strategy, estimates.
4. [v0.2 plan](./plans/zoooomrec-v0.2-live-hotkey-zoom-smooth-feel-menubar-2026-07-07.md) — the most recent shipped increment.

## Ground rules for anyone touching this repo

- **Coordinates** are capture-space **pixels**, top-left origin. **Timestamps** are seconds from the first video frame's PTS. Never change these without bumping `manifest.version`.
- **`ZoomEngine` + `ZoomTypes` must stay platform-free** (no AppKit/AVFoundation/UIKit). That purity is what makes the iOS/Android ports cheap. Enforced by review.
- **Zoom is post-production**, never burned in at capture. The raw full-resolution recording is always preserved.
- Zoom-lane precedence: `manifest.segments` (explicit edits) > hotkey markers > click auto-zoom.
- Tests are mandatory for `ZoomEngine`. No new public API on `ZoomTypes`/`ZoomEngine` without a maintainer sign-off.
- **Toolchain:** tests need full Xcode (XCTest is absent from CommandLineTools). See `ZR-900`.

---

## Status legend

`[x]` shipped & verified · `[ ]` not started · `[~]` in progress · **P0** blocker · **P1** needed for MVP · **P2** nice-to-have

---

## Phase 0 — Spike ✅ COMPLETE (commits `fe72ce7`, `aecddb7`)

- [x] **ZR-001** SwiftPM package, module split (`ZoomTypes`/`ZoomEngine`/`CaptureEngine`/`RenderEngine`/CLI)
- [x] **ZR-002** `.zoooomrec` bundle format: `recording.mp4` + `events.jsonl` + `project.json`
- [x] **ZR-003** ScreenCaptureKit capture of the main display (native Retina pixels, 60 fps, H.264)
- [x] **ZR-004** Input-event stream: 60 Hz cursor poll + CGEventTap clicks/keys, anchored to first-frame PTS
- [x] **ZR-005** `AutoZoom` — click clustering → zoom segments, with merge (anti "zoom pumping")
- [x] **ZR-006** `ZoomTimeline` — critically damped spring integrator (closed-form), per-frame crop rects
- [x] **ZR-007** `ZoomRenderer` — streaming AVAssetReader → CoreImage crop/scale → AVAssetWriter
- [x] **ZR-008** CLI `record` / `render`
- [x] **ZR-009** Apache-2.0 licence, README, CONTRIBUTING, Code of Conduct, GitHub Actions CI
- [x] **ZR-010** E2E harness: live screen recording + SSIM zoom proof (`Scripts/e2e-demo.sh`)

## Phase 0.5 — v0.2: live hotkey zoom, feel, menu bar ✅ COMPLETE (commits `c075381`, `4c2e520`)

- [x] **ZR-020** Live hotkeys captured during recording: **⌃⌥Z** zoom-in · **⌃⌥X** zoom-out · **⌃⌥S** stop
- [x] **ZR-021** `ManualZoom` lane — marker pairs → segments; re-press retargets (pan), unclosed runs to end
- [x] **ZR-022** Lane precedence in the renderer (explicit > manual > auto)
- [x] **ZR-023** Zoom feel: spring softened (ω 8 → 4.2 ≈ 1 s glide) + slower release (`releaseOmega` 3.2)
- [x] **ZR-024** Cursor-follow inside a zoom, with a 70 % dead-zone against jitter
- [x] **ZR-025** Optional `--duration`: record until stop-hotkey or Ctrl+C (SIGINT), 3-way stop race
- [x] **ZR-026** Instant result: auto-render a sibling `.mp4` the moment recording stops (`--no-render`, `--open`)
- [x] **ZR-027** `--zoom-scale`, persisted to `manifest.zoomScale`
- [x] **ZR-028** Menu-bar app (`zoooomrec app`): start/stop, zoom picker, reveal/open last, quit
- [x] **ZR-029** E2E scenario 2: posts **real** hotkeys, asserts live marker capture + zoom hold + release
- [x] **ZR-030** Data-model ERD + as-built architecture doc

---

## Phase 1 — macOS MVP (the real app) 🎯 NEXT

Goal: a macOS app a stranger can download, launch, and produce a polished demo with. Everything below is required to call zoooomrec "v1" on desktop.

### 1a. Capture completeness

- [ ] **ZR-101** **P0 — Stop burning the cursor into the video.** Capture with `showsCursor = false` and record a dedicated cursor track. _Blocks ZR-102 and every Screen-Studio cursor feature; the current bundle structurally cannot produce a synthetic cursor._ Bump `manifest.version` when the cursor track lands.
- [ ] **ZR-102** **P1** Synthetic cursor render: Catmull-Rom smoothing over the `move` track, size control, hide-when-static, click ripples, loop-cursor.
- [ ] **ZR-103** **P1** Audio capture: microphone + system audio (SCK 13+), muxed into the bundle.
- [ ] **ZR-104** **P2** Audio at render: mute, duck under voice.
- [ ] **ZR-109** **P1** Capture picker: specific **window**, **screen region**, and **multi-display**. _Today it is main-display-only; a cursor on a secondary monitor arrives with negative coordinates and clamps to the frame edge (see `ZR-905`)._
- [ ] **ZR-112** **P1** Long-recording robustness: 30 min with no frame drops or unbounded memory; free-disk preflight.

### 1b. The editor (the surface users actually live in)

- [ ] **ZR-107** **P0** Editor UI (SwiftUI): preview canvas, timeline with draggable/resizable zoom segments, click-to-edit scale + focus point, scrubbing, trim handles.
- [ ] **ZR-108** **P1** Per-segment zoom scale + per-segment easing override (today one `zoomScale` per recording).
- [ ] **ZR-113** **P1** Trim start/end (write `segments` + trim into the manifest; re-render).
- [ ] **ZR-105** **P1** Backgrounds & styling: solid / gradient / image, outer padding, corner radius, shadow, inset.
- [ ] **ZR-114** **P2** Recording indicator + countdown before capture starts.

### 1c. Export

- [ ] **ZR-106** **P1** Export presets: resolution 720p–4K, fps 24/30/60, aspect ratios 16:9 / 9:16 / 1:1 / 4:3, and GIF export with palette quantization.

### 1d. Ship it

- [ ] **ZR-110** **P0** Permissions onboarding: live TCC status for Screen Recording + Accessibility, detect-and-relaunch after grant. _The #1 drop-off in this category — treat as a designed surface._
- [ ] **ZR-111** **P0** Distribution: proper `.app` bundle, Developer ID signing, notarization, Sparkle auto-update, landing page.

## Phase 1.5 — Screen Studio parity (post-MVP, demand-ordered)

- [ ] **ZR-150** **P2** Webcam selfie overlay that auto-dodges the cursor/zoom target
- [ ] **ZR-151** **P2** Keystroke display overlay (`key_down` is already captured — mostly a render feature)
- [ ] **ZR-152** **P2** iPhone/iPad recording over USB + automatic device frames
- [ ] **ZR-153** **P2** Local voice normalisation + background-noise removal
- [ ] **ZR-154** **P2** Local transcript → auto-subtitles
- [ ] **ZR-155** **P2** Vertical re-export that re-frames zooms automatically (keyframe re-layout, not a re-record)
- [ ] **ZR-156** **P2** Shareable style presets (JSON; portable across platforms via the bundle format)

## Phase 2a — iOS (the empty open-source niche)

> Manual zoom only — iOS cannot observe system-wide taps. `ZoomEngine` + `ZoomTypes` should port with **zero changes**; if they don't, that's a bug in their platform purity.

- [ ] **ZR-200** **P1** In-app recording via ReplayKit
- [ ] **ZR-201** **P0** Broadcast Upload Extension for system-wide capture — hard **~50 MB memory cap**: write straight to `AVAssetWriter`, buffer nothing
- [ ] **ZR-202** **P0** Port `ZoomEngine`/`ZoomTypes` unchanged; Metal compositor
- [ ] **ZR-203** **P0** Touch-driven manual zoom UI (add segment, pinch scale, drag focus point)
- [ ] **ZR-204** **P1** Device frames + App Store / TikTok / X aspect presets
- [ ] **ZR-205** **P1** Store distribution + monetisation surface (see `ZR-402`)
- [ ] **ZR-206** **P2** `.zoooomrec` interop with macOS over iCloud (the cross-device differentiator)

## Phase 2b — Android

- [ ] **ZR-250** **P0** MediaProjection + MediaCodec capture; `foregroundServiceType="mediaProjection"`; **consent every session** (Android 14/15) — design the UX around it
- [ ] **ZR-251** **P1** System audio via `AudioPlaybackCapture`
- [ ] **ZR-252** **P0** Timeline + zoom engine in Kotlin (or adopt a shared core — see `ZR-300`)
- [ ] **ZR-253** **P0** Jetpack Compose editor
- [ ] **ZR-254** **P0** GLES / Media3 `Transformer` compositor (3-day spike to choose)
- [ ] **ZR-255** **P1** Manual zoom only at launch. **AccessibilityService tap capture is security-vetoed** until an explicit Play-policy review.

## Phase 3 — Windows + shared-core decision

- [ ] **ZR-300** **P0** Decision gate: extract a shared Rust/wgpu core vs a third native port. _Do not pre-build the core; decide when the Apple and Android codebases have actually diverged._
- [ ] **ZR-301** **P0** Windows.Graphics.Capture + WASAPI loopback
- [ ] **ZR-302** **P1** Low-level input hooks (`WH_MOUSE_LL`) → auto-zoom parity with macOS
- [ ] **ZR-303** **P0** D3D11 compositor + Media Foundation export

## Phase 4 — Cloud (deliberately last; local-first is a feature)

- [ ] **ZR-400** **P2** Share links: upload rendered MP4 to R2/S3, player page with OG tags, signed URLs, real deletion
- [ ] **ZR-401** **P2** Cross-device sync of `.zoooomrec` projects (iCloud first)
- [ ] **ZR-402** **P1** Monetisation surface — decide: paid store binary vs open-core cloud vs sponsors-only

---

## Cross-cutting: engineering health

These are small, real, and found by verification — not speculative.

- [ ] **ZR-900** **P1** **Toolchain pinning.** `swift test` fails with `unable to resolve module dependency: 'XCTest'` when `xcode-select` points at CommandLineTools (XCTest ships only with full Xcode). Happened live on 2026-07-10 when `Xcode.app` was replaced by `Xcode-beta.app`. Document `DEVELOPER_DIR`, add a toolchain note to CONTRIBUTING, and consider `.xcode-version`. CI (`macos-14`) is unaffected.
- [ ] **ZR-901** **P2** No `.swift-format` config exists; formatting is editor-driven. Add one + a CI format check.
- [ ] **ZR-902** **P2** `hooks/dead-code-check.sh` has no Swift scanner. Wire in `periphery`.
- [ ] **ZR-903** **P2** `AutoZoomConfig.minDuration` (1.2 s) can never fire at default config — padding already floors every segment at ≈2.4 s. Either gate significance **pre-pad** (raw click span/count) or drop the knob. _Known, intentionally deferred._
- [ ] **ZR-904** **P1** Menu-bar app: quitting **mid-recording** abandons the `AVAssetWriter`, losing the recording. Finalise (or refuse to quit) on terminate.
- [ ] **ZR-905** **P1** Secondary-display cursor coordinates arrive negative and clamp to the frame edge. Subsumed by `ZR-109` (multi-display), but surface a warning in the meantime.
- [ ] **ZR-906** **P2** CI runs build + unit tests only. Add a headless-safe E2E subset (the synthetic-clip render test is already CI-safe).
- [ ] **ZR-907** **P2** Cross-vendor second-opinion review (Codex) has never run — no login on the current machine. Optional, self-skipping.

---

## Suggested order of attack

1. **ZR-101** (un-burn the cursor) — it is a _format_ change. Do it before the bundle hardens across platforms; everything cursor-shaped is blocked behind it.
2. **ZR-110** + **ZR-111** (permissions + signed app) — turns a CLI spike into something a stranger can run.
3. **ZR-107** (editor UI) — the surface users live in.
4. **ZR-109** (multi-display / window capture) — closes the most-hit real limitation.
5. Then Phase 1 remainder → Phase 2a (iOS), where the open-source niche is genuinely empty.
