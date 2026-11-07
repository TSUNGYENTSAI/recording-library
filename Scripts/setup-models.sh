#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
app_root="${1:-$HOME/Library/Application Support/RecordingLibrary}"
shift "$(( $# > 0 ? 1 : 0 ))"
uv_bin=""
for candidate in /opt/homebrew/bin/uv /usr/local/bin/uv "$HOME/.local/bin/uv"; do
  if [[ -x "$candidate" ]]; then uv_bin="$candidate"; break; fi
done
if [[ -z "$uv_bin" ]]; then
  echo 'Install uv and FFmpeg first: brew install uv ffmpeg' >&2
  exit 2
fi
python_bin="$app_root/Runtime/text-model/bin/python"
if [[ ! -x "$python_bin" ]]; then
  "$uv_bin" venv --python 3.12 "$app_root/Runtime/text-model"
fi
"$uv_bin" pip sync --python "$python_bin" "$script_dir/requirements.lock"
exec "$python_bin" "$script_dir/setup_models.py" --root "$app_root" "$@"
