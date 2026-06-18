#!/usr/bin/env bash
#
# scripts/build-xcframework.sh — clone-and-build entry point for v0.2.0+.
#
# Produces a SwiftPM-consumable xcframework + dSYM + checksum for the
# Ghostty fork. Idempotent: re-running clears build/ and rebuilds.
#
# This script is the core of the v0.2.0+ pipeline. It does NOT do any
# distribution work (no git, no gh, no tag). scripts/release.sh wraps it
# with the release-cut steps. CI calls it directly via
# .github/workflows/build-ghosttykit.yml.
#
# Compared to v0.1.0's release.sh, this preserves full debug info:
#   * NO -Wl,-exported_symbols_list  (all C symbols stay reachable)
#   * NO -Wl,-dead_strip             (all vendored deps stay live)
#   * NO strip -S -x                 (debug symbols stay inline in dylib)
# Plus generates a separate dSYM bundle for crash symbolication.
#
# Resulting xcframework is much larger than v0.1.0 (~270 MB vs 13 MB) but
# ships as a release asset, not a git-tracked file, so the size
# difference doesn't hit a git host per-file size limit.
#
# Usage:
#   scripts/build-xcframework.sh [VERSION]
#     VERSION defaults to "dev" if not supplied. Used in the Info.plist
#     and in the output filenames (build/GhosttyKit-<VERSION>.xcframework.zip).
#
# Environment variables (all optional):
#   INPUT_AR        path to libghostty static archive
#                   (default: macos/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a
#                    after `zig build -Demit-xcframework=true`)
#   RESOURCES_SRC   path to ghostty/+terminfo/ resources dir
#                   (default: zig-out/share)
#   SKIP_ZIG_BUILD  if "1", skip the zig build step (assumes INPUT_AR
#                   already points at a pre-built archive — useful on
#                   machines where zig build is blocked, e.g. some
#                   Xcode SDKs that omit plain arm64 from libSystem.tbd)
#
# Outputs (in $REPO_ROOT/build/):
#   GhosttyKit.xcframework/                       full dynamic xcframework tree (for inspection)
#   GhosttyKit-<VERSION>.xcframework.zip          DYNAMIC SwiftPM-consumable zip artifact (mac-arm64,
#                                                 ~7 MB; this is what Package.swift points at by default)
#   GhosttyKit-<VERSION>.dSYM.zip                 separate dSYM bundle for the dynamic asset (~16 MB,
#                                                 for crash symbolication; not auto-fetched by SwiftPM)
#   GhosttyKit-<VERSION>.xcframework.zip.sha256   SwiftPM checksum for the dynamic asset
#   GhosttyKit-static.xcframework/                static xcframework tree (Muxy verbatim, all 3 slices)
#   GhosttyKit-<VERSION>-static.xcframework.zip   STATIC SwiftPM-consumable zip artifact (~131 MB,
#                                                 all 3 slices: macos-arm64_x86_64 + ios-arm64 +
#                                                 ios-arm64-simulator. Use for iOS consumers or
#                                                 maximum-preservation use case. See docs/CONSUMING.md
#                                                 for how to switch Package.swift to point at this.)
#   GhosttyKit-<VERSION>-static.xcframework.zip.sha256
#                                                 SwiftPM checksum for the static asset
#   Resources/{ghostty,terminfo}/                 staged runtime resources (for release.sh to copy
#                                                 into Sources/Ghostty/Resources/)
#
# Set BUILD_STATIC=0 to skip producing the static asset (just dynamic + dSYM).
#
# Exit codes:
#   0  success
#   1  preflight failure or build error
#   2  invalid arguments
#

set -euo pipefail

#---------------------------------------------------------------------
# Args + paths
#---------------------------------------------------------------------

VERSION="${1:-dev}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build"
SCRATCH=""
trap 'rm -rf "$SCRATCH"' EXIT

#---------------------------------------------------------------------
# Preflight
#---------------------------------------------------------------------

