#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo/.build/test-bins" "$repo/.build/test-data" "$repo/.build/module-cache"
base="$repo/Sources/RecordingLibrary"
flags=(-swift-version 5 -O -parse-as-library -module-cache-path "$repo/.build/module-cache" -target arm64-apple-macosx14.2)
swiftc "${flags[@]}" "$base/Models.swift" "$base/Store.swift" "$repo/Tests/StorageChecks.swift" -o "$repo/.build/test-bins/storage" -lsqlite3
"$repo/.build/test-bins/storage" "$repo/.build/test-data"
common=("$base/Models.swift" "$base/Store.swift" "$base/Configuration.swift" "$base/Engine.swift" "$base/Capture.swift" "$base/SystemAudio.swift" "$base/PCMInput.swift")
swiftc "${flags[@]}" "${common[@]}" "$repo/Tests/ConfigurationChecks.swift" -o "$repo/.build/test-bins/configuration" -lsqlite3
"$repo/.build/test-bins/configuration" "$repo/.build/test-data"
swiftc "${flags[@]}" "${common[@]}" "$repo/Tests/PCMInputChecks.swift" -o "$repo/.build/test-bins/pcm" -lsqlite3
"$repo/.build/test-bins/pcm" "$repo"
python3 - "$repo" <<'PY'
import ast,json,sys
from pathlib import Path
root=Path(sys.argv[1])
for folder in [root/'Scripts',root/'Workers/TextModel']:
 for path in folder.glob('*.py'):ast.parse(path.read_text())
json.loads((root/'Scripts/models.lock.json').read_text())
print('PYTHON AND MODEL MANIFEST CHECKS PASSED')
PY

python3 "$repo/Tests/SetupChecks.py"
