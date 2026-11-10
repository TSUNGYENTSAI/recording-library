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

## 0.9.1 recording synchronization recovery

Regression fixtures cover a 48 kHz aggregate delivering equal-sized mic/tap buffers while the tap still advertises 24 kHz. The mixer resolves delivery rate from actual callback frame counts relative to a stream on the aggregate clock; it keeps native per-stream conversion when frame counts instead match their advertised durations. A ten-second shared-clock fixture verifies output duration and both source frequencies without FIFO correction.

Persistent FIFO timing disagreement is now recoverable. The microphone/first stream is the reference: a lagging secondary source is padded with silence; an overlong secondary queue is interpolated onto the reference interval. Corrections keep buffers bounded and may affect sound/pitch during recovery. They produce a nonfatal recording notice and audit counters rather than stopping. Tail differences are padded at stop. This does not guarantee uninterrupted recording for device disconnection, actual PCM format changes or disk/write failures.

Synthetic tests cover continuing through sustained mismatch and a lagging source, plus a session warning that leaves the capture controller recording. No physical microphone or system recording starts in these tests. The next live Bluetooth/meeting session must verify the observed callback sizes and listening quality on that hardware. `capture-audit.json` now includes initial callback frames, effective input rates, corrected-clock stream count, maximum skew, resampling and silence-padding counts; it contains no transcript/audio samples.
