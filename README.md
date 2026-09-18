# VoiceKey

VoiceKey is an experimental iPhone voice keyboard focused on one job: turn speech into text with ChatGPT/Codex transcription and insert the result into any text field.

## Architecture

- **VoiceKey app** — ChatGPT OAuth, microphone permission, background audio session, transcription.
- **VoiceKeyKeyboard extension** — microphone/start/stop UI and text insertion.
- **App Group + Darwin notifications** — communication between the app and keyboard.
- **ChatGPT/Codex transcription** — currently targets `https://chatgpt.com/backend-api/transcribe`.

## Important limitation

The ChatGPT/Codex transcription endpoint used by this project is an undocumented backend endpoint. It can change or stop working without notice. VoiceKey is therefore experimental and should eventually include a fallback transcription engine.

## Build

1. Install Xcode 26+.
2. Install XcodeGen: `brew install xcodegen`.
3. Run `xcodegen generate`.
4. Open `VoiceKey.xcodeproj`.
5. Select your Apple Developer Team for both targets.
6. Ensure both targets use the App Group `group.com.miketoryan.VoiceKey`.
7. Run the main app on your iPhone.
8. Sign in with ChatGPT, grant microphone access, then enable the keyboard in iOS Settings.

## Usage

1. Open VoiceKey once and tap **Start Keyboard Service**.
2. Switch to VoiceKey from the globe key in any app.
3. Tap the microphone to start.
4. Tap stop to transcribe and insert.
5. Use the globe key to return to Apple Keyboard.

## Status

v0.1 — first buildable prototype. The first goal is to validate the end-to-end path on a real iPhone before adding polish, vocabulary correction, VAD, streaming, and fallback ASR.

## Acknowledgements

The design was informed by the MIT-licensed projects:
- `A3Boy/codex-voice-input`
- `n0an/VivaDicta`

See `NOTICE.md` and `LICENSE`.
