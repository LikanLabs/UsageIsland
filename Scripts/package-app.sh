#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${USAGE_ISLAND_SIGNING_IDENTITY:-}" && "$USAGE_ISLAND_SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    printf 'Use a Developer ID Application signing identity for public distribution.\n' >&2
    exit 1
fi

version="${USAGE_ISLAND_VERSION:-0.1.0}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf 'USAGE_ISLAND_VERSION must be a numeric major.minor.patch version.\n' >&2
    exit 1
fi
arch_csv="${USAGE_ISLAND_ARCHS:-$(uname -m)}"
IFS=',' read -r -a architectures <<< "$arch_csv"
if [[ "${#architectures[@]}" -eq 0 ]]; then
    printf 'USAGE_ISLAND_ARCHS must contain at least one architecture.\n' >&2
    exit 1
fi

binaries=()
for architecture in "${architectures[@]}"; do
    case "$architecture" in
        arm64|x86_64) ;;
        *) printf 'Unsupported architecture: %s (use arm64 or x86_64).\n' "$architecture" >&2; exit 1 ;;
    esac
    swift build -c release --arch "$architecture" --product UsageIslandPrototype
    binaries+=("$(swift build -c release --arch "$architecture" --show-bin-path)/UsageIslandPrototype")
done

app_path="$PWD/dist/Usage Island.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
if [[ "${#binaries[@]}" -gt 1 ]]; then
    lipo -create "${binaries[@]}" -output "$app_path/Contents/MacOS/UsageIslandPrototype"
else
    cp "${binaries[0]}" "$app_path/Contents/MacOS/UsageIslandPrototype"
fi
cp Assets/OpenAI/LICENSE.md "$app_path/Contents/Resources/OpenAI-SimpleIcons-LICENSE.md"
cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>UsageIslandPrototype</string>
    <key>CFBundleIdentifier</key><string>com.likanlabs.usageisland</string>
    <key>CFBundleName</key><string>Usage Island</string>
    <key>CFBundleDisplayName</key><string>Usage Island</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${version}</string>
    <key>CFBundleVersion</key><string>${version}</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
plutil -lint "$app_path/Contents/Info.plist"
if [[ -n "${USAGE_ISLAND_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$USAGE_ISLAND_SIGNING_IDENTITY" "$app_path"
else
    codesign --force --sign - "$app_path"
fi
codesign --verify --strict "$app_path"
printf '\nBuilt: %s\n' "$app_path"
