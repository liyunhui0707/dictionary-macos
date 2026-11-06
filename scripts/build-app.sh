#!/usr/bin/env bash
set -euo pipefail

# Builds Dictionary.app as a proper macOS bundle and drops it in build/.
# Ad-hoc signing does not guarantee Accessibility trust across rebuilds.
# Use --qa for a unique bundle, frozen source and verified build manifest.

cd "$(dirname "$0")/.."

if [[ "${1:-}" == "--qa" ]]; then
    exec node scripts/qa-app.mjs build "${@:2}"
fi

if [[ "${1:-}" == "--testing" ]]; then
    exec node scripts/qa-app.mjs build-testing "${@:2}"
fi

APP_NAME="Dictionary"
EXEC_NAME="DictionaryApp"
BUNDLE_ID="com.liyunhui.${EXEC_NAME}"
VERSION="0.1.0"
OUT_DIR="build"

if [[ -e "${OUT_DIR}/${APP_NAME}.app" || -L "${OUT_DIR}/${APP_NAME}.app" ]]; then
    echo "Existing bundle preserved. Use: bash scripts/build-app.sh --qa"
    exit 1
fi

echo "→ Building release binary…"
xcrun swift build -c release

EXEC_PATH="$(xcrun swift build -c release --show-bin-path)/${EXEC_NAME}"
if [ ! -x "${EXEC_PATH}" ]; then
    echo "Build did not produce ${EXEC_PATH}"
    exit 1
fi

APP="${OUT_DIR}/${APP_NAME}.app"
# The early guard is only a convenience. Acquire this exact path exclusively
# after compilation, before any writes, including when another build raced us.
mkdir -p "${OUT_DIR}"
if ! mkdir "${APP}"; then
    echo "Bundle path could not be acquired; existing output preserved. Use --qa." >&2
    exit 1
fi
trap 'echo "Packaging failed; incomplete bundle retained at ${APP}. Do not launch it." >&2' ERR
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"

cp "${EXEC_PATH}" "${APP}/Contents/MacOS/${EXEC_NAME}"
RESOURCE_BUNDLE="$(dirname "${EXEC_PATH}")/DictionaryApp_DictionaryApp.bundle"
if [[ -L "${RESOURCE_BUNDLE}" ]] || [[ ! -f "${RESOURCE_BUNDLE}/Contents/Resources/EnglishDictionary/oewn-2025.json.gz" && ! -f "${RESOURCE_BUNDLE}/EnglishDictionary/oewn-2025.json.gz" ]]; then
    echo "Missing or unsafe dictionary resource bundle." >&2
    exit 1
fi
cp -R "${RESOURCE_BUNDLE}" "${APP}/Contents/Resources/"
ICON_PATH="${RESOURCE_BUNDLE}/Contents/Resources/AppIcon.icns"
if [[ ! -f "${ICON_PATH}" ]]; then ICON_PATH="${RESOURCE_BUNDLE}/AppIcon.icns"; fi
if [[ ! -f "${ICON_PATH}" || -L "${ICON_PATH}" ]]; then
    echo "Missing or unsafe app icon resource." >&2
    exit 1
fi
cp "${ICON_PATH}" "${APP}/Contents/Resources/AppIcon.icns"

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${EXEC_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Dictionary uses Apple Events to read the selected text and its surrounding paragraph from Safari, so it can translate the word in context.</string>
</dict>
</plist>
PLIST

echo "→ Ad-hoc signing…"
codesign --force --deep --sign - "${APP}" 2>/dev/null
codesign --verify --strict "${APP}"
trap - ERR

echo ""
echo "Built: ${APP}"
echo ""
echo "Installation is a separate manual operation. This script does not replace installed apps."
echo ""
echo "For each new build:"
echo "  - Verify Accessibility trust for the exact running build."
echo "  - Add to Login Items: System Settings → General → Login Items → '+' → ${APP_NAME}."
