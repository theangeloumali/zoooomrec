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

# ssim_at <timestamp> — extract one frame from OUT and SRC at the same timestamp
# and print the ffmpeg SSIM "All" value for the pair.
ssim_at() {
  local t="$1"
  "$FFMPEG" -nostdin -y -ss "$t" -i "$OUT" -frames:v 1 "$WORK/out.png" >/dev/null 2>&1
  "$FFMPEG" -nostdin -y -ss "$t" -i "$SRC" -frames:v 1 "$WORK/src.png" >/dev/null 2>&1
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

# --- summary --------------------------------------------------------------
echo ""
echo "======================================================================"
echo " zoooomrec E2E demo — assertion summary"
echo "======================================================================"
overall=0
for i in "${!NAMES[@]}"; do
  printf "  [%s] %-46s %s\n" "${RESULTS[$i]}" "${NAMES[$i]}" "${DETAILS[$i]}"
  [[ "${RESULTS[$i]}" == "PASS" ]] || overall=1
done
echo "----------------------------------------------------------------------"
echo "  bundle: $REPO_ROOT/$BUNDLE"
echo "  mp4:    $REPO_ROOT/$OUT"
echo "======================================================================"

if [[ "$overall" -eq 0 ]]; then
  echo "RESULT: PASS ✅"
  exit 0
else
  echo "RESULT: FAIL ❌"
  exit 1
fi
