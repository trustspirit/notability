#!/usr/bin/env bash
# Notability installer — downloads latest release and installs to /Applications.
# Automatically removes quarantine so Gatekeeper doesn't block the app.

set -euo pipefail

REPO="trustspirit/notability"
APP_NAME="Notability"
INSTALL_DIR="/Applications"
TMP_DIR=$(mktemp -d)

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "Fetching latest release..."
DOWNLOAD_URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep '"browser_download_url"' \
  | grep 'Notability\.zip' \
  | head -1 \
  | sed -E 's/.*"browser_download_url": "([^"]+)".*/\1/')

if [ -z "$DOWNLOAD_URL" ]; then
  echo "Error: Could not find download URL. Check https://github.com/${REPO}/releases"
  exit 1
fi

echo "Downloading ${APP_NAME}..."
curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/${APP_NAME}.zip"

echo "Unpacking..."
ditto -xk "${TMP_DIR}/${APP_NAME}.zip" "$TMP_DIR"

# Checked against the downloaded bundle rather than a hardcoded version so this
# script cannot fall behind the deployment target. It has to happen before the
# existing install is removed below: otherwise an unsupported machine loses a
# working copy in exchange for one macOS refuses to launch.
REQUIRED_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" \
  "${TMP_DIR}/${APP_NAME}.app/Contents/Info.plist" 2>/dev/null || true)
CURRENT_OS=$(sw_vers -productVersion)
if [ -n "$REQUIRED_OS" ] && \
   [ "$(printf '%s\n%s\n' "$REQUIRED_OS" "$CURRENT_OS" | sort -V | head -1)" != "$REQUIRED_OS" ]; then
  echo ""
  echo "Error: ${APP_NAME} requires macOS ${REQUIRED_OS} or later, but this Mac runs ${CURRENT_OS}."
  echo "Nothing was changed. On-device live captions need the newer Speech framework,"
  echo "so this release cannot run on your version."
  if [ -d "${INSTALL_DIR}/${APP_NAME}.app" ]; then
    echo "Your existing installation was left untouched."
  fi
  exit 1
fi

# Remove quarantine so Gatekeeper allows the app without manual xattr step
echo "Removing quarantine..."
xattr -cr "${TMP_DIR}/${APP_NAME}.app"

# Re-sign deeply so Sparkle's Autoupdate XPC service can run on macOS 12+
echo "Signing app..."
codesign --deep --force --sign - "${TMP_DIR}/${APP_NAME}.app" 2>/dev/null || true

if [ -d "${INSTALL_DIR}/${APP_NAME}.app" ]; then
  echo "Replacing existing installation..."
  rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
fi

echo "Installing to ${INSTALL_DIR}..."
cp -R "${TMP_DIR}/${APP_NAME}.app" "${INSTALL_DIR}/"

echo ""
echo "✓ ${APP_NAME} installed to ${INSTALL_DIR}/${APP_NAME}.app"
echo ""
echo "To capture the other participants, grant Screen Recording and relaunch:"
echo "  System Settings → Privacy & Security → Screen Recording → enable Notability"
echo "Without it Notability still records, but only your microphone."
echo ""
open "${INSTALL_DIR}/${APP_NAME}.app"