echo "==> preflight"

# Tools we need at every step.
for tool in clang lipo dsymutil codesign xcodebuild zip; do
    command -v "$tool" >/dev/null || {
        echo "error: required tool '$tool' not found in PATH" >&2
        exit 1
    }
done

# swift package compute-checksum runs via xcrun (uses Xcode-bundled Swift,
# avoids swiftly toolchain mismatch with newer SDKs).
xcrun --find swift >/dev/null || {
    echo "error: 'xcrun swift' not found; install Xcode" >&2
    exit 1
}

# Determine whether we need zig for this run.
INPUT_AR_DEFAULT="macos/GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a"
INPUT_AR="${INPUT_AR:-$INPUT_AR_DEFAULT}"
SKIP_ZIG_BUILD="${SKIP_ZIG_BUILD:-0}"

if [ "$SKIP_ZIG_BUILD" != "1" ] && [ ! -f "$INPUT_AR" ]; then
    command -v zig >/dev/null || {
        echo "error: 'zig' not found in PATH and INPUT_AR doesn't exist." >&2
        echo "       Either:" >&2
        echo "       (a) install zig 0.15.2: \`mise install zig@0.15.2 && eval \"\$(mise activate zsh)\"\`" >&2
        echo "       (b) point INPUT_AR at a pre-built libghostty static archive and set SKIP_ZIG_BUILD=1" >&2
        exit 1
    }

    ZIG_VERSION="$(zig version 2>&1 || echo 'unknown')"
    if [ "$ZIG_VERSION" != "0.15.2" ]; then
        echo "warning: zig $ZIG_VERSION detected; Ghostty pins minimum_zig_version = 0.15.2" >&2
        echo "         Build may fail. Use \`mise install zig@0.15.2\` if it does." >&2
    fi
fi

#---------------------------------------------------------------------
# Step 1: zig build (if needed)
#---------------------------------------------------------------------

if [ "$SKIP_ZIG_BUILD" = "1" ]; then
    echo "==> SKIP_ZIG_BUILD=1; skipping zig build (using $INPUT_AR)"
elif [ -f "$INPUT_AR" ]; then
    echo "==> $INPUT_AR already exists; skipping zig build"
    echo "    (delete the file or set SKIP_ZIG_BUILD=0 to force a rebuild)"
else
    echo "==> zig build (xcframework, ReleaseFast, no macOS app)"
    zig build \
        -Doptimize=ReleaseFast \
        -Demit-xcframework=true \
        -Demit-macos-app=false
fi

if [ ! -f "$INPUT_AR" ]; then
    echo "error: expected static archive at $INPUT_AR after build, not found" >&2
    exit 1
fi

#---------------------------------------------------------------------
# Step 2: locate runtime resources
#---------------------------------------------------------------------

RESOURCES_SRC="${RESOURCES_SRC:-zig-out/share}"
if [ ! -d "$RESOURCES_SRC/ghostty/shell-integration" ] || [ ! -d "$RESOURCES_SRC/terminfo" ]; then
    echo "error: runtime resources not found in $RESOURCES_SRC" >&2
    echo "       expected: $RESOURCES_SRC/ghostty/shell-integration/ and $RESOURCES_SRC/terminfo/" >&2
    echo "       set RESOURCES_SRC to a directory containing both, or run 'zig build' first" >&2
    exit 1
fi

#---------------------------------------------------------------------
# Step 3: convert static .a (universal) → dynamic .framework (arm64)
#---------------------------------------------------------------------

SCRATCH="$(mktemp -d)"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> lipo-thin arm64 (drop x86_64 — Mac is arm64-first; see docs/known-quirks.md)"
lipo -thin arm64 -output "$SCRATCH/ghostty.a" "$INPUT_AR"
echo "    arm64-only static: $(du -h "$SCRATCH/ghostty.a" | cut -f1)"

