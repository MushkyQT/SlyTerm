#!/bin/zsh
set -euo pipefail

usage() {
  echo "usage: Tools/make-appcast.sh <dmg> <notes.html> <appcast.xml> [--ed-key-file <file>]" >&2
  exit 1
}
(( $# == 3 || $# == 5 )) || usage
dmg=$1 notes=$2 appcast=$3
if (( $# == 5 )); then
  [[ $4 == --ed-key-file ]] || usage
  key=(--ed-key-file "$5")
else
  key=(--account SlyTerm)
fi
root=${0:A:h:h}
sign_update=$root/.build/artifacts/sparkle/Sparkle/bin/sign_update
[[ -x $sign_update ]] || { echo "$sign_update is missing: run swift build first" >&2; exit 1; }

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$root/Resources/Info.plist"; }
version=$(plist CFBundleShortVersionString)
build=$(plist CFBundleVersion)
minimum=$(plist LSMinimumSystemVersion)
if [[ ${dmg:t} != SlyTerm-$version.dmg ]]; then
  echo "${dmg:t} is not SlyTerm-$version.dmg, the version in Resources/Info.plist" >&2
  exit 1
fi
releases=https://github.com/MushkyQT/SlyTerm/releases/download
url=${SLYTERM_DOWNLOAD_URL:-$releases/v$version/SlyTerm-$version.dmg}
signature=$("$sign_update" "${key[@]}" -p "$dmg")
length=$(stat -f %z "$dmg")
date=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
html=$(<"$notes")
html=${html//]]>/]]]]><![CDATA[>}

cat > "$appcast" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>SlyTerm</title>
        <link>https://github.com/MushkyQT/SlyTerm</link>
        <description>SlyTerm releases</description>
        <language>en</language>
        <item>
            <title>SlyTerm $version</title>
            <pubDate>$date</pubDate>
            <sparkle:version>$build</sparkle:version>
            <sparkle:shortVersionString>$version</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
            <description><![CDATA[
$html
]]></description>
            <enclosure url="${url//&/&amp;}" length="$length" type="application/octet-stream"
                sparkle:edSignature="$signature"/>
        </item>
    </channel>
</rss>
EOF

# SURequireSignedFeed: sign_update embeds the feed's own signature in a comment at its end.
"$sign_update" "${key[@]}" "$appcast"
"$sign_update" "${key[@]}" --verify "$dmg" "$signature"
"$sign_update" "${key[@]}" --verify "$appcast"
# sign_update checks against the key it was given. Signed with any other than the one the app
# trusts, the update would be refused by every copy out there.
swift - "$dmg" "$signature" "$(plist SUPublicEDKey)" <<'SWIFT'
import CryptoKit
import Foundation
let args = CommandLine.arguments
guard args.count == 4, let data = FileManager.default.contents(atPath: args[1]),
      let signature = Data(base64Encoded: args[2]), let raw = Data(base64Encoded: args[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw),
      key.isValidSignature(signature, for: data) else {
    FileHandle.standardError.write(Data("The update key does not match SUPublicEDKey\n".utf8))
    exit(1)
}
SWIFT
echo "Wrote $appcast"
