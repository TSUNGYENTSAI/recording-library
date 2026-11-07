#!/usr/bin/env python3
"""Generate fictional speech locally, without recording or playing any audio."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

repo = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--example', choices=['product-discussion', 'personal-idea'], default='product-discussion')
args = parser.parse_args()
say = shutil.which('say')
if not say:
    parser.error('macOS say is required.')
folder = repo / '.build' / 'examples'
folder.mkdir(parents=True, exist_ok=True)
output = folder / (args.example + '.aiff')
# Refuse overwriting an existing generated sample; no real Library paths are used.
if output.exists():
    parser.error(f'Sample already exists: {output}. Move it aside before generating again.')
subprocess.run([say, '-f', str(repo / 'Examples' / args.example / 'source.txt'), '-o', str(output)], check=True)
probe = shutil.which('ffprobe')
if probe:
    result = subprocess.run([probe, '-v', 'error', '-show_entries', 'format=duration', '-of', 'json', str(output)], check=True, capture_output=True, text=True)
    duration = float(json.loads(result.stdout).get('format', {}).get('duration', 0))
    if duration < 1:
        parser.error(f'Speech synthesis produced no usable audio: {output}. Move this file aside and retry from Terminal outside a restricted sandbox.')
elif output.stat().st_size < 8192:
    parser.error(f'Speech synthesis produced an unexpectedly small file: {output}. Check macOS speech settings and retry.')
print(f'Generated fictional speech (not played): {output}')
print('Import this sample to test transcription; press Start recording to use your own microphone/system audio.')
