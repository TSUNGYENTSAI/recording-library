# Validation and limits

The original workflow was exercised on Apple M4 / 16 GB with macOS 15 and Swift 6.1.2. Historical private test materials are intentionally excluded from this repository.

Prior local checks covered M4A, MP4 AAC extraction, a 74-minute recording, Whisper/Qwen staging, cancellation/retry, raw/edit lineage, Chinese substring search, deduplication and trash restoration. Synthetic PCM tests cover interleaved/planar streams, Float32/64 and Int16/32, per-source sample rates including 48/24 kHz, bounded queues and time alignment.

Automated tests do not request real microphone/system recording permission. Manual audio-device validation is still needed on each setup, particularly Bluetooth call-mode transitions, sleep/wake, device removal, long sessions, and disk exhaustion. Device changes stop and preserve recording; automatic recovery across device changes is not promised.

Other Apple Silicon models, smaller RAM configurations, alternate Whisper/MLX model variants and other macOS releases are not yet systematically validated. Source/model setup and signatures should be tested on a clean Mac before claiming general installation support.

To exercise the real local pipeline, build the app, configure models, generate a nonconfidential speech fixture with macOS `say`, import it and check completion with automatic naming enabled and disabled. Reopen the Library and verify raw/edit history. Never commit resulting media, transcripts or user settings.

## Optional isolated local pipeline test

After building and configuring installed local models, generate a public speech fixture (no playback):

```bash
mkdir -p .build/test-data .build/test-bins
say -v Samantha -o .build/test-data/synthetic.aiff "A synthetic discussion of the Revit API and local recording library. Original recordings must remain unchanged."
ffmpeg -nostdin -i .build/test-data/synthetic.aiff -c:a aac .build/test-data/synthetic.m4a
base=Sources/RecordingLibrary
swiftc -swift-version 5 -O -parse-as-library -module-cache-path .build/module-cache -target arm64-apple-macosx14.2 "$base/Localization.swift" "$base/Models.swift" "$base/Store.swift" "$base/Configuration.swift" "$base/Engine.swift" Tests/LocalPipelineChecks.swift -o .build/test-bins/local-pipeline -lsqlite3
.build/test-bins/local-pipeline "$PWD" "$PWD/.build/test-data/synthetic.m4a"
```

This exercises selected local model paths, Whisper-only completion, manual Qwen naming, the automatic pipeline, deduplication, persistence and immutable prior raw output in a temporary Library. It does not record microphone/system audio. Test outputs remain under ignored `.build/` and are not published.
