#!/usr/bin/env bash
#
# stage-resources.sh — copy zig-out/share/{ghostty,terminfo} into
# Sources/Ghostty/Resources/ in the layout SwiftPM .copy expects.
#
# Called by:
#   - scripts/release.sh (when building locally with a working Zig environment)
#   - .github/workflows/build-ghosttykit.yml (future CI release flow)
#
# Expected source layout:
#   $SRC/ghostty/shell-integration/{bash,elvish,fish,nushell,zsh}/
#   $SRC/ghostty/themes/
#   $SRC/terminfo/{67,78}/
#
# Output layout (terminfo/ and ghostty/ as siblings, NOT nested):
#   Sources/Ghostty/Resources/
#     ├── ghostty/
#     │   ├── shell-integration/
#     │   └── themes/
#     └── terminfo/
#       ├── 67/
#       └── 78/

set -euo pipefail

SRC="${1:-zig-out/share}"
DST="${2:-Sources/Ghostty/Resources}"

if [[ ! -d "$SRC/ghostty" ]] || [[ ! -d "$SRC/terminfo" ]]; then
    echo "error: expected '$SRC/ghostty' and '$SRC/terminfo' to exist" >&2
    echo "       (did you run 'zig build -Demit-xcframework=true'?)" >&2
    exit 1
fi

mkdir -p "$DST/ghostty"
rm -rf "$DST/ghostty/shell-integration" "$DST/ghostty/themes" "$DST/terminfo"

cp -R "$SRC/ghostty/shell-integration" "$DST/ghostty/"
cp -R "$SRC/ghostty/themes" "$DST/ghostty/"
cp -R "$SRC/terminfo" "$DST/"

echo "Staged resources from $SRC into $DST"
echo "  $DST/ghostty/shell-integration ($(find "$DST/ghostty/shell-integration" -type f | wc -l | tr -d ' ') files)"
echo "  $DST/ghostty/themes            ($(find "$DST/ghostty/themes" -type f | wc -l | tr -d ' ') files)"
echo "  $DST/terminfo                  ($(find "$DST/terminfo" -type f | wc -l | tr -d ' ') files)"