echo "==> link dynamic library (FULL DEBUG INFO — no strip, no dead-strip, no exports filter)"
clang -dynamiclib \
    -arch arm64 \
    -mmacosx-version-min=14.0 \
    -isysroot "$(xcrun --show-sdk-path --sdk macosx)" \
    -Wl,-force_load,"$SCRATCH/ghostty.a" \
    -framework AppKit -framework Carbon -framework CoreGraphics \
    -framework CoreText -framework CoreVideo -framework Foundation \
    -framework GameController \
    -framework IOKit -framework IOSurface \
    -framework Metal -framework MetalKit \
    -framework QuartzCore \
    -lc++ \
    -install_name '@rpath/GhosttyKit.framework/GhosttyKit' \
    -o "$SCRATCH/GhosttyKit"

DYLIB_BYTES=$(stat -f %z "$SCRATCH/GhosttyKit")
DYLIB_MB=$((DYLIB_BYTES / 1024 / 1024))
echo "    dylib (with debug info): ${DYLIB_MB} MB"

#---------------------------------------------------------------------
# Step 4: extract dSYM bundle (separate distribution artifact)
#---------------------------------------------------------------------

echo "==> extract dSYM bundle"
dsymutil "$SCRATCH/GhosttyKit" -o "$SCRATCH/GhosttyKit.dSYM"

DSYM_BYTES=$(find "$SCRATCH/GhosttyKit.dSYM" -type f -exec stat -f %z {} \; | awk '{s+=$1} END {print s}')
DSYM_MB=$((DSYM_BYTES / 1024 / 1024))
echo "    dSYM bundle: ${DSYM_MB} MB"

#---------------------------------------------------------------------
# Step 5: build .framework bundle
#---------------------------------------------------------------------

echo "==> build .framework bundle"
FW="$SCRATCH/GhosttyKit.framework"
mkdir -p "$FW/Versions/A/Headers" \
         "$FW/Versions/A/Modules" \
         "$FW/Versions/A/Resources"

cp "$SCRATCH/GhosttyKit" "$FW/Versions/A/GhosttyKit"
cp include/ghostty.h "$FW/Versions/A/Headers/"

cat > "$FW/Versions/A/Modules/module.modulemap" <<'MODULEMAP'
framework module GhosttyKit {
    umbrella header "ghostty.h"
    export *
    module * { export * }
}
MODULEMAP

# Strip leading "v" from VERSION for CFBundleVersion (e.g. "v0.2.0" → "0.2.0").
VERSION_NUM="${VERSION#v}"
cat > "$FW/Versions/A/Resources/Info.plist" <<INFOPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>GhosttyKit</string>
    <key>CFBundleIdentifier</key><string>com.mblumling.GhosttyKit</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>GhosttyKit</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>${VERSION_NUM}</string>
    <key>CFBundleVersion</key><string>${VERSION_NUM}</string>
    <key>CFBundleSignature</key><string>????</string>
    <key>MinimumOSVersion</key><string>14.0</string>
</dict>
</plist>
INFOPLIST

(cd "$FW/Versions" && ln -sfn A Current)
(cd "$FW" \
    && ln -sfn Versions/Current/GhosttyKit GhosttyKit \
    && ln -sfn Versions/Current/Headers Headers \
    && ln -sfn Versions/Current/Modules Modules \
    && ln -sfn Versions/Current/Resources Resources)

echo "==> ad-hoc codesign framework"
codesign --force --sign - --timestamp=none "$FW"

#---------------------------------------------------------------------
# Step 6: wrap as xcframework
#---------------------------------------------------------------------

echo "==> create xcframework"
xcodebuild -create-xcframework \
    -framework "$FW" \
    -output "$BUILD_DIR/GhosttyKit.xcframework" \
    >/dev/null

# Move dSYM into place too.
cp -R "$SCRATCH/GhosttyKit.dSYM" "$BUILD_DIR/GhosttyKit.dSYM"

