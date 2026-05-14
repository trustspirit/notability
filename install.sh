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
echo "Grant Screen Recording permission on first launch:"
echo "  System Settings → Privacy & Security → Screen Recording → enable Notability"
echo ""
open "${INSTALL_DIR}/${APP_NAME}.app"
