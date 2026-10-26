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
# A new team's first submissions can take hours; later ones usually minutes.
wait_limit="${USAGE_ISLAND_NOTARY_TIMEOUT:-3h}"
submit_status=0
xcrun notarytool submit "$submission_zip" "${credentials[@]}" --wait --timeout "$wait_limit" \
    --output-format json > "$result_path" || submit_status=$?
result_field() {
    python3 -c 'import json, sys
try:
    print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "-")
except Exception:
    print("-")' "$result_path" "$1"
}
submission_id="$(result_field id)"
submission_status="$(result_field status)"
if [[ "$submit_status" != 0 || "$submission_status" != "Accepted" ]]; then
    cat "$result_path" >&2 || true
    # Apple's reasons, once it has finished processing the submission.
    if [[ "$submission_id" != "-" ]]; then
        xcrun notarytool log "$submission_id" "${credentials[@]}" >&2 || true
    fi
    printf 'Notarization of submission %s was not accepted (status: %s).\n' "$submission_id" "$submission_status" >&2
    exit 1
fi
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose "$app_path"
ditto -c -k --keepParent "$app_path" "$PWD/dist/Usage-Island.zip"
printf '\nNotarized archive: %s/dist/Usage-Island.zip\n' "$PWD"