#---------------------------------------------------------------------
# Step 6b: stage the STATIC xcframework verbatim from Muxy
#
# This preserves Muxy's exact output: 3 slices (macos-arm64_x86_64 +
# ios-arm64 + ios-arm64-simulator), all static archives with inline
# DWARF, all vendored deps reachable. ~131 MB zipped vs ~7 MB for the
# dynamic asset above.
#
# Use cases for the static asset:
#   * Future iOS/iOS-sim consumers (the dynamic asset is mac-arm64-only)
#   * Consumer-side dead-strip preferred (their app's linker drops
#     unused libghostty code at link time)
#   * Maximum-preservation use case ("don't lose anything from Muxy")
#
# The static xcframework is the parent directory of INPUT_AR.
# E.g. INPUT_AR=.../GhosttyKit.xcframework/macos-arm64_x86_64/ghostty-internal.a
#      → STATIC_XCF_DIR=.../GhosttyKit.xcframework
#
# Skip this step (and don't produce a static asset) if BUILD_STATIC=0
# is set in the environment.
#---------------------------------------------------------------------

BUILD_STATIC="${BUILD_STATIC:-1}"
STATIC_XCF_ZIP=""
STATIC_CHECKSUM_FILE=""
STATIC_CHECKSUM=""
STATIC_XCF_ZIP_BYTES=0
STATIC_XCF_ZIP_MB=0

if [ "$BUILD_STATIC" = "1" ]; then
    # Walk up from INPUT_AR to find the .xcframework directory.
    STATIC_XCF_DIR="$(cd "$(dirname "$INPUT_AR")/.." && pwd)"
    if [ ! -d "$STATIC_XCF_DIR" ] || [ ! -f "$STATIC_XCF_DIR/Info.plist" ]; then
        echo "warning: BUILD_STATIC=1 but could not locate parent xcframework of INPUT_AR" >&2
        echo "         Looked at: $STATIC_XCF_DIR" >&2
        echo "         Skipping static asset. Set BUILD_STATIC=0 to silence this." >&2
    else
        echo "==> stage static xcframework from $STATIC_XCF_DIR (preserves all 3 slices verbatim)"
        # Copy into build/ so we can rezip from a clean location.
        rm -rf "$BUILD_DIR/GhosttyKit-static.xcframework"
        cp -R "$STATIC_XCF_DIR" "$BUILD_DIR/GhosttyKit-static.xcframework"

        # Sanity: must contain at least the 3 slice dirs we expect.
        for slice in macos-arm64_x86_64 ios-arm64 ios-arm64-simulator; do
            if [ ! -d "$BUILD_DIR/GhosttyKit-static.xcframework/$slice" ]; then
                echo "warning: static xcframework missing expected slice '$slice'" >&2
            fi
        done
    fi
fi

#---------------------------------------------------------------------
# Step 7: stage runtime resources (uncompressed for release.sh to copy)
#---------------------------------------------------------------------

echo "==> stage runtime resources from $RESOURCES_SRC"
mkdir -p "$BUILD_DIR/Resources/ghostty"
cp -R "$RESOURCES_SRC/ghostty/shell-integration" "$BUILD_DIR/Resources/ghostty/"
cp -R "$RESOURCES_SRC/ghostty/themes" "$BUILD_DIR/Resources/ghostty/"
cp -R "$RESOURCES_SRC/terminfo" "$BUILD_DIR/Resources/"

#---------------------------------------------------------------------
# Step 8: zip the artifacts (SwiftPM .binaryTarget(url:) requires .zip)
#---------------------------------------------------------------------

echo "==> zip dynamic xcframework"
XCF_ZIP="$BUILD_DIR/GhosttyKit-${VERSION}.xcframework.zip"
(cd "$BUILD_DIR" && zip -qry "$(basename "$XCF_ZIP")" GhosttyKit.xcframework)

