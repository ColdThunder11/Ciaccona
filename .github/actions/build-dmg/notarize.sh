#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "::error::Usage: notarize.sh <artifact-path>"
  exit 1
fi

TARGET_PATH="$1"

if [[ -n "${APPLE_NOTARY_KEY_P8:-}" ]]; then
  KEY_FILE="$RUNNER_TEMP/notary-key.p8"
  trap 'rm -f "$KEY_FILE"' EXIT
  printf '%s' "$APPLE_NOTARY_KEY_P8" | tr -d '[:space:]' | base64 --decode > "$KEY_FILE"

  xcrun notarytool submit "$TARGET_PATH" \
    --key "$KEY_FILE" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait
elif [[ -n "${APPLE_ID:-}" ]]; then
  xcrun notarytool submit "$TARGET_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APPLE_APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
else
  echo "::error::Notarization credentials are missing."
  exit 1
fi
