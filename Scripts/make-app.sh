#!/usr/bin/env bash
#
# make-app.sh — assemble, sign, and verify the zoooomrec macOS .app bundle (ZR-111).
#
# `swift build` emits a bare Mach-O with NO Info.plist; NSApplication needs a real
# bundle. This script assembles dist/zoooomrec.app around the release binary, gives
# it an icon + Info.plist, code-signs it, and reports what Gatekeeper thinks.
#
# TCC NOTE (read this): macOS keys the Screen-Recording grant on the app's CODE
# SIGNATURE. Ad-hoc signing (`codesign -s -`) keys on the cdhash, which CHANGES on
# every rebuild, so macOS forgets the grant each build. A STABLE identity (Apple
# Development or Developer ID) keeps the same signing identity across rebuilds, so
# the grant persists. Prefer a real identity; ad-hoc is the last resort.
#
# IDENTITY IS NEVER AUTO-PICKED. This machine can hold several 'Apple Development'
# certificates belonging to DIFFERENT companies. Signing as the wrong company is a
# real error, so this script refuses to guess — you choose an identity explicitly.
#
# Identity resolution (strict priority, no guessing):
#   1. --identity <sha-or-name>          (explicit, wins)
#   2. --adhoc                           (explicit ad-hoc escape hatch)
#   3. $ZOOOOMREC_SIGN_IDENTITY          (env var)
#   4. .signing.env in repo root         (ZOOOOMREC_SIGN_IDENTITY=...)
#   none of the above AND no --adhoc  ->  HARD FAIL (exit 1), lists your identities.
#
# Usage:
#   bash Scripts/make-app.sh                                   # uses env / .signing.env
#   bash Scripts/make-app.sh --identity 3EED45A2...            # by SHA-1
#   bash Scripts/make-app.sh --identity "Developer ID Application: You (TEAMID)"
#   bash Scripts/make-app.sh --adhoc                           # ad-hoc (TCC resets each build)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="zoooomrec"
DIST="$REPO_ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
BIN_SRC="$REPO_ROOT/.build/release/$APP_NAME"
INFO_PLIST_SRC="$REPO_ROOT/Resources/Info.plist"
ICON_GEN="$REPO_ROOT/Resources/icon/make-icon.swift"
ICON_PNG_SRC="$REPO_ROOT/Resources/icon/icon_1024.png"
SIGNING_ENV="$REPO_ROOT/.signing.env"

FORCE_ADHOC=0
IDENTITY_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --adhoc) FORCE_ADHOC=1; shift;;
    --identity) IDENTITY_OVERRIDE="${2:?--identity needs a value}"; shift 2;;
    --identity=*) IDENTITY_OVERRIDE="${1#*=}"; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

# ---------------------------------------------------------------------------
# Certificate → Organization helpers (so the human SEES which company they sign
# as — the whole point of the killed-run post-mortem).
# ---------------------------------------------------------------------------
cert_subject_for() {
  # $1 = SHA-1 hash (40 hex) or certificate common-name substring.
  # Prints "subject= /.../O=.../C=US" on success; returns 1 if not found.
  local id="$1" kc pem=""
  if printf '%s' "$id" | grep -qiE '^[0-9a-f]{40}$'; then
    for kc in $(security list-keychains 2>/dev/null | tr -d '"'); do
      pem="$(security find-certificate -a -Z -p "$kc" 2>/dev/null | awk -v h="$id" '
        BEGIN { h = toupper(h) }
        /SHA-1 hash:/ { cur = toupper($NF) }
        /-----BEGIN CERT/ { b = 1; buf = "" }
        b { buf = buf $0 ORS }
        /-----END CERT/ { b = 0; if (cur == h) { printf "%s", buf; exit } }')"
      if [ -n "$pem" ]; then break; fi
    done
  else
    pem="$(security find-certificate -a -c "$id" -p 2>/dev/null | awk '
      /-----BEGIN CERT/ { b = 1; buf = "" }
      b { buf = buf $0 ORS }
      /-----END CERT/ { b = 0; if (!done) { printf "%s", buf; done = 1 } }')"
  fi
  [ -n "$pem" ] || return 1
  printf '%s' "$pem" | openssl x509 -noout -subject 2>/dev/null
}

cert_org_for() {
  # Always prints something and returns 0 (safe under `set -e` in $(...) capture).
  local subj org
  if ! subj="$(cert_subject_for "$1")"; then
    echo "(unknown — certificate not found in keychain)"; return 0
  fi
  # subject looks like:  subject= /UID=.../CN=.../OU=7QZW432V8B/O=ZKidz Dev LLC/C=US
  org="$(printf '%s' "$subj" | sed -n 's#.*/O=\([^/]*\).*#\1#p')"
  if [ -n "$org" ]; then printf '%s' "$org"; else echo "(unknown — no O= field in subject)"; fi
  return 0
}

