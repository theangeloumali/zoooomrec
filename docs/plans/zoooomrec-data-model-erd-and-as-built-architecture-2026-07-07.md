# zoooomrec — Data Model (ERD) + As-Built Architecture (2026-07-07)

> Authored from the **shipped code** at commit `9be6afa` (v0.2), not from the plan — every field below was read out of `Sources/ZoomTypes/Models.swift` and a real `project.json` on disk. Updated for the **bundle format v2** cursor contract (ZR-101, commit `27ad2c0`): the pointer is no longer burned into the pixels.
>
> Companion docs: [master plan](./zoooomrec-cross-platform-zoomable-screen-recorder-master-plan-2026-07-07.md) · [v0.2 plan](./zoooomrec-v0.2-live-hotkey-zoom-smooth-feel-menubar-2026-07-07.md)

---

## 1. Why there is no database

zoooomrec is **local-first**: nothing leaves the device, and there is no server, no Postgres, no ORM. Its data model is a **file bundle** — the `.zoooomrec` directory — plus a small set of value types.

That makes the ERD _more_ important, not less: the bundle format is the **day-1 cross-platform contract**. A recording made by the macOS app must be readable by the future iOS, Android, and Windows apps. This document is that contract.

---

## 2. Persisted data model — the `.zoooomrec` bundle

Everything below is written to disk. `project.json` and `events.jsonl` are the only schema surfaces we must keep stable across platforms.

```mermaid
erDiagram
    ZOOOOMREC_BUNDLE ||--|| PROJECT_MANIFEST : "project.json"
    ZOOOOMREC_BUNDLE ||--|| RECORDING_MP4 : "recording.mp4"
    ZOOOOMREC_BUNDLE ||--o{ INPUT_EVENT : "events.jsonl (one per line)"
    PROJECT_MANIFEST ||--o{ ZOOM_SEGMENT : "segments (optional, embedded)"

    PROJECT_MANIFEST {
        Int version "2"
        String videoFile "recording.mp4"
        String eventsFile "events.jsonl"
        Int pixelWidth "3840"
        Int pixelHeight "2160"
        Double fps "60"
        Double durationSeconds "10.883"
        Array segments "nullable: nil = derive"
        Double zoomScale "nullable: nil = ZoomDefaults.scale"
        Bool cursorBurnedIn "nullable: nil = true (v1 legacy)"
    }
    INPUT_EVENT {
        Double t "sec since first video frame"
        Enum kind "see event-kind table"
        Double x "capture-space px, top-left origin"
        Double y "capture-space px, top-left origin"
    }
    ZOOM_SEGMENT {
        Double start "sec"
        Double end "sec"
        Double centerX "raw px, clamped at render"
        Double centerY "raw px, clamped at render"
        Double scale "magnification"
    }
    RECORDING_MP4 {
        String codec "H.264"
        Int width "= manifest.pixelWidth"
        Int height "= manifest.pixelHeight"
        Bool cursorBurnedIn "false (v2) — pointer lives in the move track"
    }
```

### Three nullable fields carry all the behavior

| Field                   | `nil` means                                                | Set means                                                              |
| ----------------------- | ---------------------------------------------------------- | --------------------------------------------------------------------- |
| `manifest.segments`     | derive zooms from the event stream at render time          | use these exact zooms (an edited/manual timeline)                     |
| `manifest.zoomScale`    | fall back to `ZoomDefaults.scale` (2.0)                    | the magnification chosen at record time (`--zoom-scale`)             |
| `manifest.cursorBurnedIn` | **`true`** — a v1 bundle with the real pointer in the pixels | `false` (v2): the pointer is out of the pixels and lives only in the `move` events, drawn synthetically at render |

> Read `cursorBurnedIn` through the computed `cursorIsBurnedIn` (`cursorBurnedIn ?? true`), never by unwrapping it directly — a missing key must resolve to a legacy v1 bundle.

### `InputEvent.kind` enum

| Raw value                    | Emitted by                               | Used for                                    |
| ---------------------------- | ---------------------------------------- | ------------------------------------------- |
| `move`                       | 60 Hz cursor poll (no permission needed) | cursor-follow target inside a zoom          |
| `left_click` / `right_click` | listen-only CGEventTap (Input Monitoring, or Accessibility) | **AutoZoom** click clustering               |
| `key_down`                   | CGEventTap                               | extends an AutoZoom cluster's hold (typing) |
| `scroll`                     | CGEventTap                               | reserved; creates no segment                |
| `zoom_in`                    | **⌃⌥Z** hotkey                           | **ManualZoom** — opens a zoom / retargets   |
| `zoom_out`                   | **⌃⌥X** hotkey                           | **ManualZoom** — closes the zoom            |

> `CropKeyframe { t, rect: Rect }`, `CursorFrame { position: Point, opacity }`, and the `Rect { x, y, width, height }` / `Point { x, y }` value types they carry are deliberately **absent from the ERD**: all are derived per-frame at render time and never persisted. `Rect` and `Point` are platform-free value types, deliberately _not_ `CGRect` / `CGPoint`, so the crop and cursor math port to Android/Windows unchanged; the CoreImage layer bridges them only at the render boundary. `CursorFrame` — where the synthetic pointer sits and how opaque it is on a given output frame — is recomputed from the `move` event track every render, so the cursor can be re-smoothed, resized, or faded later. Persisting any of these would freeze the animation and break re-rendering at a different spring feel.

### Format versions

| `manifest.version` | Cursor storage                                                                        | How a reader must treat it                                                     |
| ------------------ | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| **v1**             | The real macOS pointer is **burned into** `recording.mp4` (`cursorBurnedIn` absent)   | Never draw a synthetic cursor — the pixels already have one                     |
| **v2**             | Pointer is captured as `move` **events only** (`cursorBurnedIn: false`)               | Draw the pointer synthetically from the `move` track, smoothed and idle-faded   |

