#!/bin/zsh
set -e
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/Dictation.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"

FLAGS=(-O -swift-version 5 -module-cache-path "$TMP/mc")
# Command Line Tools 16 ships SwiftBridging twice; hide the duplicate.
DUP=/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap
if [[ -f $DUP && -f ${DUP:h}/bridging.modulemap ]]; then
  : > "$TMP/empty.modulemap"
  print "{\"version\":0,\"roots\":[{\"name\":\"$DUP\",\"type\":\"file\",\"external-contents\":\"$TMP/empty.modulemap\"}]}" > "$TMP/vfs.yaml"
  FLAGS+=(-vfsoverlay "$TMP/vfs.yaml" -Xcc -ivfsoverlay -Xcc "$TMP/vfs.yaml")
fi

swiftc $FLAGS Sources/*.swift -o "$APP/Contents/MacOS/Dictation"
codesign --force --sign - "$APP"

pkill -x Dictation 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Dictation.app
cp -R "$APP" ~/Applications/
open ~/Applications/Dictation.app
echo "Installed ~/Applications/Dictation.app"