# ---------------------------------------------------------------------------
# a. Build the release binary (retry on SwiftPM build-lock contention).
#
# SwiftUI (@State etc.) needs the SwiftUI macro plugin, which ships with Xcode
# but NOT with the standalone Command Line Tools. If CLT is the active toolchain,
# `swift build` fails with "external macro implementation ... SwiftUIMacros ...
# not found" (and cascading "self is immutable"). Honor a caller-set
# DEVELOPER_DIR; otherwise, when CLT is active and a full Xcode is installed,
# build with that Xcode for THIS run only (no sudo, no machine-global change).
# ---------------------------------------------------------------------------
if [ -z "${DEVELOPER_DIR:-}" ]; then
  active_dir="$(xcode-select -p 2>/dev/null || true)"
  case "$active_dir" in
    *CommandLineTools*)
      for cand in /Applications/Xcode*.app/Contents/Developer; do
        if [ -x "$cand/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" ]; then
          export DEVELOPER_DIR="$cand"
          echo "==> toolchain: active dir is Command Line Tools (no SwiftUI macro plugin);"
          echo "    building with Xcode toolchain at $DEVELOPER_DIR for this run."
          break
        fi
      done
      ;;
  esac
fi

echo "==> [a] swift build -c release"
build_ok=0
for attempt in 1 2 3; do
  if swift build -c release; then build_ok=1; break; fi
  echo "    build failed (attempt $attempt/3) — retrying (possible build-lock contention)..." >&2
  sleep 3
done
[ "$build_ok" -eq 1 ] || { echo "swift build failed after 3 attempts" >&2; exit 1; }
[ -x "$BIN_SRC" ] || { echo "expected release binary not found at $BIN_SRC" >&2; exit 1; }

# ---------------------------------------------------------------------------
# b. Assemble the bundle skeleton.
# ---------------------------------------------------------------------------
echo "==> [b] assemble $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_SRC" "$CONTENTS/MacOS/$APP_NAME"          # CFBundleExecutable must match this filename
chmod +x "$CONTENTS/MacOS/$APP_NAME"
cp "$INFO_PLIST_SRC" "$CONTENTS/Info.plist"
printf 'APPL????' > "$CONTENTS/PkgInfo"            # classic companion to CFBundlePackageType=APPL

# ---------------------------------------------------------------------------
# c. Generate the .icns (fresh from CoreGraphics; fall back to committed PNG).
# ---------------------------------------------------------------------------
echo "==> [c] build AppIcon.icns"
ICONSET="$DIST/AppIcon.iconset"
BASE_PNG="$DIST/icon_1024.png"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
if swift "$ICON_GEN" "$BASE_PNG"; then
  echo "    icon: generated a fresh 1024px source via CoreGraphics"
elif [ -f "$ICON_PNG_SRC" ]; then
  cp "$ICON_PNG_SRC" "$BASE_PNG"
  echo "    icon: swift generator unavailable — using committed Resources/icon/icon_1024.png"
else
  echo "    icon: no generator output and no committed PNG" >&2; exit 1
fi
for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" "128 128x128" \
            "256 128x128@2x" "256 256x256" "512 256x256@2x" "512 512x512" "1024 512x512@2x"; do
  # shellcheck disable=SC2086
  set -- $pair
  sips -z "$1" "$1" "$BASE_PNG" --out "$ICONSET/icon_$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

# ---------------------------------------------------------------------------
# d. Resolve the signing identity — STRICT, EXPLICIT, NEVER GUESS.
# ---------------------------------------------------------------------------
echo "==> [d] resolve signing identity (never auto-picked)"

if [ "$FORCE_ADHOC" -eq 1 ] && [ -n "$IDENTITY_OVERRIDE" ]; then
  echo "ERROR: pass EITHER --identity OR --adhoc, not both." >&2
  exit 2
fi

IDENTITY=""
IDENTITY_KIND=""
IDENTITY_SOURCE=""

if [ -n "$IDENTITY_OVERRIDE" ]; then
  IDENTITY="$IDENTITY_OVERRIDE"; IDENTITY_KIND="real"; IDENTITY_SOURCE="--identity flag"
elif [ "$FORCE_ADHOC" -eq 1 ]; then
  IDENTITY="-"; IDENTITY_KIND="adhoc"; IDENTITY_SOURCE="--adhoc flag"
