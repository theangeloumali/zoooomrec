#!/usr/bin/env bash
#
# e2e-demo.sh — end-to-end demo test for zoooomrec.
#
# Records a REAL screen recording with visible activity (E2EDemo drive), guarantees
# the event stream has clicks (E2EDemo patch), renders the auto-zoomed output, and
# asserts via ffprobe/ffmpeg that the zoom actually happened. Exit 0 + PASS summary
# on success, non-zero otherwise.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

FFMPEG="/opt/homebrew/bin/ffmpeg"
FFPROBE="/opt/homebrew/bin/ffprobe"
BUNDLE="recordings/e2e-live.zoooomrec"
OUT="recordings/e2e-live-zoomed.mp4"
SRC="$BUNDLE/recording.mp4"
DURATION=12
DRIVE_SECONDS=10

# Thresholds (calibrated by running this script end-to-end).
SSIM_ZOOMED_MAX=0.90    # mid-zoom frame must be visibly transformed (SSIM below this)
SSIM_UNZOOMED_MIN=0.93  # early frame must be preserved (SSIM at/above this)
EARLY_T=0.2             # before the first segment's spring moves

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# SwiftUI macros need a full Xcode toolchain (ZR-909).
# shellcheck source=lib/select-toolchain.sh
source "$SCRIPT_DIR/lib/select-toolchain.sh"

echo "==> [a] swift build -c release"
build_ok=0
for attempt in 1 2 3; do
  if swift build -c release; then
    build_ok=1
    break
  fi
  echo "    build attempt $attempt failed (build-lock contention?); retrying in 3s..."
  sleep 3
done
if [[ "$build_ok" -ne 1 ]]; then
  echo "FATAL: swift build failed after 3 attempts" >&2
  exit 1
fi

mkdir -p recordings

echo "==> [b] start recorder in background (${DURATION}s → $BUNDLE)"
rm -rf "$BUNDLE"
.build/release/zoooomrec record --output "$BUNDLE" --duration "$DURATION" &
REC_PID=$!

echo "==> [c] sleep 1, then drive ${DRIVE_SECONDS}s of on-screen activity (foreground)"
sleep 1
.build/release/E2EDemo drive --seconds "$DRIVE_SECONDS"
echo "    waiting for recorder (pid $REC_PID) to finish..."
wait "$REC_PID"

echo "==> [d] patch clicks into the event stream (min 3)"
.build/release/E2EDemo patch "$BUNDLE" --min-clicks 3

echo "==> [e] render zoomed output → $OUT"
.build/release/zoooomrec render "$BUNDLE" --output "$OUT"

echo "==> [f] assertions"

# --- helpers --------------------------------------------------------------

# ssim_at <timestamp> [out] [src] — extract one frame from OUT and SRC at the same
# timestamp and print the ffmpeg SSIM "All" value for the pair. Defaults to the
# scenario-1 $OUT/$SRC; pass explicit files to reuse it for other scenarios.
ssim_at() {
  local t="$1"
  local out="${2:-$OUT}"
  local src="${3:-$SRC}"
  "$FFMPEG" -nostdin -y -ss "$t" -i "$out" -frames:v 1 "$WORK/out.png" >/dev/null 2>&1
  "$FFMPEG" -nostdin -y -ss "$t" -i "$src" -frames:v 1 "$WORK/src.png" >/dev/null 2>&1
  "$FFMPEG" -nostdin -i "$WORK/out.png" -i "$WORK/src.png" -lavfi ssim -f null - 2>&1 \
    | grep -oE 'All:[0-9.]+' | head -1 | cut -d: -f2
}

# less_than <a> <b> — exit 0 if a < b (float compare via awk)
less_than() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 < b+0)}'; }
ge()        { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }

declare -a NAMES RESULTS DETAILS
record_result() { NAMES+=("$1"); RESULTS+=("$2"); DETAILS+=("$3"); }

# --- assertion 1: output exists and non-empty -----------------------------
if [[ -s "$OUT" ]]; then
  record_result "output exists & non-empty" PASS "$(wc -c < "$OUT" | tr -d ' ') bytes"
else
  record_result "output exists & non-empty" FAIL "missing or empty"
fi

# --- assertion 2: codec is h264 -------------------------------------------
CODEC="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$OUT" 2>/dev/null || echo "?")"
if [[ "$CODEC" == "h264" ]]; then
  record_result "codec is h264" PASS "codec_name=$CODEC"
