#!/usr/bin/env python3
"""
patch-package-swift.py — surgically rewrite Package.swift's .binaryTarget block
from path-based to URL-based (or vice-versa).

Used by scripts/release.sh and .github/workflows/build-ghosttykit.yml. Single
source of truth for the regex pattern, so the CLI and CI flows can't diverge.

Usage:
    patch-package-swift.py --url <RELEASE_ASSET_URL> --checksum <SHA256>
        Rewrites:
            .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework")
        Into:
            .binaryTarget(
                name: "GhosttyKit",
                url: "<URL>",
                checksum: "<SHA256>"
            )

    patch-package-swift.py --restore-path
        Reverse: rewrites the URL-based block back to path-based. Used when
        resetting main after a release commit so binaries don't appear to live
        on main. Idempotent.

Refuses to patch if the expected source pattern isn't found (defensive — a
silent no-op would let release.sh continue and ship a broken Package.swift).

Exit codes:
    0  patched successfully (or already in target state)
    1  Package.swift not in expected shape
    2  invalid arguments
"""

import argparse
import pathlib
import re
import sys

PATH_BASED_RE = re.compile(
    r'\.binaryTarget\(\s*name:\s*"GhosttyKit",\s*path:\s*"vendor/GhosttyKit\.xcframework"\s*\)',
    re.MULTILINE,
)

URL_BASED_RE = re.compile(
    r'\.binaryTarget\(\s*\n?\s*name:\s*"GhosttyKit",\s*\n?\s*url:\s*"[^"]+",\s*\n?\s*checksum:\s*"[a-f0-9]+"\s*\n?\s*\)',
    re.MULTILINE,
)

PATH_BASED_BLOCK = '.binaryTarget(\n            name: "GhosttyKit",\n            path: "vendor/GhosttyKit.xcframework"\n        )'


def url_based_block(url: str, checksum: str) -> str:
    return (
        '.binaryTarget(\n'
        '            name: "GhosttyKit",\n'
        f'            url: "{url}",\n'
        f'            checksum: "{checksum}"\n'
        '        )'
    )


def patch_to_url(package_swift: pathlib.Path, url: str, checksum: str) -> int:
    src = package_swift.read_text()

    if URL_BASED_RE.search(src):
        # Already URL-based. Replace with the new URL/checksum.
        new = url_based_block(url, checksum)
        patched = URL_BASED_RE.sub(new, src, count=1)
        if patched == src:
            print("error: URL-based block found but substitution didn't change anything", file=sys.stderr)
            return 1
        package_swift.write_text(patched)
        print(f"updated existing URL-based binaryTarget: url={url}, checksum={checksum[:12]}...")
        return 0

    if not PATH_BASED_RE.search(src):
        print(
            f"error: {package_swift} doesn't contain the expected path-based .binaryTarget block.\n"
            f"       Expected to match pattern: {PATH_BASED_RE.pattern}",
            file=sys.stderr,
        )
        return 1

    patched = PATH_BASED_RE.sub(url_based_block(url, checksum), src, count=1)
    if patched == src:
        print("error: substitution found pattern but didn't change source", file=sys.stderr)
        return 1

    package_swift.write_text(patched)
    print(f"patched path-based → URL-based: url={url}, checksum={checksum[:12]}...")
    return 0


def restore_path(package_swift: pathlib.Path) -> int:
    src = package_swift.read_text()

    if PATH_BASED_RE.search(src):
        print("Package.swift already path-based; no-op")
        return 0

    if not URL_BASED_RE.search(src):
        print(
            f"error: {package_swift} doesn't contain the expected URL-based .binaryTarget block.\n"
            f"       Expected to match pattern: {URL_BASED_RE.pattern}",
            file=sys.stderr,
        )
        return 1

    patched = URL_BASED_RE.sub(PATH_BASED_BLOCK, src, count=1)
    if patched == src:
        print("error: substitution found URL-based pattern but didn't change source", file=sys.stderr)
        return 1

    package_swift.write_text(patched)
    print("restored URL-based → path-based binaryTarget")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--package", default="Package.swift", help="Path to Package.swift (default: Package.swift)")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--url", help="Release asset URL for the URL-based binary target")
    g.add_argument("--restore-path", action="store_true", help="Reverse: rewrite URL-based block back to path-based")
    p.add_argument("--checksum", help="SwiftPM sha256 checksum (required with --url)")
    args = p.parse_args()

    package_swift = pathlib.Path(args.package)
    if not package_swift.exists():
        print(f"error: {package_swift} not found", file=sys.stderr)
        return 2

    if args.restore_path:
        return restore_path(package_swift)

    if not args.checksum:
        print("error: --checksum is required when using --url", file=sys.stderr)
        return 2

    return patch_to_url(package_swift, args.url, args.checksum)


if __name__ == "__main__":
    sys.exit(main())
