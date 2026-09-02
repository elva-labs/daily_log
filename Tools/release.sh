#!/usr/bin/env bash
#
# Build a distributable daily_log.app, zip it, and (with --publish) cut the
# GitHub release. The Homebrew cask is NOT produced here: elva-labs/homebrew-elva
# polls this repo's releases and updates Casks/daily-log.rb itself.
#
# Signing is picked automatically:
#
#   Developer ID  — a "Developer ID Application" identity in the keychain plus
#                   the notarytool credentials (NOTARY_KEY_ID, NOTARY_ISSUER_ID,
#                   NOTARY_KEY_PATH). The app is signed hardened-runtime +
#                   secure-timestamp, submitted to Apple, and the ticket stapled
#                   into the bundle — it then installs with no Gatekeeper prompt,
#                   and the stable signature stops macOS re-asking for
#                   notification permission on every upgrade.
#
#   ad-hoc        — the fallback: signs with `-`, enough to *execute* but not to
#                   pass Gatekeeper, so the cask still needs `--no-quarantine`.
#
# Usage:
#   Tools/release.sh              build + zip into build/release
#   Tools/release.sh --publish    also create the GitHub release and upload assets
#
# Env:
#   SKIP_TESTS=1        skip the test run that otherwise gates the build
#   ALLOW_DIRTY=1       build from a dirty working tree
#   APPLE_TEAM_ID       team for Developer ID signing (default WL4K563SDJ)
#   MACOS_SIGN_IDENTITY codesign identity (default "Developer ID Application")
#   NOTARY_KEY_ID       App Store Connect API key ID           } all three
#   NOTARY_ISSUER_ID    App Store Connect API issuer UUID       } required to
#   NOTARY_KEY_PATH     path to the App Store Connect .p8 key   } notarize

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PROJECT=daily_log.xcodeproj
SCHEME=daily_log
APP=daily_log.app
OUT=build/release
PUBLISH=0

TEAM_ID="${APPLE_TEAM_ID:-WL4K563SDJ}"
SIGN_IDENTITY="${MACOS_SIGN_IDENTITY:-Developer ID Application}"

for arg in "$@"; do
	case "$arg" in
		--publish) PUBLISH=1 ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

if [[ -z "${ALLOW_DIRTY:-}" && -n "$(git status --porcelain)" ]]; then
	echo "working tree is dirty — commit first, or set ALLOW_DIRTY=1" >&2
	exit 1
fi

if [[ -z "${SKIP_TESTS:-}" ]]; then
	echo "==> tests"
	xcodebuild test -project "$PROJECT" -scheme "$SCHEME" \
		-destination 'platform=macOS' -quiet
fi

# Developer ID path only when both halves are in place: an identity to sign with
# and credentials to notarize with. Either one missing drops to ad-hoc so a
# stray local build still produces a runnable app.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application" \
	&& [[ -n "${NOTARY_KEY_ID:-}" && -n "${NOTARY_ISSUER_ID:-}" && -n "${NOTARY_KEY_PATH:-}" ]]; then
	NOTARIZE=1
else
	NOTARIZE=0
fi

echo "==> build (Release, universal, $([[ $NOTARIZE -eq 1 ]] && echo 'Developer ID' || echo 'ad-hoc') signed)"
rm -rf "$OUT"
mkdir -p "$OUT"

if [[ $NOTARIZE -eq 1 ]]; then
	xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
		-destination 'generic/platform=macOS' \
		CONFIGURATION_BUILD_DIR="$PWD/$OUT" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
		DEVELOPMENT_TEAM="$TEAM_ID" \
		OTHER_CODE_SIGN_FLAGS="--timestamp" \
		-quiet
else
	xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
		-destination 'generic/platform=macOS' \
		CONFIGURATION_BUILD_DIR="$PWD/$OUT" \
		ONLY_ACTIVE_ARCH=NO \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_IDENTITY=- \
		DEVELOPMENT_TEAM="" \
		-quiet
fi

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
	"$OUT/$APP/Contents/Info.plist")
TAG="v$VERSION"
ZIP="$OUT/daily_log-$VERSION.zip"

lipo -archs "$OUT/$APP/Contents/MacOS/daily_log"

if [[ $NOTARIZE -eq 1 ]]; then
	# Re-sign the finished bundle in one explicit pass: hardened runtime and a
	# secure timestamp are what notarization checks for, and keeping the flags
	# here rather than trusting the xcodebuild pass makes the contract obvious.
	echo "==> sign (Developer ID, hardened runtime)"
	codesign --force --options runtime --timestamp \
		--sign "$SIGN_IDENTITY" "$OUT/$APP"
	codesign --verify --strict --deep --verbose=2 "$OUT/$APP"

	echo "==> notarize (this waits on Apple — usually a minute or two)"
	NOTARIZE_ZIP="$OUT/notarize.zip"
	ditto -c -k --keepParent "$OUT/$APP" "$NOTARIZE_ZIP"
	xcrun notarytool submit "$NOTARIZE_ZIP" \
		--key "$NOTARY_KEY_PATH" \
		--key-id "$NOTARY_KEY_ID" \
		--issuer "$NOTARY_ISSUER_ID" \
		--wait
	rm -f "$NOTARIZE_ZIP"

	echo "==> staple"
	xcrun stapler staple "$OUT/$APP"
	# The real Gatekeeper check the user's machine will run on first launch.
	spctl -a -vvv "$OUT/$APP"
else
	# Cheap sanity check only: the bundle is signed and the signature is
	# self-consistent. This will not pass `spctl -a` and is not meant to.
	codesign --verify --strict "$OUT/$APP"
fi

echo "==> package"
ditto -c -k --keepParent "$OUT/$APP" "$ZIP"
SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
printf '%s  %s\n' "$SHA" "$(basename "$ZIP")" > "$ZIP.sha256"

echo
echo "    app     $OUT/$APP"
echo "    zip     $ZIP"
echo "    sha256  $SHA"
echo "    signed  $([[ $NOTARIZE -eq 1 ]] && echo 'Developer ID + notarized + stapled' || echo 'ad-hoc')"
echo

if [[ $PUBLISH -eq 1 ]]; then
	echo "==> publish $TAG"
	# --target pins the tag to the commit that was actually built. Without it
	# `gh` tags the default branch, which is only right by coincidence.
	gh release create "$TAG" "$ZIP" "$ZIP.sha256" \
		--title "$TAG" --generate-notes \
		--target "$(git rev-parse HEAD)"
	echo
	echo "elva-labs/homebrew-elva will pick this up within the hour, or run its"
	echo "'Update daily-log cask' workflow by hand to pull it immediately."
else
	cat <<-EOF
	Nothing was published. To ship this build:

	    Tools/release.sh --publish
	EOF
fi
