# Try a fictional example

The everyday workflow starts with **Start recording**. Choose microphone, system audio, or both; stop and save when finished. With models configured, Whisper transcribes locally and optional Qwen suggests a title/category. Review the text, search, copy, or export it.

To try transcription without recording a real conversation, generate a fictional speech sample on your Mac:

```bash
python3 Scripts/generate-example-audio.py
# Optional second sample:
python3 Scripts/generate-example-audio.py --example personal-idea
```

The script uses your installed macOS `say` voice, writes an AIFF file under ignored `.build/examples/`, and does not play audio, start recording, run a model, or change your Library. Drag the generated file into the app or choose **Import**. Exact transcription and metadata vary; `example.json` describes illustrative results, not a model accuracy test. Qwen currently suggests Traditional Chinese titles, even with English controls. Your default voice affects pronunciation; choose an English voice in macOS settings if needed.

For the **recording-first** workflow, read the fictional text aloud after pressing **Start recording**, then **Stop and save**. A short permission/audio check is useful before recording your first meeting. Confirm the microphone/system level meters respond to the sources you selected.

| Sample | Illustrates | Search for |
| --- | --- | --- |
| [Product discussion](product-discussion/source.txt) | Headphone meeting → offline transcript → title/category | `offline`, `Whisper` |
| [Personal idea](personal-idea/source.txt) | A short voice note you can find later | `walk`, `voice note` |

The [workflow GIF](../Docs/Media/workflow.gif) is an **illustrated walkthrough with fictional data**, not a screen recording, live model output or a performance benchmark. Recording/transcription waits are shortened. No real meeting audio or transcripts are included.

繁體中文：日常使用從「開始錄音」開始，停止儲存後自動轉錄，再由選用的 Qwen 命名分類。上面的腳本只在本機產生虛構測試語音，不播放、不錄音，也不修改資料庫；可拖入 App 測試。JSON 的標題分類是示意，實際辨識結果可能不同。
