#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# The standalone runner links the package's object files directly, which only
# the native build system lays out as `<bin>/<target>.build/*.swift.o` with a
# `Modules` directory. Newer toolchains default to swiftbuild, so opt out there.
build_system=()
if swift build --help 2>/dev/null | grep -q 'default: swiftbuild'; then
    build_system=(--build-system native)
fi
swift build ${build_system[@]+"${build_system[@]}"} --product UsageIslandPrototype
binary_dir="$(swift build ${build_system[@]+"${build_system[@]}"} --show-bin-path)"
objects=()
for object in "$binary_dir"/UsageIslandPrototype.build/*.swift.o; do
    if [[ "$object" != */UsageIslandApp.swift.o ]]; then objects+=("$object"); fi
done
if [[ "${#objects[@]}" -eq 0 || ! -e "${objects[0]}" ]]; then
    printf 'No object files found under %s; run `swift test --filter ResilienceTests` instead.\n' "$binary_dir" >&2
    exit 1
fi
swiftc -swift-version 6 -parse-as-library -I "$binary_dir/Modules" \
    Tests/UsageIslandPrototypeTests/ResilienceScenarios.swift \
    Scripts/verify-resilience.swift "${objects[@]}" -o "$binary_dir/verify-resilience"
"$binary_dir/verify-resilience"
