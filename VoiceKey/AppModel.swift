import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var signedIn: Bool
    @Published private(set) var accountEmail: String?
    @Published private(set) var serviceReady: Bool
    @Published private(set) var statusText = "Idle"
    @Published var lastError: String?

    private let auth: ChatGPTAuthManager
    private let audio = AudioService()
    private let transcriber = ChatGPTTranscriptionService()
    private var observerTokens: [UUID] = []
    private var activeRecordingURL: URL?
    private var expiryTask: Task<Void, Never>?

    init() {
        let auth = ChatGPTAuthManager()
        self.auth = auth
        self.signedIn = auth.isSignedIn
        self.accountEmail = auth.credential?.email
        self.serviceReady = SharedBridge.serviceReady

        // A fresh process must not claim readiness until its audio session is armed.
        SharedBridge.serviceReady = false
        self.serviceReady = false

        observerTokens.append(
            DarwinBus.shared.observe(SharedBridge.Event.startRecording) { [weak self] in
                Task { @MainActor in self?.startRecordingFromKeyboard() }
            }
        )
        observerTokens.append(
            DarwinBus.shared.observe(SharedBridge.Event.stopRecording) { [weak self] in
                Task { @MainActor in await self?.finishRecordingFromKeyboard() }
            }
        )
    }

    deinit {
        expiryTask?.cancel()
        for token in observerTokens {
            DarwinBus.shared.remove(token)
        }
    }

    func signIn() async {
        lastError = nil
        do {
            try await auth.signIn()
            signedIn = true
            accountEmail = auth.credential?.email
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() {
        stopService()
        auth.signOut()
        signedIn = false
        accountEmail = nil
    }

    func startService() async {
        lastError = nil
        guard signedIn else {
            lastError = "Sign in with ChatGPT first."
            return
        }

        let granted = await AudioService.requestPermission()
        guard granted else {
            lastError = "Microphone permission is required."
            return
        }

        do {
            try audio.arm()
            serviceReady = true
            statusText = "Ready for keyboard dictation"
            SharedBridge.lastError = nil
            SharedBridge.status = .idle
            SharedBridge.serviceReady = true
            resetExpiryTimer()
        } catch {
            lastError = error.localizedDescription
            SharedBridge.publishError(error.localizedDescription)
        }
    }

    func stopService() {
        expiryTask?.cancel()
        expiryTask = nil
        _ = audio.endCapture()
        audio.disarm()
        serviceReady = false
        statusText = "Idle"
        SharedBridge.serviceReady = false
        SharedBridge.status = .idle
    }

    private func startRecordingFromKeyboard() {
        guard serviceReady, audio.isArmed else {
            SharedBridge.publishError("Open VoiceKey and start the keyboard service first.")
            return
        }
        guard SharedBridge.status != .recording else { return }

        do {
            SharedBridge.transcribedText = nil
            SharedBridge.lastError = nil
            activeRecordingURL = try audio.beginCapture()
            SharedBridge.status = .recording
            statusText = "Recording…"
            resetExpiryTimer()
        } catch {
            SharedBridge.publishError(error.localizedDescription)
            lastError = error.localizedDescription
        }
    }

    private func finishRecordingFromKeyboard() async {
        guard SharedBridge.status == .recording else { return }
        guard let url = audio.endCapture() ?? activeRecordingURL else {
            SharedBridge.publishError("No recording was captured.")
            return
        }
        activeRecordingURL = nil

        SharedBridge.status = .transcribing
        statusText = "Transcribing…"

        defer {
            try? FileManager.default.removeItem(at: url)
            resetExpiryTimer()
        }

        do {
            let credential = try await auth.validCredential()
            let text = try await transcriber.transcribe(
                audioURL: url,
                credential: credential,
                language: "zh"
            )
            SharedBridge.publishTranscription(text)
            statusText = "Ready for keyboard dictation"
            signedIn = true
            accountEmail = credential.email
        } catch {
            let message = error.localizedDescription
            SharedBridge.publishError(message)
            lastError = message
            statusText = "Transcription failed"
        }
    }

    private func resetExpiryTimer() {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard !Task.isCancelled else { return }
            guard SharedBridge.status != .recording else { return }
            self?.stopService()
        }
    }
}
