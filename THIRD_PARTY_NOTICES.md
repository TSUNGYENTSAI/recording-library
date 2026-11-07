# Third-party components

Recording Library application and wrapper code: MIT, see LICENSE.

- WhisperKit / Argmax OSS Swift: MIT, copyright Argmax, Inc. The worker pins commit `9f99b5cb6a907730543823ad271b82532782a899`. License included in `Docs/WhisperKit-LICENSE`. https://github.com/argmaxinc/argmax-oss-swift
- MLX and MLX-LM: MIT, copyright Apple Inc. Installed separately by the explicit setup step. https://github.com/ml-explore/mlx and https://github.com/ml-explore/mlx-lm
- Whisper Core ML conversion: see `Scripts/models.lock.json` and the model repository's license. https://huggingface.co/argmaxinc/whisperkit-coreml
- OpenAI Whisper tokenizer/model: Apache-2.0 as identified in the pinned model card. https://huggingface.co/openai/whisper-large-v3
- Qwen3-1.7B and the recommended MLX quantization: Apache-2.0. https://huggingface.co/Qwen/Qwen3-1.7B and https://huggingface.co/mlx-community/Qwen3-1.7B-4bit
- FFmpeg/FFprobe: external prerequisites, not redistributed in this repository or app bundle. Their license depends on the installation's build options. https://ffmpeg.org/legal.html
- SwiftPM and Python transitive dependencies retain their respective licenses; inspect the pinned dependency manifests before redistributing a self-contained binary/runtime distribution.

No model weights, Python runtime, private audio, or transcription results are distributed in this repository. Setup downloads models and packages from their original sources and preserves upstream license files. Selecting another model does not change its upstream license.

The project is independent of MacWhisper. Existing compatible model files can be selected or reused in place; no MacWhisper application code is included.
