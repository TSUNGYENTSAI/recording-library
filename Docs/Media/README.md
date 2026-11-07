# Illustrated walkthrough

`workflow.gif` and `workflow-poster.png` are generated illustrations using fictional text. They are not recordings of the running app or actual model output. The demo starts with the recording button; audio/video import is a secondary entry point. Waiting times are shortened.

Rebuild on macOS from the repository root:

```bash
swift -module-cache-path .build/module-cache Scripts/render-demo.swift "$PWD"
```

The renderer uses AppKit/ImageIO offscreen. It does not open a window, record audio, access a user Library, or run/download models. Example source text and illustrative expected metadata live under `Examples/`. Category labels are English in this demo; the example Qwen title is Traditional Chinese, matching the current naming prompt.
