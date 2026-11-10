#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$(uname -m)" == arm64 ]] || { echo 'Apple Silicon is required for this early preview.' >&2; exit 2; }
mkdir -p "$repo/.build/module-cache" "$repo/dist"
export CLANG_MODULE_CACHE_PATH="$repo/.build/module-cache"
if [[ -n "${RECORDING_LIBRARY_WORKER:-}" ]]; then
  worker="$RECORDING_LIBRARY_WORKER"
else
  swift build --package-path "$repo/Workers/WhisperWorker" --scratch-path "$repo/.build/whisper" -c release --disable-sandbox
  worker="$repo/.build/whisper/release/Validate"
fi
worker_name="Validate-$(shasum -a 256 "$worker" | cut -c 1-16)"
text_worker="$repo/Workers/TextModel/local_text.py"
text_name="local_text-$(shasum -a 256 "$text_worker" | cut -c 1-16).py"
app="$repo/dist/Recording Library.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/WhisperValidation" "$app/Contents/Resources/TextModel" "$app/Contents/Resources/Setup" "$app/Contents/Resources/Licenses"
swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$repo/.build/module-cache" -target arm64-apple-macosx14.2 "$repo"/Sources/RecordingLibrary/*.swift -o "$app/Contents/MacOS/RecordingLibrary" -lsqlite3
cp "$worker" "$app/Contents/Resources/WhisperValidation/$worker_name"
cp "$text_worker" "$app/Contents/Resources/TextModel/$text_name"
cp -R "$repo/Resources/." "$app/Contents/Resources/"
cp "$repo/Assets/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$repo/Scripts/setup-models.sh" "$repo/Scripts/setup_models.py" "$repo/Scripts/models.lock.json" "$repo/Scripts/requirements.lock" "$app/Contents/Resources/Setup/"
cp "$repo/LICENSE" "$repo/THIRD_PARTY_NOTICES.md" "$repo/Docs/WhisperKit-LICENSE" "$app/Contents/Resources/Licenses/"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>RecordingLibrary</string>
<key>CFBundleIdentifier</key><string>local.recordinglibrary.mac</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hant</string></array>
<key>CFBundleName</key><string>Recording Library</string>
<key>CFBundleDisplayName</key><string>Recording Library</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.9.1</string>
<key>CFBundleVersion</key><string>11</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Record system audio locally for transcription while headphones continue playing.</string>
<key>NSMicrophoneUsageDescription</key><string>Record microphone audio locally for transcription.</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>RecordingLibraryWorker</key><string>$worker_name</string>
<key>RecordingLibraryTextWorker</key><string>$text_name</string>
<key>CFBundleDocumentTypes</key><array><dict><key>CFBundleTypeName</key><string>Recording</string><key>CFBundleTypeRole</key><string>Viewer</string><key>LSHandlerRank</key><string>Alternate</string><key>LSItemContentTypes</key><array><string>public.audio</string><string>public.movie</string></array></dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$app/Contents/Resources/WhisperValidation/$worker_name"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "Built: $app"
