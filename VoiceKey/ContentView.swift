import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationStack {
            Form {
                Section("ChatGPT") {
                    HStack {
                        Text("Account")
                        Spacer()
                        Text(model.signedIn ? (model.accountEmail ?? "Signed in") : "Not signed in")
                            .foregroundStyle(.secondary)
                    }

                    if model.signedIn {
                        Button("Sign Out", role: .destructive) {
                            model.signOut()
                        }
                    } else {
                        Button("Sign in with ChatGPT") {
                            Task { await model.signIn() }
                        }
                    }
                }

                Section("Keyboard Service") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(model.serviceReady ? "Ready" : "Stopped")
                            .foregroundStyle(model.serviceReady ? Color.green : Color.secondary)
                    }

                    Text(model.statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if model.serviceReady {
                        Button("Stop Keyboard Service", role: .destructive) {
                            model.stopService()
                        }
                    } else {
                        Button("Start Keyboard Service") {
                            Task { await model.startService() }
                        }
                        .disabled(!model.signedIn)
                    }
                }

                Section("Skip App Switching") {
                    if model.pictureInPictureSupported {
                        PiPPreviewView(service: model.pictureInPictureService)
                            .frame(height: 150)
                            .listRowInsets(EdgeInsets())

                        HStack {
                            Text("Picture in Picture")
                            Spacer()
                            Text(model.pictureInPictureActive ? "Active" : "Off")
                                .foregroundStyle(
                                    model.pictureInPictureActive
                                        ? Color.green
                                        : Color.secondary
                                )
                        }

                        Text(
                            model.pictureInPictureActive
                                ? "VoiceKey can stay reachable while you use other apps. The microphone remains off until you tap Speak in the keyboard."
                                : "Enable this before leaving VoiceKey. iOS will show a small Picture in Picture window; you can tuck it against the screen edge."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                        if model.pictureInPictureActive {
                            Button("Turn Off Skip App Switching", role: .destructive) {
                                model.disableSkipAppSwitching()
                            }
                        } else {
                            Button("Enable Skip App Switching") {
                                Task { await model.enableSkipAppSwitching() }
                            }
                            .disabled(!model.signedIn)
                        }
                    } else {
                        Text("Picture in Picture is not supported on this device.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Setup") {
                    Text("1. Sign in with ChatGPT.")
                    Text("2. Start Keyboard Service.")
                    Text("3. Enable Skip App Switching and leave the VoiceKey Picture in Picture window active.")
                    Text("4. Go to Settings → General → Keyboard → Keyboards → Add New Keyboard → VoiceKey.")
                    Text("5. Enable Allow Full Access for VoiceKey.")
                    Text("6. In any text field, switch to VoiceKey with the globe key and tap Speak.")
                }

                Section("Privacy & limitations") {
                    Text("VoiceKey does not turn on the microphone just because the keyboard is visible. Recording starts only after you tap Speak and stops immediately when you tap Stop or the keyboard disappears.")
                    Text("Skip App Switching uses Apple's Picture in Picture mechanism to keep the VoiceKey app reachable while another app is in front.")
                    Text("If Picture in Picture is closed by you or by iOS, VoiceKey falls back to the older background-audio standby and may eventually need to be reopened.")
                    Text("The current ChatGPT/Codex transcription endpoint is undocumented and may change.")
                }

                if let error = model.lastError {
                    Section("Error") {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("VoiceKey")
        }
    }
}