A reader that does not recognise `cursorBurnedIn` must treat it as **`true`** (legacy v1), so old bundles keep rendering correctly and never end up with two pointers. This is exactly what `ProjectManifest.cursorIsBurnedIn` (`cursorBurnedIn ?? true`) encodes — every platform port is expected to mirror that default.

---

## 3. How persisted data becomes a zoomed video

The renderer picks exactly one zoom lane, then compiles it into per-frame crop rects.

```mermaid
flowchart TD
    M{"manifest.segments<br/>set?"}
    M -->|yes| USE["use them verbatim"]
    M -->|no| HK{"any zoom_in<br/>event?"}
    HK -->|yes| MAN["ManualZoom<br/>hotkey markers"]
    HK -->|no| AUTO["AutoZoom<br/>click clusters"]
    USE --> TL
    MAN --> TL
    AUTO --> TL
    TL["ZoomTimeline<br/>spring + cursor-follow"] --> KF["CropKeyframe per frame"]
    KF --> COMP["CoreImage crop + scale"]
    COMP --> MP4["zoomed MP4"]
```

**Precedence rule (as shipped):** explicit edits > your hotkeys > inferred clicks. When you direct the zoom by hand, auto-zoom stays out of the way.

The spring that turns segments into motion:

| Parameter          | Value | Role                                                                 |
| ------------------ | ----- | -------------------------------------------------------------------- |
| `omega`            | 4.2   | attack (zoom-in) + all panning → ≈1s glide                           |
| `releaseOmega`     | 3.2   | release (zoom-out) → relaxes slower than it attacks                  |
| `deadZoneFraction` | 0.7   | cursor may roam the inner 70% of the crop before the zoom re-targets |

---

## 4. As-built module graph

Dependencies flow **downward only** — `ZoomTypes` is the shared contract and depends on nothing.

```mermaid
flowchart TD
    CLI["ZoooomrecCLI<br/>record · render · app"]
    APP["ZoooomrecApp<br/>menu bar"]
    CAP["CaptureEngine<br/>ScreenCaptureKit + CGEventTap"]
    REN["RenderEngine<br/>AVFoundation + CoreImage"]
    ENG["ZoomEngine<br/>AutoZoom · ManualZoom · ZoomTimeline"]
    TYP["ZoomTypes<br/>the bundle contract"]

    CLI --> APP
    CLI --> CAP
    CLI --> REN
    APP --> CAP
    APP --> REN
    REN --> ENG
    CAP --> TYP
    ENG --> TYP
```

**Why this shape matters for the roadmap:** `ZoomEngine` + `ZoomTypes` contain zero platform APIs — pure Swift value types and math, covered by the platform-free `ZoomEngineTests` suite (33 tests, one of which fails if either module imports a platform framework). The AVFoundation renderer — including the synthetic-cursor compositor — is proven separately by `RenderEngineTests`. They port to iOS unchanged. Only `CaptureEngine` (ScreenCaptureKit → ReplayKit/MediaProjection) and the UI shell are platform-specific. That is the ~60%-reuse claim in the master plan, now concrete.

---

## 5. Cross-platform contract rules (bindings on every future port)

1. **Coordinates** are capture-space **pixels**, top-left origin — not points, not normalized. A Retina main display at 1920×1080 pt writes `pixelWidth: 3840`.
2. **Timestamps** (`InputEvent.t`, `ZoomSegment.start/end`) are seconds relative to the **first video frame's presentation time**, never process start. Events before the first frame clamp to `t = 0`.
3. **`events.jsonl` is append-only JSONL**, one `InputEvent` per line, time-sorted. Unknown `kind` values must be skipped, not fatal — this is how we add event kinds without breaking old readers.
4. **Segment centers are stored raw** (possibly out of frame). The renderer clamps per frame. One source of truth: `ZoomTimeline`.
5. **`version: 2`** (current). v1 burned the cursor into `recording.mp4`; v2 moved it out into the `move` track (`cursorBurnedIn: false`) and draws it synthetically. Any breaking change to the above increments the version again, and a missing `cursorBurnedIn` always resolves to `true` (legacy v1).

---

## 6. Known gaps in the model (honest list)

| Gap                                                                                                      | Impact                                                                                  | When it matters                                                                               |
| -------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| **Main display only** — coordinates from a secondary monitor arrive negative and clamp to the frame edge | Recording a second monitor produces edge-pinned zooms                                   | Multi-display capture (next increment)                                                        |
| No audio track in the bundle                                                                             | Mic/system audio unrecorded                                                             | Master plan §5 module 1                                                                       |
| No cursor **size control, click ripples, or loop-cursor** yet                                            | The synthetic pointer draws at native size with idle-fade + smoothing, but the richer Screen-Studio cursor styling is still open | Cursor polish pass (`ZR-102`)                                                                 |
| macOS **hides the real pointer** during text entry and full-screen video, but we still draw the synthetic one from the `move` samples | The rendered cursor can appear where the OS would have shown nothing                     | Recordings that include text fields or full-screen playback                                   |
| No `zoomScale` per-segment                                                                               | One magnification per recording                                                         | Per-zoom scale in the editor                                                                  |
| `scroll` events captured but unused                                                                      | Dead enum case (documented, not dead code)                                              | Scroll-driven auto-zoom, if ever                                                              |

The old "cursor is burned into `recording.mp4`" gap is now **closed** by `ZR-101`: v2 bundles capture with `showsCursor = false` and reconstruct the pointer from the `move` track at render, so it can be smoothed and faded when idle. What remains is cursor _styling_ (`ZR-102`) and the fact that macOS itself hides the real pointer in some contexts while we still draw ours.
