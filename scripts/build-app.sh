#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
signing_identity="${BILINEXT_SIGNING_IDENTITY:-}"
if [ -z "$signing_identity" ] && [ -f .signing-identity ]; then
    IFS= read -r signing_identity < .signing-identity
fi
if [ -z "$signing_identity" ] || [ "$signing_identity" = "-" ]; then
    printf '%s\n' 'Set BILINEXT_SIGNING_IDENTITY or .signing-identity to a persistent code-signing certificate. Ad-hoc signing causes repeated Keychain prompts.' >&2
    exit 1
fi
swift build
bin_dir="$(swift build --show-bin-path)"
app_dir="$PWD/build/BiliNext.app"
mkdir -p "$app_dir/Contents/MacOS"
cp "$bin_dir/BiliNext" "$app_dir/Contents/MacOS/BiliNext"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BiliNext</string>
<key>CFBundleIdentifier</key><string>me.nickxu.BiliNext</string>
<key>CFBundleName</key><string>BiliNext</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 scripts/bundle-mpv.py "$app_dir"
for library in "$app_dir"/Contents/Frameworks/*.dylib; do
    codesign --force --sign "$signing_identity" "$library"
done
codesign --force --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