else
  record_result "codec is h264" FAIL "codec_name=$CODEC"
fi

# --- assertion 3: duration within 0.5s of source --------------------------
SRC_DUR="$("$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$SRC" 2>/dev/null || echo 0)"
OUT_DUR="$("$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$OUT" 2>/dev/null || echo 0)"
DUR_DIFF="$(awk -v s="$SRC_DUR" -v o="$OUT_DUR" 'BEGIN{d=o-s; if(d<0)d=-d; printf "%.3f", d}')"
if awk -v d="$DUR_DIFF" 'BEGIN{exit !(d <= 0.5)}'; then
  record_result "duration within 0.5s" PASS "src=${SRC_DUR}s out=${OUT_DUR}s Δ=${DUR_DIFF}s"
else
  record_result "duration within 0.5s" FAIL "src=${SRC_DUR}s out=${OUT_DUR}s Δ=${DUR_DIFF}s"
fi

# --- assertion 4: ZOOM PROOF via SSIM -------------------------------------
MID_T="$(awk -v s="$SRC_DUR" 'BEGIN{printf "%.3f", s*0.5}')"
MID_SSIM="$(ssim_at "$MID_T")"
EARLY_SSIM="$(ssim_at "$EARLY_T")"
MID_SSIM="${MID_SSIM:-1}"
EARLY_SSIM="${EARLY_SSIM:-0}"

# mid-zoom frame visibly transformed (low SSIM)
if less_than "$MID_SSIM" "$SSIM_ZOOMED_MAX"; then
  record_result "zoom active @ ${MID_T}s (SSIM < $SSIM_ZOOMED_MAX)" PASS "SSIM=$MID_SSIM"
else
  record_result "zoom active @ ${MID_T}s (SSIM < $SSIM_ZOOMED_MAX)" FAIL "SSIM=$MID_SSIM"
fi

# early frame preserved (high SSIM)
if ge "$EARLY_SSIM" "$SSIM_UNZOOMED_MIN"; then
  record_result "unzoomed preserved @ ${EARLY_T}s (SSIM >= $SSIM_UNZOOMED_MIN)" PASS "SSIM=$EARLY_SSIM"
else
  record_result "unzoomed preserved @ ${EARLY_T}s (SSIM >= $SSIM_UNZOOMED_MIN)" FAIL "SSIM=$EARLY_SSIM"
fi

# --- summary (scenario 1) -------------------------------------------------
echo ""
echo "======================================================================"
echo " zoooomrec E2E demo — scenario 1: auto-zoom (clicks) — assertion summary"
echo "======================================================================"
overall1=0
for i in "${!NAMES[@]}"; do
  printf "  [%s] %-46s %s\n" "${RESULTS[$i]}" "${NAMES[$i]}" "${DETAILS[$i]}"
  [[ "${RESULTS[$i]}" == "PASS" ]] || overall1=1
done
echo "----------------------------------------------------------------------"
echo "  bundle: $REPO_ROOT/$BUNDLE"
echo "  mp4:    $REPO_ROOT/$OUT"
echo "  scenario 1: $([[ $overall1 -eq 0 ]] && echo 'PASS ✅' || echo 'FAIL ❌')"
echo "======================================================================"

# ==========================================================================
# Scenario 2 — manual hotkey zoom (LIVE ⌃⌥Z / ⌃⌥X during recording)
# ==========================================================================
# Records with NO --duration (stopped by the live ⌃⌥S hotkey) and --no-render,
# posts REAL ⌃⌥Z / ⌃⌥X keystrokes mid-recording via E2EDemo hotkeys, then renders
# the manual-marker zoom explicitly. Proves the live hotkey-zoom + stop paths.

HK_BUNDLE="recordings/e2e-hotkey.zoooomrec"
HK_OUT="recordings/e2e-hotkey-zoomed.mp4"
HK_SRC="$HK_BUNDLE/recording.mp4"
HK_EVENTS="$HK_BUNDLE/events.jsonl"
HK_SECONDS=10

echo ""
echo "==> [g] start recorder (no --duration, --no-render) → $HK_BUNDLE"
rm -rf "$HK_BUNDLE"
.build/release/zoooomrec record --output "$HK_BUNDLE" --no-render &
HK_REC_PID=$!

