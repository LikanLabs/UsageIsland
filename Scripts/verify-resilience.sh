#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scratch_dir="$(mktemp -d)"
trap 'rm -rf "$scratch_dir"' EXIT
swift build --scratch-path "$scratch_dir" --product UsageIslandPrototype
binary_dir="$(swift build --scratch-path "$scratch_dir" --show-bin-path)"
objects=()
for object in "$binary_dir"/UsageIslandPrototype.build/*.swift.o; do
    if [[ "$object" != */UsageIslandApp.swift.o ]]; then objects+=("$object"); fi
done
swiftc -swift-version 6 -parse-as-library -I "$binary_dir/Modules" \
    Tests/UsageIslandPrototypeTests/ResilienceScenarios.swift \
    Scripts/verify-resilience.swift "${objects[@]}" -o "$binary_dir/verify-resilience"
"$binary_dir/verify-resilience"
