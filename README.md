# whispr

A fully local [Wispr Flow](https://wisprflow.ai) clone for macOS. Hold **fn**, speak, release — clean text appears at your cursor in any app. No audio, text, or context ever leaves your Mac.

See [PLAN.md](PLAN.md) for the full architecture and milestone roadmap. Current status: **M1 walking skeleton** — fn push-to-talk, on-device transcription via Apple SpeechAnalyzer, deterministic cleanup rules, clipboard-paste insertion with clipboard restore, Flow-Bar HUD, menu bar app.

## Build & run

Requires macOS 26+, Apple Silicon, and Xcode Command Line Tools (full Xcode not needed).

```sh
make run        # release build → whispr.app → codesign → open
```

## One-time setup

1. **Permissions** (whispr prompts on first launch/use):
   - *Accessibility* — for the fn hotkey and paste keystroke. System Settings → Privacy & Security → Accessibility → enable whispr, then relaunch the app.
   - *Microphone* — prompted on your first dictation.
2. **Free up the fn key:** System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing** (or `defaults write com.apple.HIToolbox AppleFnUsageType -int 0`), and disable the Apple Dictation shortcut on the same screen. Otherwise macOS pops emoji/dictation on every fn press — this is enforced at a level apps cannot intercept.
3. **Stable signing (recommended):** ad-hoc-signed rebuilds reset the permission grants every time. Create a self-signed code-signing certificate named `whispr-dev` (Keychain Access → Certificate Assistant → Create a Certificate → Code Signing); `make` picks it up automatically and grants then survive rebuilds.

## Usage

- **Hold fn** and speak; release to transcribe and paste. First dictation may pause briefly while the system speech model downloads.
- **Esc** while recording cancels.
- Menu bar icon → enable/disable, paste last transcript, sounds, quit.
- Dictation language: defaults to your system locale; override with
  `defaults write dev.local.whispr whispr.locale en-US` (any SpeechTranscriber-supported locale).