elif [ -n "${ZOOOOMREC_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$ZOOOOMREC_SIGN_IDENTITY"; IDENTITY_KIND="real"; IDENTITY_SOURCE="\$ZOOOOMREC_SIGN_IDENTITY env var"
elif [ -f "$SIGNING_ENV" ]; then
  # shellcheck source=/dev/null
  set -a; . "$SIGNING_ENV"; set +a
  if [ -n "${ZOOOOMREC_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$ZOOOOMREC_SIGN_IDENTITY"; IDENTITY_KIND="real"; IDENTITY_SOURCE=".signing.env"
  fi
fi

if [ -z "$IDENTITY" ]; then
  cat >&2 <<'EOF'
==> NO SIGNING IDENTITY RESOLVED — refusing to guess.

This machine may hold multiple 'Apple Development' certificates from DIFFERENT
companies. Signing as the wrong company is a real error, so this script will NOT
pick one for you. Choose ONE explicitly:

  * bash Scripts/make-app.sh --identity <SHA-1-or-name>
  * export ZOOOOMREC_SIGN_IDENTITY=<SHA-1-or-name>  &&  bash Scripts/make-app.sh
  * create .signing.env in the repo root:  ZOOOOMREC_SIGN_IDENTITY=<SHA-1-or-name>
  * bash Scripts/make-app.sh --adhoc      (ad-hoc; TCC grant resets every rebuild)

Available code-signing identities on this machine:
EOF
  security find-identity -v -p codesigning >&2 || true
  echo "" >&2
  echo "Pick the SHA-1 of YOUR identity and pass it via one of the routes above." >&2
  exit 1
fi

if [ "$IDENTITY_KIND" = "adhoc" ]; then
  echo "    Identity : AD-HOC (-)   [source: $IDENTITY_SOURCE]"
  echo "    Org      : (ad-hoc — not tied to any company / certificate)"
  echo ""
  echo "    !! LOUD WARNING — AD-HOC SIGNING"
  echo "    !! Ad-hoc keys the code signature on the cdhash, which CHANGES on EVERY"
  echo "    !! rebuild. macOS ties the Screen-Recording (TCC) grant to the signature,"
  echo "    !! so it will FORGET the grant after each build and re-prompt you."
  echo "    !! Use a STABLE identity (--identity / \$ZOOOOMREC_SIGN_IDENTITY / .signing.env)"
  echo "    !! to make the Screen-Recording grant PERSIST across rebuilds."
else
  ORG="$(cert_org_for "$IDENTITY")"
  echo "    Identity : $IDENTITY   [source: $IDENTITY_SOURCE]"
  echo "    Org      : $ORG   <-- CONFIRM this is YOUR company before shipping"
  echo "    Stable identity -> the Screen-Recording (TCC) grant PERSISTS across rebuilds"
  echo "    (ad-hoc would reset it every build because it keys on the cdhash)."
fi

# ---------------------------------------------------------------------------
# e. Code-sign (hardened runtime; secure timestamp only for a real identity).
# ---------------------------------------------------------------------------
echo "==> [e] codesign (hardened runtime)"
sign_args=(--force --options runtime --sign "$IDENTITY")
if [ "$IDENTITY_KIND" != "adhoc" ]; then
  sign_args+=(--timestamp)                         # ad-hoc cannot use --timestamp
fi
codesign "${sign_args[@]}" "$APP"

# ---------------------------------------------------------------------------
# f. Verify signature + report Gatekeeper verdict (spctl must not fail script).
# ---------------------------------------------------------------------------
echo "==> [f] verify"
echo "-- codesign -dv --verbose=4 --"
codesign -dv --verbose=4 "$APP" 2>&1 || true
echo "-- codesign --verify --deep --strict --"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "-- spctl -a -vv (Gatekeeper assessment) --"
if spctl -a -vv "$APP" 2>&1; then
  echo "    spctl: ACCEPTED"
else
  echo "    spctl: REJECTED — expected for a non-notarized build. Not an error."
  echo "    Notarize with a Developer ID identity (Scripts/notarize.sh) for other Macs."
fi

# ---------------------------------------------------------------------------
# g. Report.
# ---------------------------------------------------------------------------
APP_ABS="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
echo ""
echo "==> Built: $APP_ABS"
if [ "$IDENTITY_KIND" = "adhoc" ]; then
  echo "    Next step: get a stable identity so the Screen-Recording grant persists."
else
  echo "    Next step: bash Scripts/notarize.sh   (needs a Developer ID cert; see that script)"
fi
