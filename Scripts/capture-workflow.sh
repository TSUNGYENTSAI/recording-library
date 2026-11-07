#!/bin/bash
# Render production SwiftUI views with isolated, replayed fixture state.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo/.build/module-cache"
work=$(mktemp -d "$repo/.build/workflow.XXXXXX")
app="$work/Workflow Capture.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
python3 - "$repo" "$work" <<'PY'
from pathlib import Path
import sys,plistlib,shutil
repo,work=map(Path,sys.argv[1:])
s=(repo/'Sources/RecordingLibrary/App.swift').read_text()
assert s.count('@main struct RecordingLibraryApp: App')==1
s=s.replace('@main struct RecordingLibraryApp: App','struct RecordingLibraryApp: App')
s+='''
// Fixture state injection only; production view bodies are unchanged.
extension LibraryView {
    static func workflowFixture(selection: UUID? = nil, query: String = "", filter: String = "全部錄音") -> Self {
        var view = Self()
        view._selectedIDs = State(initialValue: selection.map {Set([$0])} ?? [])
        view._query = State(initialValue: query)
        view._filter = State(initialValue: filter)
        return view
    }
}
'''
(work/'AppViews.swift').write_text(s)
app=work/'Workflow Capture.app'
shutil.copytree(repo/'Resources',app/'Contents/Resources',dirs_exist_ok=True)
plist={'CFBundleExecutable':'WorkflowCapture','CFBundleIdentifier':'local.recordinglibrary.workflowcapture','CFBundleName':'Workflow Capture','CFBundlePackageType':'APPL','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hant'],'LSUIElement':True,'NSHighResolutionCapable':True,'LSMinimumSystemVersion':'14.2'}
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
PY
sources=()
for source in "$repo"/Sources/RecordingLibrary/*.swift; do
  [[ "$source" == */App.swift ]] || sources+=("$source")
done
swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$repo/.build/module-cache" -target arm64-apple-macosx14.2 "${sources[@]}" "$work/AppViews.swift" "$repo/Scripts/WorkflowCapture.swift" -o "$app/Contents/MacOS/WorkflowCapture" -lsqlite3
codesign --force --sign - "$app"
for language in en zh-Hant; do
  "$app/Contents/MacOS/WorkflowCapture" "$work/$language" -AppleLanguages "($language)"
done
swift -module-cache-path "$repo/.build/module-cache" "$repo/Scripts/render-demo.swift" "$repo" "$work"
echo "Native view frames: $work"