echo "==> [h] sleep 1, then post ${HK_SECONDS}s of live hotkeys (foreground)"
sleep 1
.build/release/E2EDemo hotkeys --seconds "$HK_SECONDS"

echo "==> [i] post stop hotkey ⌃⌥S (E2EDemo stoptest)"
.build/release/E2EDemo stoptest

echo "    waiting up to ~4s for recorder (pid $HK_REC_PID) to exit on ⌃⌥S..."
stopped=0
for _ in $(seq 1 40); do
  if ! kill -0 "$HK_REC_PID" 2>/dev/null; then
    stopped=1
    break
  fi
  sleep 0.1
done
if [[ "$stopped" -ne 1 ]]; then
  echo "    ⌃⌥S did not stop the recorder in time — sending SIGINT fallback to $HK_REC_PID"
  kill -INT "$HK_REC_PID" 2>/dev/null || true
fi
wait "$HK_REC_PID" 2>/dev/null || true
recorder_exited=1
kill -0 "$HK_REC_PID" 2>/dev/null && recorder_exited=0

echo "==> [j] render manual-marker zoom → $HK_OUT"
.build/release/zoooomrec render "$HK_BUNDLE" --output "$HK_OUT"

echo "==> [k] scenario 2 assertions"
declare -a HK_NAMES HK_RESULTS HK_DETAILS
hk_result() { HK_NAMES+=("$1"); HK_RESULTS+=("$2"); HK_DETAILS+=("$3"); }

# --- assertion: recorder actually exited (stop path) ----------------------
if [[ "$recorder_exited" -eq 1 ]]; then
  hk_result "recorder exited (⌃⌥S/SIGINT stop)" PASS "stopped_by=$([[ $stopped -eq 1 ]] && echo hotkey || echo sigint-fallback)"
else
  hk_result "recorder exited (⌃⌥S/SIGINT stop)" FAIL "still running"
fi

# --- assertion (i): output exists & h264 ----------------------------------
if [[ -s "$HK_OUT" ]]; then
  hk_result "output exists & non-empty" PASS "$(wc -c < "$HK_OUT" | tr -d ' ') bytes"
else
  hk_result "output exists & non-empty" FAIL "missing or empty"
fi
HK_CODEC="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$HK_OUT" 2>/dev/null || echo "?")"
if [[ "$HK_CODEC" == "h264" ]]; then
  hk_result "codec is h264" PASS "codec_name=$HK_CODEC"
else
  hk_result "codec is h264" FAIL "codec_name=$HK_CODEC"
fi

# --- assertion (ii): events.jsonl captured a live zoom_in -----------------
ZOOM_IN_COUNT="$(grep -c 'zoom_in' "$HK_EVENTS" 2>/dev/null || true)"
ZOOM_IN_COUNT="${ZOOM_IN_COUNT:-0}"
ZOOM_OUT_COUNT="$(grep -c 'zoom_out' "$HK_EVENTS" 2>/dev/null || true)"
ZOOM_OUT_COUNT="${ZOOM_OUT_COUNT:-0}"
if [[ "$ZOOM_IN_COUNT" -ge 1 ]]; then
  hk_result "captured >=1 live zoom_in" PASS "zoom_in=$ZOOM_IN_COUNT zoom_out=$ZOOM_OUT_COUNT"
else
  hk_result "captured >=1 live zoom_in" FAIL "zoom_in=$ZOOM_IN_COUNT zoom_out=$ZOOM_OUT_COUNT"
fi

# --- assertion (iii)/(iv): SSIM proves zoom held then released ------------
# Sample mid-hold exactly between the captured markers (deepest zoom), and the
# release near the very end (view back to full frame after ⌃⌥X).
HK_SRC_DUR="$("$FFPROBE" -v error -show_entries format=duration -of default=nw=1:nk=1 "$HK_SRC" 2>/dev/null || echo 0)"
ZIN_T="$(grep 'zoom_in' "$HK_EVENTS" 2>/dev/null | head -1 | grep -oE '"t":[0-9.]+' | head -1 | cut -d: -f2 || true)"
ZOUT_T="$(grep 'zoom_out' "$HK_EVENTS" 2>/dev/null | head -1 | grep -oE '"t":[0-9.]+' | head -1 | cut -d: -f2 || true)"
if [[ -n "$ZIN_T" && -n "$ZOUT_T" ]]; then
  HK_MID_T="$(awk -v a="$ZIN_T" -v b="$ZOUT_T" 'BEGIN{printf "%.3f", (a+b)/2}')"
