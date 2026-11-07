# Contributing

Please keep contributions focused on local recording reliability, original-result preservation, model setup, search and file management. Run `Scripts/test.sh` and `Scripts/build.sh` on an Apple Silicon Mac before submitting a change.

Use synthetic or explicitly public fixtures. Never commit a real meeting, transcript, Library database, local model path configuration, downloaded model, runtime, API key or signing credential. Keep media and model artifacts outside Git.

Bug reports should include macOS/chip, selected input/output devices, source mode and a synthetic reproduction where possible. Describe permission or format-change symptoms without attaching confidential audio. Setup diagnostics can contain local information; inspect and redact them before sharing.

Do not add automatic transcript rewriting. Raw results remain immutable, and edited versions must retain their source relationship.
