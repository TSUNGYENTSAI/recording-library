#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
source_app="$repo/dist/Recording Library.app"
target="${1:-$HOME/Applications/Recording Library.app}"
[[ -d "$source_app" ]] || { echo 'Run Scripts/build.sh first.' >&2; exit 2; }
[[ ! -e "$target" ]] || { echo "Target already exists; quit the app and move the old bundle aside before updating: $target" >&2; exit 2; }
mkdir -p "$(dirname "$target")"
ditto "$source_app" "$target"
codesign --verify --deep --strict "$target"
echo "Installed: $target"
echo 'Library and models remain in Application Support/RecordingLibrary; no audio or models were copied.'
