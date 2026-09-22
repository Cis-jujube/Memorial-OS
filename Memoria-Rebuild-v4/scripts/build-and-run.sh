#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build
binary_dir="$(swift build --show-bin-path)"
app_dir="$PWD/dist/MemoriaRebuild.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/MemoriaRebuild" "$app_dir/Contents/MacOS/MemoriaRebuild"
# SwiftPM uses a sibling resource bundle for the library's schemas.
for bundle in "$binary_dir"/*.bundle(N); do
  cp -R "$bundle" "$app_dir/Contents/Resources/"
  cp -R "$bundle" "$app_dir/Contents/MacOS/"
done
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MemoriaRebuild</string>
<key>CFBundleIdentifier</key><string>local.jujube.memoria.rebuild.v4</string>
<key>CFBundleName</key><string>Memoria Rebuild</string>
<key>CFBundleDisplayName</key><string>Memoria</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict "$app_dir"
if [[ "${1:-}" != "--build-only" ]]; then
  open "$app_dir"
fi
printf '%s\n' "$app_dir"
