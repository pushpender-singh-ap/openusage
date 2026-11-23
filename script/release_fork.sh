#!/usr/bin/env bash
set -euo pipefail

# One-command local release for this fork, published by hand (not by GitHub Actions):
#   1. script/release.sh builds the universal app, signs it with Developer ID, notarizes + staples it,
#      and writes dist/OpenUsage-<version>.dmg.
#   2. Sparkle's generate_appcast writes dist/appcast.xml: the currently published feed plus a signed
#      entry for the new DMG.
# Then create a GitHub release tagged v<version> on the fork, attach BOTH files, and publish it as the
# Latest release. Installed copies check <repo>/releases/latest/download/appcast.xml for updates.
#
# Usage:
#   OPENUSAGE_VERSION=1.0.0 ICLOUD_PROVISIONING_PROFILE=/path/to/profile.provisionprofile ./script/release_fork.sh
# Optional env (defaults in parentheses):
#   NOTARY_KEYCHAIN_PROFILE   notarytool keychain profile (dnsblocker-notary)
#   CODESIGN_IDENTITY         Developer ID Application identity (the first valid one for team Y425B96UBL)
#   SPARKLE_PRIVATE_KEY_FILE  Sparkle private key file (default: the key generate_keys saved in your keychain)
#   OPENUSAGE_BUILD           build number (default: git commit count; must grow with every release)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

: "${OPENUSAGE_VERSION:?set OPENUSAGE_VERSION, e.g. 1.0.0 (the release tag is v<version>)}"
: "${ICLOUD_PROVISIONING_PROFILE:?set ICLOUD_PROVISIONING_PROFILE to the Developer ID provisioning profile path}"

REPO="pushpender-singh-ap/openusage"
TEAM_ID="Y425B96UBL"
TAG="v$OPENUSAGE_VERSION"
DMG="OpenUsage-$OPENUSAGE_VERSION.dmg"
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"
BUILD="${OPENUSAGE_BUILD:-$(git rev-list --count HEAD)}"

export NOTARY_KEYCHAIN_PROFILE="${NOTARY_KEYCHAIN_PROFILE:-dnsblocker-notary}"
# Public half of the update-signing key (safe to commit). Every release must carry this same key, or
# installed copies refuse the update. The private half stays in the keychain and a password manager.
export SPARKLE_PUBLIC_KEY="9tCnmdmJRdM7IthxUkUd8rDTI9uA9bw0CMR7krxvIvk="
# The Developer ID certificate is installed in two keychains, so sign by hash (a name match is ambiguous).
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | awk -v team="($TEAM_ID)" '/Developer ID Application:/ && index($0, team) { print $2; exit }')"
fi
[ -n "$CODESIGN_IDENTITY" ] || { echo "No Developer ID Application identity for team $TEAM_ID found." >&2; exit 1; }
export CODESIGN_IDENTITY ICLOUD_PROVISIONING_PROFILE OPENUSAGE_VERSION FEED_URL
export OPENUSAGE_BUILD="$BUILD"

if [ -n "$(git status --porcelain)" ]; then
  echo "NOTE: building with uncommitted changes; commit them so the release tag matches this build." >&2
fi

FEED_DIR="$(mktemp -d)"
trap 'rm -rf "$FEED_DIR"' EXIT

# Load the published feed first: it keeps earlier versions listed, and it tells us whether this build is
# newer. A 404 means nothing is published yet (fresh feed); any other failure aborts so a network blip
# can't wipe the feed's history.
status="$(curl -sSL -o "$FEED_DIR/appcast.xml" -w '%{http_code}' "$FEED_URL" || true)"
case "$status" in
  200) echo "==> loaded the published appcast" ;;
  404) rm -f "$FEED_DIR/appcast.xml"; echo "==> no published appcast yet — starting a fresh feed" ;;
  *)   echo "Could not download $FEED_URL (HTTP $status) — aborting to protect the feed." >&2; exit 1 ;;
esac
before=0
if [ -f "$FEED_DIR/appcast.xml" ]; then
  before="$(grep -c '<item>' "$FEED_DIR/appcast.xml" || true)"
  # Sparkle offers an update only when its build number is higher than the installed one.
  published="$(grep -Eo 'sparkle:version(>|=")[0-9]+' "$FEED_DIR/appcast.xml" | grep -Eo '[0-9]+$' | sort -n | tail -n1 || true)"
  if [ -n "$published" ] && [ "$BUILD" -le "$published" ]; then
    echo "Build number $BUILD is not higher than the published $published, so no one would be offered this" >&2
    echo "update. Commit your changes first (the build number is the git commit count)." >&2
    exit 1
  fi
fi

"$ROOT_DIR/script/release.sh"

echo "==> generating appcast for $TAG"
GENERATE_APPCAST="$(find "$ROOT_DIR/.build/artifacts" -type f -name generate_appcast 2>/dev/null | head -n1)"
[ -x "$GENERATE_APPCAST" ] || { echo "generate_appcast not found under .build/artifacts" >&2; exit 1; }
cp "dist/$DMG" "$FEED_DIR/$DMG"
appcast_args=(--download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" --maximum-versions 0)
if [ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]; then
  # Fed on stdin so the key never appears in the process list.
  "$GENERATE_APPCAST" --ed-key-file - "${appcast_args[@]}" "$FEED_DIR" < "$SPARKLE_PRIVATE_KEY_FILE"
else
  "$GENERATE_APPCAST" "${appcast_args[@]}" "$FEED_DIR"
fi

# The new entry must exist AND carry an EdDSA signature: generate_appcast silently leaves it unsigned
# when the app's SUPublicEDKey doesn't match the signing key.
grep -Eq "$DMG\"[^>]*sparkle:edSignature" "$FEED_DIR/appcast.xml" \
  || { echo "The appcast entry for $DMG is missing or unsigned (public/private key mismatch?)." >&2; exit 1; }
after="$(grep -c '<item>' "$FEED_DIR/appcast.xml" || true)"
[ "$after" -ge "$before" ] || { echo "Appcast item count dropped ($before -> $after) — aborting." >&2; exit 1; }
cp "$FEED_DIR/appcast.xml" "dist/appcast.xml"

cat <<EOF
==> ready to publish $TAG (build $BUILD)
    Create a release at https://github.com/$REPO/releases/new
      tag:    $TAG   (exactly this, or the update download link breaks)
      files:  dist/$DMG
              dist/appcast.xml
    Publish it as the Latest release. Installed copies find it within about an hour.
EOF
