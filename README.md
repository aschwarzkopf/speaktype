# SpeakType

<div align="center">

![SpeakType Icon](speaktype/Assets.xcassets/AppIcon.appiconset/icon_256x256.png)

**Fast, Offline Voice-to-Text for macOS**

![SpeakType app screenshot](image.png)
[![Download](https://img.shields.io/badge/Download-SpeakType.dmg-blueviolet?logo=apple&logoColor=white)](https://github.com/karansinghgit/speaktype/releases/latest)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2014.0+-blue?logo=apple)](https://www.apple.com/macos/)
[![License](https://img.shields.io/badge/License-MIT-red)](LICENSE)

*Press a hotkey, speak, and instantly paste text anywhere on your Mac.*

</div>

---

## What is SpeakType?

SpeakType is a **privacy-first, offline voice dictation tool** for macOS. Unlike online dictation services, the core dictation pipeline runs **100% locally** using OpenAI's Whisper AI model via [WhisperKit](https://github.com/argmaxinc/WhisperKit). Support for Parakeet coming soon!

- **Privacy First** - Whisper runs locally; nothing leaves your Mac unless you explicitly opt into Cloud cleanup
- **Lightning Fast** - Optimized for Apple Silicon
- **Works Everywhere** - Any app, any text field
- **Optional Cleanup** - Remove filler words and fix punctuation via on-device Apple Intelligence (free) or Anthropic Claude (BYOK)
- **Open Source** - Audit every line of code yourself

---

## Installation

### Requirements

- macOS 14.0+ (Sonoma or newer)
- Apple Silicon (M1+) recommended
- 2GB available storage (for AI models)
- macOS 26+ with Apple Intelligence enabled — optional, only required for the on-device "Local" cleanup mode

### Download

**[Download Latest Release](https://github.com/karansinghgit/speaktype/releases/latest)**

1. Download `SpeakType.dmg`
2. Drag **SpeakType** to **Applications**
3. Grant **Microphone** and **Accessibility** permissions when prompted
4. Set **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing** so macOS doesn't open the emoji picker on Fn press
5. Download an AI model from Settings → AI Models

Press `fn` to start dictating.

### Build from Source

```bash
git clone https://github.com/karansinghgit/speaktype.git
cd speaktype
make build && make run
```

---

## Usage

1. Press hotkey (`fn` by default)
2. Speak your text
3. Release hotkey
4. Text appears!

**Tips:**
- Speak naturally - Whisper handles accents well
- Say punctuation: "comma", "period", "question mark"
- Best results with 3-10 second clips

---

## Development

```bash
make setup-signing  # One-time: create stable "SpeakType Dev" cert in your Keychain
make build          # Build debug
make run            # Run app
make clean          # Clean build
make test           # Run tests
make dmg            # Create DMG installer
```

**Use `make` for local dev — not raw `xcodebuild`.** The `make` targets
pass signing flags that build with a stable self-signed identity, so
TCC grants (Accessibility, Microphone) survive rebuilds. Plain
`xcodebuild` falls back to ad-hoc signing, which changes the binary's
code-directory hash on every build and silently invalidates
permissions — you'll see "accessibility not granted" warnings on the
next run even though nothing changed. Run `make setup-signing` once
to create the cert.

### Current Issues

⚠️ When loading a model for the first time / switching to another model, there is a startup delay of 30-60 seconds. 

So the first transcription will appear ultra slow, but it will go back to instantaneous dictation right after it's warmed up. 

### Project Structure

```
speaktype/
├── App/           # Entry point
├── Views/         # SwiftUI interface
├── Models/        # Data models
├── Services/      # Core functionality
├── Controllers/   # Window management
└── Resources/     # Assets & config
```

### Tech Stack

- **Swift 5.9+** / SwiftUI + AppKit
- **[WhisperKit](https://github.com/argmaxinc/WhisperKit)** - Local Whisper inference (Neural Engine, GPU-accelerated)
- **[KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts)** - Global hotkeys
- **AVFoundation** - Audio capture (`AVCaptureSession` with forced Float32 output for level-meter consistency across devices)
- **CoreAudio** - System default-input device tracking via `kAudioHardwarePropertyDefaultInputDevice` listener (no AVFoundation equivalent on macOS)
- **FoundationModels** *(macOS 26+, optional)* - On-device Apple Intelligence for "Local" transcript cleanup
- **Anthropic Claude API** *(optional, BYOK)* - Cloud transcript cleanup; key stored in macOS Keychain
- **NDJSON file persistence** - History stored at `~/Library/Application Support/SpeakType/history.ndjson` (survives SIGKILL via atomic rewrites)

---

## Contributing

1. Fork & clone
2. Create a branch: `git checkout -b feature/my-feature`
3. Make changes and run `make lint`
4. Submit a PR

---

## License

MIT License - see [LICENSE](LICENSE) for details.

---

## Credits

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax
- [OpenAI Whisper](https://github.com/openai/whisper)

---

<div align="center">

**Made with ❤️ for developers**

*Privacy-first • Open Source *

</div>
