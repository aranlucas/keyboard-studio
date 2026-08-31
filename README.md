# Keyboard Studio

Keyboard Studio is a native macOS SwiftUI configurator and Codex status deck for SayoDevice O2L keyboards.

## Open the app

Open the Xcode project and run the `KeyboardStudio` target with a supported keyboard connected. The app stages edits, verifies device responses, and writes changes only when you choose **Save to keyboard**.

The app also includes backup/restore, lighting and macro controls, gesture profiles, clipboard utilities, and Codex status actions. Device scripts run on the keyboard; the app does not execute shell scripts.

## Build and verify

```bash
swift build
swift test
```

The repository also contains `sayo-probe` and `protocol-check` command-line tools for read-only device and protocol checks. See the Xcode project for the complete app target configuration.
