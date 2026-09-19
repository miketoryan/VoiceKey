# VoiceKey

VoiceKey is an experimental, personal-use iPhone voice keyboard focused on one job: turn speech into text with ChatGPT/Codex transcription and insert the result into any text field.

## Architecture

- **VoiceKey app** — ChatGPT OAuth, microphone permission, Picture in Picture quick-start service, audio capture, and transcription.
- **VoiceKeyKeyboard extension** — Speak/Stop UI, service status, and text insertion.
- **Picture in Picture quick start** — keeps the containing app reachable while another app is in front so the keyboard can request recording without an app switch. The microphone stays off until the user taps **Speak**.
- **Localhost bridge** — the keyboard talks to the app through `127.0.0.1:14556`, avoiding the App Group entitlement that is unavailable to free Apple developer accounts.
- **ChatGPT/Codex transcription** — currently targets `https://chatgpt.com/backend-api/transcribe`.

## Important limitation

The ChatGPT/Codex transcription endpoint used by this project is an undocumented backend endpoint. It can change or stop working without notice. VoiceKey is therefore experimental and should eventually include a fallback transcription engine.

The containing app records on behalf of the keyboard because iOS keyboard extensions cannot access the microphone directly. Recordings have no fixed duration limit and are uploaded through a temporary multipart file instead of being copied fully into memory.

VoiceKey now has a **Skip App Switching** mode based on Picture in Picture. Enable it while VoiceKey is in the foreground, then leave the Picture in Picture window active while using other apps. The keyboard can keep talking to the containing app through the localhost bridge without visibly opening VoiceKey first. The microphone is not armed by keyboard heartbeats: it turns on only after **Speak** is tapped and is turned off immediately after **Stop** before transcription continues.

While visible, the keyboard sends a heartbeat every 2 seconds. If the keyboard disappears during an active recording, VoiceKey finishes the capture after a 10-second grace period. If Picture in Picture is closed or becomes unavailable, VoiceKey falls back to the older silent-background-audio standby. iOS may eventually suspend that fallback, in which case VoiceKey must be reopened. Picture in Picture behavior must still be validated on a real iPhone because the CI simulator cannot reproduce all background lifecycle behavior.

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

1. Open VoiceKey, sign in, and tap **Start Keyboard Service**.
2. Tap **Enable Skip App Switching**. Keep the resulting Picture in Picture window active; it may be tucked against the edge of the screen.
3. In Settings → General → Keyboard → Keyboards, add VoiceKey and enable **Allow Full Access**. Localhost communication does not work without Full Access.
4. Switch to VoiceKey from the globe key in any app.
5. A filled microphone means Skip App Switching is active. Tap **Speak** to turn on the microphone and start recording.
6. Tap **Stop** to close the microphone and begin transcription. The result is inserted automatically only while the same keyboard session remains active; otherwise VoiceKey asks you to tap **Insert Result** so stale text is not inserted into the wrong field.
7. If the Picture in Picture window is closed and VoiceKey later becomes unreachable, reopen VoiceKey and enable Skip App Switching again.

## Status

v0.1 experimental — the end-to-end path is buildable and the Picture in Picture quick-start architecture is now ready for real-iPhone validation. Next steps include device lifecycle testing, vocabulary correction, VAD, streaming, and fallback ASR.

## Acknowledgements

The design was informed by the MIT-licensed projects:
- `A3Boy/codex-voice-input`
- `n0an/VivaDicta`

See `NOTICE.md` and `LICENSE`.
