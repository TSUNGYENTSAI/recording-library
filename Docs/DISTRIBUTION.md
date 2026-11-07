# Distribution

This early preview supports building from source on Apple Silicon / macOS 14.2+.

`Scripts/build.sh` applies an ad-hoc local code signature. This is not a Developer ID identity and is not Apple notarization. Downloaded copies may be blocked by the recipient's default Gatekeeper settings. The initial public preview should be described as a source-build preview, not a notarized installer.

A future public binary release needs the publisher's Developer ID credentials, hardened-runtime/entitlement verification for microphone and system audio, signing of all embedded executables, notarization and ticket stapling. Never commit signing keys, passwords or provisioning credentials. Do not recommend disabling system security protections.

Models, Python runtime and FFmpeg are separate installations in this preview. A self-contained distribution requires reviewing all transitive redistribution licenses and validating the runtime on a clean Mac.
