#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
case "$MODE" in
  run|--debug|--logs|--telemetry|--verify|--preview) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--preview]" >&2; exit 2 ;;
esac
BUILD_PRODUCT="SourceEditorDemo"
APP_NAME="SourceEditorDemo"
BUNDLE_ID="dev.ktiays.SourceEditorDemo"
DISPLAY_NAME="SourceEditor"
SOURCE_EDITOR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SOURCE_EDITOR_ROOT"
APP_BUNDLE="$SOURCE_EDITOR_ROOT/dist/$APP_NAME.app"
export SOURCE_EDITOR_CORE_ONLY=0

if [[ "$MODE" == "--preview" ]]; then
  APP_NAME="SourceEditorPreview"
  BUNDLE_ID="dev.ktiays.SourceEditorPreview"
  DISPLAY_NAME="SourceEditor Preview"
  mkdir -p "$SOURCE_EDITOR_ROOT/dist"
  PREVIEW_DIR="$(mktemp -d "$SOURCE_EDITOR_ROOT/dist/preview.XXXXXX")"
  APP_BUNDLE="$PREVIEW_DIR/$APP_NAME.app"
else
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi
swift build --product "$BUILD_PRODUCT"
BUILD_DIR="$(swift build --show-bin-path)"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
cp "$BUILD_DIR/$BUILD_PRODUCT" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
QUERY_BUNDLE="$BUILD_DIR/SourceEditor_SourceEditorTreeSitter.bundle"
if [[ -d "$QUERY_BUNDLE" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources"
  cp -R "$QUERY_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi
if [[ -f "$SOURCE_EDITOR_ROOT/THIRD_PARTY_NOTICES.txt" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources"
  cp "$SOURCE_EDITOR_ROOT/THIRD_PARTY_NOTICES.txt" "$APP_BUNDLE/Contents/Resources/"
fi
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$DISPLAY_NAME</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

case "$MODE" in
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --preview)
    /usr/bin/open -n "$APP_BUNDLE"
    echo "Preview launched: $APP_BUNDLE"
    ;;
  --debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME launched."
    ;;
esac
