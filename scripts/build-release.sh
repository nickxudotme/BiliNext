#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export BILINEXT_DISTRIBUTION=1
export BILINEXT_BUILD_CONFIGURATION=release
export BILINEXT_BUNDLE_MPV=0
bash scripts/build-app.sh
version="${BILINEXT_VERSION:-0.1.0}"
mkdir -p dist
archive="dist/BiliNext-${version}-arm64.zip"
test "$(uname -m)" = arm64
if [ -e "$archive" ]; then rm "$archive"; fi
ditto -c -k --sequesterRsrc --keepParent build/BiliNext.app "$archive"
shasum -a 256 "$archive"
