# whispr

A fully local [Wispr Flow](https://wisprflow.ai) clone for macOS. Hold **fn**, speak, release — clean, AI-formatted text appears at your cursor in any app. No audio, text, or context ever leaves your Mac.

See [PLAN.md](PLAN.md) for the architecture and milestone roadmap. **Status: M0–M8 complete** — the full core feature set:

- **Push-to-talk** (hold fn) · **hands-free** (double-tap fn, fn+Space, or click the Flow Bar; VAD auto-endpoints utterances while the session keeps listening) · Esc cancels · ⌘⌃V re-pastes last transcript · remappable keys
- **Local ASR**: Parakeet TDT 0.6B on the Neural Engine (near-instant), Apple SpeechAnalyzer fallback, WhisperKit large-v3 for 99 languages + auto-detect
- **Local AI cleanup** (Qwen 4B via MLX): fillers, self-corrections ("no wait, I mean…"), punctuation, lists; 4 cleanup levels; never answers your dictation; falls back to rules-only if slow/down
- **Context awareness** (Accessibility only — no screenshots): per-app tone styles (casual in Slack, formal in Mail), mid-sentence splicing, on-screen proper-noun spelling hints, code-context preservation, secure-field refusal
- **Dictionary**: custom vocabulary (starring, CSV import), replacement rules, spoken snippets, experimental auto-learning from your edits
- **Command mode** (hold Right ⌘): speak an instruction over selected text → rewritten in place; Transform Selection presets in the menu
- **History** (SQLite, local): search, audio playback, raw-transcript recovery, retention controls · **Insights**: WPM, streaks, per-app stats
- Flow Bar HUD (draggable, hideable), crash recovery, 20-min session cap, launch at login

## Build & run

Requires macOS 26+, Apple Silicon, Xcode Command Line Tools (full Xcode not needed), and [`uv`](https://docs.astral.sh/uv/) for the optional AI layer.

```sh
make run              # release build → whispr.app → codesign → open
./scripts/setup-llm.sh  # one-time: local AI model (~2.3 GB); optional but recommended
```

## One-time setup

1. **Signing identity** (so permissions survive rebuilds): Keychain Access → Certificate Assistant → Create a Certificate → name `whispr-dev`, type **Code Signing**. Trust it for code signing if asked. `make` picks it up automatically; without it, builds are ad-hoc signed and macOS re-asks for permissions after every rebuild.
2. **Permissions**: grant **Accessibility** when prompted (System Settings → Privacy & Security → Accessibility), then relaunch the app. **Microphone** is prompted on first dictation.
3. **Free up the fn key**: System Settings → Keyboard → "Press 🌐 key to" → **Do Nothing** (`defaults write com.apple.HIToolbox AppleFnUsageType -int 0`) and disable Apple Dictation's shortcut.

## Usage

Hold **fn** and talk; release to paste. Say punctuation ("comma", "new paragraph") or "press enter" at the end to auto-submit. Double-tap **fn** for hands-free; press fn again to stop. Hold **Right ⌘** over a selection and say "make this shorter" to rewrite it in place. Everything else lives in the menu bar: History, Insights, Dictionary, Settings.

Language: Settings → Dictation language (system default, fixed language, or Whisper auto-detect). Cleanup intensity: Settings → Cleanup level.

## Storage

Everything lives in `~/Library/Application Support/whispr/` (SQLite history + audio + the AI venv). Delete that folder and the app's UserDefaults (`defaults delete dev.local.whispr`) for a full reset.
