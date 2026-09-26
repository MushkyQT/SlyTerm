#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=dist/SlyTerm.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/SlyTerm "$APP/Contents/MacOS/SlyTerm"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/StatusItemIcon.pdf Resources/AppIcon.icns "$APP/Contents/Resources/"
for bundle in .build/release/*.bundle; do
  [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done
# Ad-hoc signing changes the app's identity on every build, which resets the Screen Recording
# grant. A stable CODESIGN_IDENTITY (a self-signed certificate is enough) keeps it.
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/SlyTerm.app
  cp -R "$APP" /Applications/SlyTerm.app
  echo "Installed /Applications/SlyTerm.app"
fi
