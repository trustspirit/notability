#!/usr/bin/env bash
# One-time setup: generates Sparkle EdDSA key pair.
# Run this ONCE, then:
#   1. Put the public key into Info.plist → SUPublicEDKey
#   2. Put the private key into GitHub → Settings → Secrets → SPARKLE_PRIVATE_KEY

set -euo pipefail

SPARKLE_VER="2.6.4"
TOOLS_DIR="$(dirname "$0")/../.sparkle-tools"

if [ ! -f "${TOOLS_DIR}/bin/generate_keys" ]; then
  echo "Downloading Sparkle ${SPARKLE_VER} tools..."
  mkdir -p "${TOOLS_DIR}"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VER}/Sparkle-${SPARKLE_VER}.tar.xz" \
    | tar xJ -C "${TOOLS_DIR}"
  chmod +x "${TOOLS_DIR}/bin/generate_keys" "${TOOLS_DIR}/bin/sign_update"
fi

echo ""
echo "=== Generating Sparkle EdDSA key pair ==="
echo ""
OUTPUT=$("${TOOLS_DIR}/bin/generate_keys" 2>&1)
echo "$OUTPUT"

PUBLIC_KEY=$(echo "$OUTPUT" | grep "Public key" | awk '{print $NF}')

if [ -n "$PUBLIC_KEY" ]; then
  echo ""
  echo "=== Next steps ==="
  echo ""
  echo "1. Add to MeetingScribe/Info.plist:"
  echo "   <key>SUPublicEDKey</key>"
  echo "   <string>${PUBLIC_KEY}</string>"
  echo ""
  echo "2. Add SPARKLE_PRIVATE_KEY to GitHub Secrets:"
  echo "   https://github.com/trustspirit/notability/settings/secrets/actions"
  echo "   (The private key is shown above — copy it before closing this window)"
  echo ""
fi
