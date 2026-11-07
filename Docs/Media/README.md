# Native interface walkthroughs

- `workflow.gif` / `workflow-poster.png`: English controls, captions, fictional transcript, titles and edit notes.
- `workflow-zh-TW.gif` / `workflow-poster-zh-TW.png`: Traditional Chinese controls, captions and fictional content.

Both use the **production SwiftUI/AppKit view tree**, including `LibraryView`, `CaptureControls`, the transcript viewer and Trash. No app layout, controls or transcript UI are redrawn by the compositor. Captions are placed above the captured view; a disclosure remains below it.

The English fixture uses translated illustrative titles for an English-only walkthrough; the current Qwen naming prompt still produces Traditional Chinese titles. This demo does not add English title generation to the app.

The demo shows Start recording → Stop and save → incremental transcript preview → optional title/category → completed → edit/copy/export controls → search → Trash → restore / Keep forever. It demonstrates the UI with fictional test data; recording and inference states are replayed and waits shortened. It is not a live recording, model output or performance benchmark. The copy/export controls are shown; the script does not overwrite the clipboard or open a Save dialog.

## Reproduce on macOS

From the repository root, with Command Line Tools and FFmpeg installed:

```bash
./Scripts/capture-workflow.sh
```

The script builds a separate capture executable under a new ignored `.build/workflow.XXXXXX/` directory. It compiles the unchanged production view bodies, omitting the production entry point and adding only an extension to initialize selection/search/filter state. Production app sources and the installed app are not modified.

An injected `AudioRecordingSession` writes synthetic silence to its own temporary CAF; microphone permission is injected and no microphone or system tap is opened. Local FFprobe/FFmpeg verify/archive only this generated file. No model is loaded or downloaded. An isolated SQLite Library supplies fictional raw text, an edit revision and naming metadata; real storage methods perform Trash/restore. A background, mouse-disabled native window lays out the views, and AppKit captures only that view tree. It never captures the desktop or other apps. Temporary capture bundles use a separate bundle ID and preferences.

`render-demo.swift` composites the captured images and explanatory text into GIFs with ImageIO. The generated raw frames and fixture database stay under ignored `.build/`; only the captioned GIFs, posters and fixture code are published. Never substitute personal Library data.