echo "==> zip dSYM"
DSYM_ZIP="$BUILD_DIR/GhosttyKit-${VERSION}.dSYM.zip"
(cd "$BUILD_DIR" && zip -qry "$(basename "$DSYM_ZIP")" GhosttyKit.dSYM)

if [ -d "$BUILD_DIR/GhosttyKit-static.xcframework" ]; then
    echo "==> zip static xcframework (Muxy verbatim, all 3 slices)"
    STATIC_XCF_ZIP="$BUILD_DIR/GhosttyKit-${VERSION}-static.xcframework.zip"
    (cd "$BUILD_DIR" && zip -qry "$(basename "$STATIC_XCF_ZIP")" GhosttyKit-static.xcframework)
fi

#---------------------------------------------------------------------
# Step 9: compute SwiftPM checksums
#---------------------------------------------------------------------

echo "==> compute SwiftPM checksum (dynamic)"
CHECKSUM="$(xcrun swift package compute-checksum "$XCF_ZIP")"
CHECKSUM_FILE="$XCF_ZIP.sha256"
echo "$CHECKSUM" > "$CHECKSUM_FILE"

if [ -n "$STATIC_XCF_ZIP" ]; then
    echo "==> compute SwiftPM checksum (static)"
    STATIC_CHECKSUM="$(xcrun swift package compute-checksum "$STATIC_XCF_ZIP")"
    STATIC_CHECKSUM_FILE="$STATIC_XCF_ZIP.sha256"
    echo "$STATIC_CHECKSUM" > "$STATIC_CHECKSUM_FILE"
fi

#---------------------------------------------------------------------
# Step 10: size sanity check (release asset limit is 2 GB)
#---------------------------------------------------------------------

XCF_ZIP_BYTES=$(stat -f %z "$XCF_ZIP")
DSYM_ZIP_BYTES=$(stat -f %z "$DSYM_ZIP")
XCF_ZIP_MB=$((XCF_ZIP_BYTES / 1024 / 1024))
DSYM_ZIP_MB=$((DSYM_ZIP_BYTES / 1024 / 1024))

if [ -n "$STATIC_XCF_ZIP" ]; then
    STATIC_XCF_ZIP_BYTES=$(stat -f %z "$STATIC_XCF_ZIP")
    STATIC_XCF_ZIP_MB=$((STATIC_XCF_ZIP_BYTES / 1024 / 1024))
fi

# 2 GB = 2 * 1024 * 1024 * 1024 = 2147483648 bytes.
# Refuse if any asset exceeds 2 GB (release asset hard limit).
if [ "$XCF_ZIP_BYTES" -gt 2147483648 ] || [ "$DSYM_ZIP_BYTES" -gt 2147483648 ] || [ "$STATIC_XCF_ZIP_BYTES" -gt 2147483648 ]; then
    echo "error: one of the build artifacts exceeds the 2 GB release asset limit:" >&2
    echo "       dynamic xcframework zip: ${XCF_ZIP_MB} MB" >&2
    echo "       dSYM zip:                ${DSYM_ZIP_MB} MB" >&2
    [ -n "$STATIC_XCF_ZIP" ] && echo "       static xcframework zip:  ${STATIC_XCF_ZIP_MB} MB" >&2
    exit 1
fi

#---------------------------------------------------------------------
# Final summary
#---------------------------------------------------------------------

cat <<EOF

==========================================================
build-xcframework.sh completed for VERSION=$VERSION
==========================================================

Artifacts in $BUILD_DIR/:
  $(basename "$XCF_ZIP")
      ${XCF_ZIP_MB} MB    sha256: $CHECKSUM
      (DYNAMIC mac-arm64; full debug info via the separate dSYM below)
  $(basename "$DSYM_ZIP")
      ${DSYM_ZIP_MB} MB    (dSYM bundle for crash symbolication)
  Resources/{ghostty,terminfo}
      runtime resources, ready to be staged by the consuming repo
EOF
