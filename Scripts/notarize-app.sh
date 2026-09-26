#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Authenticate with a stored notarytool keychain profile (local use), or with
# an App Store Connect API key from the environment (CI):
#   USAGE_ISLAND_NOTARY_KEY_PATH, USAGE_ISLAND_NOTARY_KEY_ID, USAGE_ISLAND_NOTARY_ISSUER
if [[ $# == 1 && -n "$1" ]]; then
    credentials=(--keychain-profile "$1")
elif [[ $# == 0 && -n "${USAGE_ISLAND_NOTARY_KEY_PATH:-}" && -n "${USAGE_ISLAND_NOTARY_KEY_ID:-}" && -n "${USAGE_ISLAND_NOTARY_ISSUER:-}" ]]; then
    credentials=(--key "$USAGE_ISLAND_NOTARY_KEY_PATH" --key-id "$USAGE_ISLAND_NOTARY_KEY_ID" --issuer "$USAGE_ISLAND_NOTARY_ISSUER")
else
    printf 'Usage: %s <existing-notarytool-keychain-profile>\n' "$0" >&2
    printf '   or: set USAGE_ISLAND_NOTARY_KEY_PATH, USAGE_ISLAND_NOTARY_KEY_ID and USAGE_ISLAND_NOTARY_ISSUER\n' >&2
    exit 1
fi
app_path="$PWD/dist/Usage Island.app"
codesign --verify --strict "$app_path"
signature_details="$(codesign --display --verbose=4 "$app_path" 2>&1)"
if [[ "$signature_details" != *"Authority=Developer ID Application:"* || "$signature_details" != *"runtime"* ]]; then
    printf 'Build with USAGE_ISLAND_SIGNING_IDENTITY set to a Developer ID Application identity first.\n' >&2
    exit 1
fi
submission_zip="$PWD/dist/Usage-Island-submission.zip"
result_path="$PWD/dist/notarization-result.json"
ditto -c -k --keepParent "$app_path" "$submission_zip"
xcrun notarytool submit "$submission_zip" "${credentials[@]}" --wait --timeout 30m --output-format json > "$result_path"
python3 - "$result_path" <<'PY'
import json, sys
with open(sys.argv[1]) as result_file:
    result = json.load(result_file)
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted. Inspect dist/notarization-result.json before distributing.')
PY
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose "$app_path"
ditto -c -k --keepParent "$app_path" "$PWD/dist/Usage-Island.zip"
printf '\nNotarized archive: %s/dist/Usage-Island.zip\n' "$PWD"
