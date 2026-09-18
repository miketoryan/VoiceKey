# VoiceKey

VoiceKey is an experimental, personal-use iPhone voice keyboard focused on one job: turn speech into text with ChatGPT/Codex transcription and insert the result into any text field.

## Architecture

- **VoiceKey app** — ChatGPT OAuth, microphone permission, background audio session, transcription.
- **VoiceKeyKeyboard extension** — microphone/start/stop UI and text insertion.
- **Localhost bridge** — the keyboard talks to the app through `127.0.0.1:14556`, avoiding the App Group entitlement that is unavailable to free Apple developer accounts.
- **ChatGPT/Codex transcription** — currently targets `https://chatgpt.com/backend-api/transcribe`.

## Important limitation

The ChatGPT/Codex transcription endpoint used by this project is an undocumented backend endpoint. It can change or stop working without notice. VoiceKey is therefore experimental and should eventually include a fallback transcription engine.

The containing app records on behalf of the keyboard because iOS keyboard extensions cannot access the microphone directly. Recordings have no fixed duration limit and are uploaded through a temporary multipart file instead of being copied fully into memory. While visible, the keyboard sends a heartbeat every 2 seconds. When those heartbeats stop because the keyboard was dismissed, switched, or terminated, the app closes the microphone after a 10-second grace period.

After the microphone closes, VoiceKey plays a silent background audio loop to keep its localhost bridge available. Switching back to the VoiceKey keyboard automatically reactivates the microphone. This personal-use workaround may consume a small amount of battery and may appear as audio activity in iOS. The service normally needs to be started only once after installation, a phone restart, a force-quit, or if iOS terminates the app.

## Build

The repository's `Build` GitHub Actions workflow selects Xcode 26.3, validates a simulator build, archives an unsigned iPhone build, and uploads `VoiceKey-unsigned.ipa`. This route is intended for an older Mac that cannot run Xcode 26.

1. Push a commit to `main`, or run the `Build` workflow manually from the GitHub Actions page.
2. Open the completed workflow run and download the `VoiceKey-unsigned` artifact.
3. Extract the artifact ZIP to get `VoiceKey-unsigned.ipa`.
4. Open AltServer on the Mac, hold Option while opening its menu, choose **Sideload .ipa…**, and sign the IPA with a free Apple ID.
5. Use the same Apple ID and bundle IDs when refreshing or replacing the app.
6. A free signature lasts 7 days. Reinstall the IPA with AltServer before it expires.

For a local Xcode build, install Xcode 26+ and XcodeGen, run `xcodegen generate`, and select a signing team for both targets. VoiceKey intentionally has no App Group entitlement.

## Usage

1. Open VoiceKey once and tap **Start Keyboard Service**. It then reactivates automatically whenever the VoiceKey keyboard appears.
2. In Settings → General → Keyboard → Keyboards, add VoiceKey and enable **Allow Full Access**. Localhost communication does not work without Full Access.
3. Switch to VoiceKey from the globe key in any app.
4. Tap the microphone to start.
5. Tap stop to transcribe. The result is inserted automatically only while the same keyboard session remains active; otherwise VoiceKey asks you to tap **Insert Result** so stale text is not inserted into the wrong field.
6. Use the globe key to return to Apple Keyboard. The microphone closes about 10 seconds later while the silent standby session remains available for automatic reactivation.

## Status

v0.1 — first buildable prototype. The first goal is to validate the end-to-end path on a real iPhone before adding polish, vocabulary correction, VAD, streaming, and fallback ASR.

## Acknowledgements

The design was informed by the MIT-licensed projects:
- `A3Boy/codex-voice-input`
- `n0an/VivaDicta`

See `NOTICE.md` and `LICENSE`.
