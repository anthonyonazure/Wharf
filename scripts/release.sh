#!/bin/zsh
# Build, sign, notarize and package Wharf.app for direct download.
#
# This replaces upstream's Sparkle/getdocky.com release script, which publishes
# to a domain this fork does not own. It never uploads anything: it leaves
# build/release/Wharf-<version>.zip and a SHA-256 file for you to attach to a
# GitHub release by hand.
#
# Prerequisites (one time):
#   1. A "Developer ID Application" certificate in the login keychain
#      (Apple Developer Program, developer.apple.com/account/resources/certificates).
#   2. A notarytool credential profile:
#        xcrun notarytool store-credentials wharf-notary \
#          --apple-id <apple id> --team-id <TEAMID> --password <app-specific password>
#
# Usage: scripts/release.sh [version]     (defaults to MARKETING_VERSION in the project)
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

NOTARY_PROFILE="${NOTARY_PROFILE:-wharf-notary}"
TEAM_ID="${TEAM_ID:-4P54C2K45P}"
BUILD_ROOT="$PROJECT_ROOT/build/release"
ARCHIVE_PATH="$BUILD_ROOT/Wharf.xcarchive"
EXPORT_PATH="$BUILD_ROOT/export"
APP_PATH="$EXPORT_PATH/Wharf.app"

die() { print -u2 "release: $*"; exit 1; }

# Refuse to ship anything the tests have not passed.
if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
    print "release: running the unit tests first"
    xcodebuild -project Docky.xcodeproj -scheme Docky -configuration Debug \
        -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
        test > /dev/null || die "tests failed; not releasing"
fi

security find-identity -v -p codesigning | grep -q "Developer ID Application" \
    || die "no 'Developer ID Application' certificate in the keychain. Without it macOS Gatekeeper blocks the download. See the prerequisites at the top of this script."

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" > /dev/null 2>&1 \
    || die "no notarytool credential profile named '$NOTARY_PROFILE'. See the prerequisites at the top of this script."

VERSION="${1:-$(xcodebuild -project Docky.xcodeproj -scheme Docky -showBuildSettings 2>/dev/null \
    | awk '/ MARKETING_VERSION = / {print $3; exit}')}"
[[ -n "$VERSION" ]] || die "could not determine the version"

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT"

print "release: archiving Wharf $VERSION"
xcodebuild -project Docky.xcodeproj -scheme Docky -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$ARCHIVE_PATH" \
    MARKETING_VERSION="$VERSION" archive > /dev/null

cat > "$BUILD_ROOT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

print "release: exporting with Developer ID signing"
xcodebuild -exportArchive -archivePath "$ARCHIVE_PATH" -exportPath "$EXPORT_PATH" \
    -exportOptionsPlist "$BUILD_ROOT/ExportOptions.plist" > /dev/null
[[ -d "$APP_PATH" ]] || die "export did not produce $APP_PATH"

# The widget loader relies on library validation staying on; fail the release if
# the shipped binary ever disables it or carries a debugger entitlement.
ENTITLEMENTS="$(codesign -d --entitlements - "$APP_PATH" 2>&1 || true)"
if print -- "$ENTITLEMENTS" | grep -q "disable-library-validation"; then
    die "shipped app disables library validation"
fi
if print -- "$ENTITLEMENTS" | grep -q "get-task-allow"; then
    die "shipped app carries get-task-allow (debuggable)"
fi

print "release: notarizing (this waits for Apple, usually a few minutes)"
ZIP_FOR_NOTARY="$BUILD_ROOT/notarize.zip"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_FOR_NOTARY"
xcrun notarytool submit "$ZIP_FOR_NOTARY" --keychain-profile "$NOTARY_PROFILE" --wait \
    || die "notarization failed or was rejected"

xcrun stapler staple "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH" || die "Gatekeeper rejects the stapled app"

FINAL_ZIP="$BUILD_ROOT/Wharf-$VERSION.zip"
ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP"
( cd "$BUILD_ROOT" && shasum -a 256 "Wharf-$VERSION.zip" > "Wharf-$VERSION.zip.sha256" )

print "release: done"
print "  $FINAL_ZIP"
print "  $(cat "$BUILD_ROOT/Wharf-$VERSION.zip.sha256")"
print "Attach both files to a GitHub release by hand. Nothing was uploaded."
