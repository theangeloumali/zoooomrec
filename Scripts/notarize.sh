#!/usr/bin/env bash
#
# notarize.sh — notarize + staple the zoooomrec.app produced by Scripts/make-app.sh (ZR-111).
#
# Notarization REQUIRES a "Developer ID Application" identity (Apple Development
# certs are rejected by the notary service) AND a stored notarytool keychain
# profile holding your Apple ID + team-id + app-specific password. If either is
# missing this script prints the exact fix and exits 2 — it never fails silently.
#
# Usage:
#   bash Scripts/notarize.sh                        # default profile "zoooomrec-notary"
#   bash Scripts/notarize.sh --profile my-profile
#   bash Scripts/notarize.sh --identity "Developer ID Application: You (TEAMID)"
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="zoooomrec"
DIST="$REPO_ROOT/dist"
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME.zip"
PROFILE="zoooomrec-notary"
IDENTITY_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="${2:?--profile needs a value}"; shift 2;;
    --profile=*) PROFILE="${1#*=}"; shift;;
    --identity) IDENTITY_OVERRIDE="${2:?--identity needs a value}"; shift 2;;
    --identity=*) IDENTITY_OVERRIDE="${1#*=}"; shift;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 2;;
  esac
done

[ -d "$APP" ] || { echo "no app bundle at $APP — run Scripts/make-app.sh first" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Require a Developer ID Application identity — never auto-pick among several.
# ---------------------------------------------------------------------------
if [ -n "$IDENTITY_OVERRIDE" ]; then
  DEVID="$IDENTITY_OVERRIDE"
else
  DEVID_HASHES="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Developer ID Application/ {print $2}')"
  DEVID_COUNT="$(printf '%s\n' "$DEVID_HASHES" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [ "$DEVID_COUNT" -gt 1 ]; then
    echo "Multiple 'Developer ID Application' identities found — refusing to auto-pick" >&2
    echo "(same rule as make-app.sh: signing as the wrong company is a real error)." >&2
    echo "Pass one explicitly:  bash Scripts/notarize.sh --identity <SHA-1-or-name>" >&2
    security find-identity -v -p codesigning | grep 'Developer ID Application' >&2 || true
    exit 2
  fi
  DEVID="$(printf '%s\n' "$DEVID_HASHES" | sed '/^$/d' | head -n1)"
fi

if [ -z "$DEVID" ]; then
  cat >&2 <<EOF
No "Developer ID Application" identity found in your keychain.
Notarization REQUIRES one — 'Apple Development' certs (like the one in
.signing.env) are REJECTED by Apple's notary service.

Fix it under the zoooomrec maintainer's team — ZKidz Dev LLC, Team ID 7QZW432V8B
(needs a paid Apple Developer Program membership on that team):
  1. Create a "Developer ID Application" certificate under team 7QZW432V8B:
       https://developer.apple.com/account/resources/certificates/add
  2. Download the .cer and double-click to install it into your login keychain.
  3. Make an app-specific password at https://appleid.apple.com
       (Sign-In & Security -> App-Specific Passwords).
  4. Store notarytool credentials once, into the keychain profile "$PROFILE":
       xcrun notarytool store-credentials "$PROFILE" \\
         --apple-id "<your-apple-id-email>" \\
         --team-id "7QZW432V8B" \\
         --password "<app-specific-password>"
  5. Re-run: bash Scripts/notarize.sh --profile "$PROFILE"
EOF
  exit 2
fi

echo "==> Using Developer ID identity: $DEVID"

# ---------------------------------------------------------------------------
# Re-sign with hardened runtime + secure timestamp, then verify.
# ---------------------------------------------------------------------------
echo "==> re-sign (hardened runtime + timestamp)"
codesign --force --options runtime --timestamp --sign "$DEVID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ---------------------------------------------------------------------------
# Zip (preserving the bundle) and submit to the notary service.
# ---------------------------------------------------------------------------
echo "==> ditto -> $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> notarytool submit --wait (can take a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# ---------------------------------------------------------------------------
# Staple the ticket and confirm Gatekeeper accepts the app offline.
# ---------------------------------------------------------------------------
echo "==> stapler staple"
xcrun stapler staple "$APP"

echo "==> spctl assessment (must say accepted)"
spctl -a -vv -t exec "$APP"

echo ""
echo "==> Notarized + stapled: $APP"