else
  HK_MID_T="$(awk -v d="$HK_SRC_DUR" 'BEGIN{printf "%.3f", d*0.55}')"
fi
HK_TAIL_T="$(awk -v d="$HK_SRC_DUR" 'BEGIN{t=d-0.5; if(t<0)t=0; printf "%.3f", t}')"

HK_MID_SSIM="$(ssim_at "$HK_MID_T" "$HK_OUT" "$HK_SRC")"
HK_TAIL_SSIM="$(ssim_at "$HK_TAIL_T" "$HK_OUT" "$HK_SRC")"
HK_MID_SSIM="${HK_MID_SSIM:-1}"
HK_TAIL_SSIM="${HK_TAIL_SSIM:-1}"

if less_than "$HK_MID_SSIM" "$SSIM_ZOOMED_MAX"; then
  hk_result "zoom active mid-hold @ ${HK_MID_T}s (SSIM < $SSIM_ZOOMED_MAX)" PASS "SSIM=$HK_MID_SSIM (zin=${ZIN_T:-?}s zout=${ZOUT_T:-?}s)"
else
  hk_result "zoom active mid-hold @ ${HK_MID_T}s (SSIM < $SSIM_ZOOMED_MAX)" FAIL "SSIM=$HK_MID_SSIM (zin=${ZIN_T:-?}s zout=${ZOUT_T:-?}s)"
fi

# Release proof by RELATIVE recovery, not absolute pixel-identity: after ⌃⌥X the
# view must come back toward full frame, so the tail SSIM must rise well above the
# mid-hold SSIM. Absolute identity (>=0.93) is the wrong test here — the release
# spring is intentionally slow (releaseOmega), and screen content moves between the
# two videos' tail frames, so a fully-released frame still won't be pixel-identical.
HK_RECOVERY="$(awk -v m="$HK_MID_SSIM" -v t="$HK_TAIL_SSIM" 'BEGIN{printf "%.3f", t-m}')"
HK_RELEASE_MIN_GAIN=0.05   # tail must recover at least this much SSIM over mid-hold
HK_RELEASE_MIN_ABS=0.80    # ...and be mostly back to full frame
if less_than "$HK_RELEASE_MIN_GAIN" "$HK_RECOVERY" && ge "$HK_TAIL_SSIM" "$HK_RELEASE_MIN_ABS"; then
  hk_result "zoom released @ ${HK_TAIL_T}s (recovered +${HK_RECOVERY} to $HK_TAIL_SSIM)" PASS "mid=$HK_MID_SSIM tail=$HK_TAIL_SSIM"
else
  hk_result "zoom released @ ${HK_TAIL_T}s (recovered +${HK_RECOVERY} to $HK_TAIL_SSIM)" FAIL "mid=$HK_MID_SSIM tail=$HK_TAIL_SSIM (need +>=$HK_RELEASE_MIN_GAIN & >=$HK_RELEASE_MIN_ABS)"
fi

# --- summary (scenario 2) -------------------------------------------------
echo ""
echo "======================================================================"
echo " zoooomrec E2E demo — scenario 2: live hotkey zoom — assertion summary"
echo "======================================================================"
overall2=0
for i in "${!HK_NAMES[@]}"; do
  printf "  [%s] %-46s %s\n" "${HK_RESULTS[$i]}" "${HK_NAMES[$i]}" "${HK_DETAILS[$i]}"
  [[ "${HK_RESULTS[$i]}" == "PASS" ]] || overall2=1
done
echo "----------------------------------------------------------------------"
echo "  bundle: $REPO_ROOT/$HK_BUNDLE"
echo "  mp4:    $REPO_ROOT/$HK_OUT"
echo "  scenario 2: $([[ $overall2 -eq 0 ]] && echo 'PASS ✅' || echo 'FAIL ❌')"
echo "======================================================================"

# --- overall result (both scenarios) --------------------------------------
echo ""
if [[ "$overall1" -eq 0 && "$overall2" -eq 0 ]]; then
  echo "RESULT: PASS ✅ (scenario 1 + scenario 2)"
  exit 0
else
  echo "RESULT: FAIL ❌ (scenario1=$([[ $overall1 -eq 0 ]] && echo PASS || echo FAIL), scenario2=$([[ $overall2 -eq 0 ]] && echo PASS || echo FAIL))"
  exit 1
fi
