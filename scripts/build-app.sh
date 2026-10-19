#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
signing_identity="${BILINEXT_SIGNING_IDENTITY:-}"
if [ -z "$signing_identity" ] && [ -f .signing-identity ]; then
    IFS= read -r signing_identity < .signing-identity
fi
if [ "${BILINEXT_DISTRIBUTION:-0}" = "1" ]; then
    signing_identity="-"
fi
if [ -z "$signing_identity" ] || { [ "$signing_identity" = "-" ] && [ "${BILINEXT_DISTRIBUTION:-0}" != "1" ]; }; then
    printf '%s\n' 'Set BILINEXT_SIGNING_IDENTITY or .signing-identity to a persistent code-signing certificate. Ad-hoc signing causes repeated Keychain prompts.' >&2
    exit 1
fi
# Local iteration uses the existing development-file backend. Self-signed Release
# binaries get a new Keychain partition (cdhash) whenever their contents change.
build_configuration="${BILINEXT_BUILD_CONFIGURATION:-debug}"
case "$build_configuration" in
    debug|release) ;;
    *) printf '%s\n' 'BILINEXT_BUILD_CONFIGURATION must be debug or release.' >&2; exit 1 ;;
esac
version="${BILINEXT_VERSION:-0.1.0}"
build_number="${BILINEXT_BUILD_NUMBER:-1}"
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! [[ "$build_number" =~ ^[0-9]+$ ]]; then
    printf '%s\n' 'Invalid BILINEXT_VERSION or BILINEXT_BUILD_NUMBER.' >&2
    exit 1
fi
bundle_mpv="${BILINEXT_BUNDLE_MPV:-1}"
case "$bundle_mpv" in
    0|1) ;;
    *) printf '%s\n' 'BILINEXT_BUNDLE_MPV must be 0 or 1.' >&2; exit 1 ;;
esac
if [ "${BILINEXT_DISTRIBUTION:-0}" = "1" ] && [ "$build_configuration" != "release" ]; then
    printf '%s\n' 'Distribution builds must use Release configuration.' >&2
    exit 1
fi
swift build -c "$build_configuration"
bin_dir="$(swift build -c "$build_configuration" --show-bin-path)"
app_dir="$PWD/build/BiliNext.app"
# Remove only the generated bundle so a previous embedded runtime cannot leak
# into a Homebrew-dependent distribution build.
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp Resources/BiliNext.icns "$app_dir/Contents/Resources/BiliNext.icns"
cp LICENSE THIRD-PARTY-NOTICES.md "$app_dir/Contents/Resources/"
cp "$bin_dir/BiliNext" "$app_dir/Contents/MacOS/BiliNext"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
<key>CFBundleExecutable</key><string>BiliNext</string>
<key>CFBundleIdentifier</key><string>me.nickxu.BiliNext</string>
<key>CFBundleIconFile</key><string>BiliNext</string>
<key>CFBundleName</key><string>BiliNext</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app_dir/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app_dir/Contents/Info.plist"
if [ "$bundle_mpv" = "1" ]; then
    python3 scripts/bundle-mpv.py "$app_dir"
    for library in "$app_dir"/Contents/Frameworks/*.dylib; do
        codesign --force --sign "$signing_identity" "$library"
    done
else
    mpv_library="$(brew --prefix mpv)/lib/libmpv.2.dylib"
    otool -L "$app_dir/Contents/MacOS/BiliNext" | awk '{print $1}' | grep -Fx "$mpv_library" >/dev/null || {
        printf '%s\n' 'The executable must link to the Homebrew mpv opt path.' >&2
        exit 1
    }
fi
codesign --force --sign "$signing_identity" "$app_dir"
codesign --verify --deep --strict "$app_dir"
printf '%s\n' "$app_dir"
