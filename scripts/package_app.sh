#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

swift build -c release --arch arm64

BUNDLE_PATH="dist/PulseDeck AI.app"
CONTENTS_DIR="${BUNDLE_PATH}/Contents"

rm -rf "${BUNDLE_PATH}"
mkdir -p "${CONTENTS_DIR}/MacOS" "${CONTENTS_DIR}/Resources"

cp ".build/release/PulseDeckAI" "${CONTENTS_DIR}/MacOS/PulseDeckAI"
chmod +x "${CONTENTS_DIR}/MacOS/PulseDeckAI"

# SwiftPM's Bundle.module looks in Bundle.main.resourceURL (Contents/Resources). Test bundles stay out.
for bundle in .build/release/*.bundle; do
    case "$bundle" in *Tests.bundle) continue ;; esac
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "${CONTENTS_DIR}/Resources/"
    fi
done

VERSION="$(git describe --tags --always)"

cat <<EOF > "${CONTENTS_DIR}/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>PulseDeckAI</string>
    <key>CFBundleIdentifier</key>
    <string>com.pulsedeckai.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PulseDeck AI</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

codesign --force --deep --sign - "${BUNDLE_PATH}"
codesign --verify --deep --strict "${BUNDLE_PATH}"

# Disk image: the app plus an Applications shortcut, so installing is one drag.
DMG_PATH="dist/PulseDeckAI-${VERSION}.dmg"
STAGING="$(mktemp -d)"
cp -R "${BUNDLE_PATH}" "${STAGING}/"
ln -s /Applications "${STAGING}/Applications"
rm -f "${DMG_PATH}"
hdiutil create -volname "PulseDeck AI" -srcfolder "${STAGING}" -ov -format UDZO "${DMG_PATH}" >/dev/null
rm -rf "${STAGING}"

echo "${BUNDLE_PATH}"
echo "${DMG_PATH}"
