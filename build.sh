#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

release=false install=false
for arg in "$@"; do
  case $arg in
    --release) release=true ;;
    --install) install=true ;;
    *) echo "usage: ./build.sh [--release] [--install]" >&2; exit 1 ;;
  esac
done

if $release; then
  # A release runs on Intel Macs too. Each architecture gets its own triple: after a build for
  # one, .build/release points at it. Sparkle.framework and the resources are the same in both.
  for arch in arm64 x86_64; do swift build -c release --triple $arch-apple-macosx14.0; done
  products=.build/arm64-apple-macosx/release
else
  swift build -c release
  products=.build/release
fi
APP=dist/SlyTerm.app
SPARKLE=$APP/Contents/Frameworks/Sparkle.framework
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
if $release; then
  lipo -create .build/{arm64,x86_64}-apple-macosx/release/SlyTerm -output "$APP/Contents/MacOS/SlyTerm"
else
  cp $products/SlyTerm "$APP/Contents/MacOS/SlyTerm"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/StatusItemIcon.pdf Resources/AppIcon.icns "$APP/Contents/Resources/"
for bundle in $products/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
ditto $products/Sparkle.framework "$SPARKLE"
# Sparkle's XPC services are only for sandboxed apps.
rm -rf "$SPARKLE/XPCServices" "$SPARKLE/Versions/B/XPCServices"

if $release; then
  # Only this build updates itself: source and debug builds have no feed.
  feed=${SLYTERM_FEED_URL:-https://github.com/MushkyQT/SlyTerm/releases/latest/download/appcast.xml}
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed" "$APP/Contents/Info.plist"
  identity=${CODESIGN_IDENTITY:-"Developer ID Application: Charles Melki (J5958G39Q2)"}
  runtime=(--options runtime --timestamp)
else
  # Ad-hoc signing changes the app's identity on every build, which resets the Screen Recording
  # grant. A stable CODESIGN_IDENTITY (a self-signed certificate is enough) keeps it.
  identity=${CODESIGN_IDENTITY:--}
  runtime=()
fi
sign() { codesign --force --sign "$identity" "${runtime[@]}" "$@" >/dev/null; }
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
sign --entitlements Resources/SlyTerm.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"

if $release; then
  if [[ -n "${NOTARY_KEY_FILE:-}" ]]; then
    notary=(--key "$NOTARY_KEY_FILE" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
  else
    notary=(--keychain-profile "${NOTARY_PROFILE:-SlyTerm}")
  fi
  notarize() {
    local result id state
    result=$(xcrun notarytool submit "$1" "${notary[@]}" --wait --output-format json) || true
    id=$(plutil -extract id raw -o - - <<<"$result" 2>/dev/null) || id=
    state=$(plutil -extract status raw -o - - <<<"$result" 2>/dev/null) || state=
    if [[ "$state" != Accepted ]]; then
      echo "Notarization of $1 failed: ${state:-no status}" >&2
      if [[ -n "$id" ]]; then
        xcrun notarytool log "$id" "${notary[@]}" >&2
      else
        echo "$result" >&2
      fi
      exit 1
    fi
    echo "Notarized $1"
  }
  # A new ticket can take a moment to reach the servers stapler asks, and hdiutil on CI runners
  # now and then fails with "Resource busy".
  retry() {
    for try in 1 2 3; do
      "$@" && return
      (( try < 3 )) && sleep 15
    done
    exit 1
  }

  if [[ "${NOTARIZE:-1}" != 0 ]]; then
    zip=dist/SlyTerm.zip
    ditto -c -k --keepParent "$APP" "$zip"
    notarize "$zip"
    rm "$zip"
    retry xcrun stapler staple -q "$APP"
  fi

  version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
  DMG=dist/SlyTerm-$version.dmg
  stage=dist/dmg
  rm -rf "$stage" "$DMG"
  mkdir "$stage"
  ditto "$APP" "$stage/SlyTerm.app"
  ln -s /Applications "$stage/Applications"
  retry hdiutil create -quiet -ov -volname SlyTerm -srcfolder "$stage" -format UDZO "$DMG"
  rm -rf "$stage"
  codesign --force --sign "$identity" --timestamp "$DMG"

  if [[ "${NOTARIZE:-1}" != 0 ]]; then
    notarize "$DMG"
    retry xcrun stapler staple -q "$DMG"
    echo "Built $DMG"
  else
    echo "Built $DMG, not notarized (NOTARIZE=0)"
  fi
fi

if $install; then
  rm -rf /Applications/SlyTerm.app
  ditto "$APP" /Applications/SlyTerm.app
  echo "Installed /Applications/SlyTerm.app"
fi
