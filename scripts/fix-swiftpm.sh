#!/bin/bash
# Workaround for a half-updated Command Line Tools install on this machine:
# the stale PackageDescription/PackagePlugin *.private.swiftinterface files
# (old `enum SwiftVersion` API) don't match the newer libPackageDescription
# dylib, so every Package.swift manifest fails to link.
#
# This script builds a repaired copy of the SwiftPM support libraries with the
# stale private interfaces omitted (swiftc then falls back to the correct
# public .swiftinterface). Point SwiftPM at it with:
#   export SWIFTPM_CUSTOM_LIBS_DIR="<repo>/.swiftpm-libs-fix/pm"
# A proper fix is reinstalling the CLT:  sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="/Library/Developer/CommandLineTools/usr/lib/swift/pm"
DST=".swiftpm-libs-fix/pm"

rm -rf "$DST"
for api in ManifestAPI PluginAPI; do
    [ -d "$SRC/$api" ] || continue
    mkdir -p "$DST/$api"
    for dylib in "$SRC/$api"/*.dylib; do
        cp "$dylib" "$DST/$api/"
    done
    for module in "$SRC/$api"/*.swiftmodule; do
        name=$(basename "$module")
        mkdir -p "$DST/$api/$name"
        # Copy everything except the stale .private.swiftinterface files.
        find "$module" -maxdepth 1 -type f ! -name '*.private.swiftinterface' \
            -exec cp {} "$DST/$api/$name/" \;
    done
done
echo "Repaired SwiftPM libs at $DST"
