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
    private var activeRequestID: String?
    private var heartbeatTask: Task<Void, Never>?
    private var keyboardExitTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?

    init() {
        let auth = ChatGPTAuthManager()
        self.auth = auth
        self.signedIn = auth.isSignedIn
        self.accountEmail = auth.credential?.email
        self.serviceReady = SharedBridge.serviceReady

        // A fresh process must not claim readiness until its audio session is armed.
        SharedBridge.invalidateService()
        self.serviceReady = false

        observerTokens.append(
            DarwinBus.shared.observe(SharedBridge.Event.startRecording) { [weak self] in
                Task { @MainActor in self?.startRecordingFromKeyboard() }
            }
        )
        observerTokens.append(
            DarwinBus.shared.observe(SharedBridge.Event.stopRecording) { [weak self] in
                Task { @MainActor in
                    self?.beginFinishingRecording(
                        expectedRequestID: SharedBridge.requestID,
                        deactivateMicrophoneAfterCapture: false
                    )
                }
            }
        )
        observerTokens.append(
            DarwinBus.shared.observe(SharedBridge.Event.keyboardActivated) { [weak self] in
                Task { @MainActor in self?.cancelKeyboardExitShutdown() }
            }
        )
        observerTokens.append(
            DarwinBus.shared.observe(SharedBridge.Event.keyboardDeactivated) { [weak self] in
                Task { @MainActor in self?.scheduleKeyboardExitShutdown() }
            }
        )
    }

    deinit {
        heartbeatTask?.cancel()
        keyboardExitTask?.cancel()
        transcriptionTask?.cancel()
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
            transcriptionTask?.cancel()
            transcriptionTask = nil
            keyboardExitTask?.cancel()
            keyboardExitTask = nil
            try audio.arm()
            serviceReady = true
            statusText = "Ready for keyboard dictation"
            SharedBridge.lastError = nil
            SharedBridge.clearResult()
            SharedBridge.requestID = nil
            SharedBridge.status = .idle
            SharedBridge.touchHeartbeat()
            SharedBridge.serviceReady = true
            startHeartbeat()
        } catch {
            lastError = error.localizedDescription
            SharedBridge.publishError(error.localizedDescription)
        }
    }

    func stopService() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        keyboardExitTask?.cancel()
        keyboardExitTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil

        if let url = audio.endCapture() ?? activeRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeRecordingURL = nil
        activeRequestID = nil
        audio.disarm()
        serviceReady = false
        statusText = "Idle"
        SharedBridge.invalidateService()
    }

    private func startRecordingFromKeyboard() {
        guard serviceReady, audio.isRunning, SharedBridge.isServiceAvailable else {
            SharedBridge.publishError(
                "Open VoiceKey and start the keyboard service first.",
                requestID: SharedBridge.requestID
            )
            return
        }
        guard SharedBridge.status == .starting,
              let requestID = SharedBridge.requestID else { return }
        guard SharedBridge.status != .recording else { return }

        do {
            SharedBridge.transcribedText = nil
            SharedBridge.lastError = nil
            activeRecordingURL = try audio.beginCapture()
            activeRequestID = requestID
            SharedBridge.status = .recording
            statusText = "Recording…"
        } catch {
            SharedBridge.publishError(error.localizedDescription, requestID: requestID)
            lastError = error.localizedDescription
        }
    }

    private func finishRecordingFromKeyboard(
        expectedRequestID: String?,
        deactivateMicrophoneAfterCapture: Bool
    ) async {
        guard SharedBridge.status == .recording else { return }
        guard let requestID = activeRequestID,
              expectedRequestID == nil || expectedRequestID == requestID else { return }

        let capturedURL = audio.endCapture() ?? activeRecordingURL
        activeRecordingURL = nil
        activeRequestID = nil

        guard let url = capturedURL else {
            SharedBridge.publishError("No recording was captured.", requestID: requestID)
            return
        }

        SharedBridge.status = .transcribing
        statusText = "Transcribing…"

        if deactivateMicrophoneAfterCapture {
            deactivateMicrophonePreservingResponse()
        }

        defer {
            try? FileManager.default.removeItem(at: url)
        }

        do {
            let credential = try await auth.validCredential()
            let text = try await transcriber.transcribe(
                audioURL: url,
                credential: credential,
                language: "zh"
            )
            SharedBridge.publishTranscription(text, requestID: requestID)
            statusText = serviceReady
                ? "Ready for keyboard dictation"
                : "Keyboard closed. Transcription is ready."
            signedIn = true
            accountEmail = credential.email
        } catch {
            guard !Task.isCancelled else { return }
            let message = error.localizedDescription
            SharedBridge.publishError(message, requestID: requestID)
            lastError = message
            statusText = "Transcription failed"
        }
    }

    private func beginFinishingRecording(
        expectedRequestID: String?,
        deactivateMicrophoneAfterCapture: Bool
    ) {
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            await self?.finishRecordingFromKeyboard(
                expectedRequestID: expectedRequestID,
                deactivateMicrophoneAfterCapture: deactivateMicrophoneAfterCapture
            )
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard let self, self.serviceReady else { return }
                guard self.audio.isRunning else {
                    self.stopService()
                    return
                }
                SharedBridge.touchHeartbeat()
            }
        }
    }

    private func cancelKeyboardExitShutdown() {
        keyboardExitTask?.cancel()
        keyboardExitTask = nil
    }

    private func scheduleKeyboardExitShutdown() {
        keyboardExitTask?.cancel()
        keyboardExitTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            guard let self, !SharedBridge.keyboardActive else { return }

            if SharedBridge.status == .recording {
                self.beginFinishingRecording(
                    expectedRequestID: self.activeRequestID,
                    deactivateMicrophoneAfterCapture: true
                )
            } else {
                self.deactivateMicrophonePreservingResponse()
            }
        }
    }

    private func deactivateMicrophonePreservingResponse() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        audio.disarm()
        serviceReady = false
        SharedBridge.heartbeatAt = nil
        SharedBridge.serviceReady = false

        switch SharedBridge.status {
        case .starting, .idle:
            SharedBridge.requestID = nil
            SharedBridge.status = .idle
        case .recording:
            break
        case .transcribing:
            statusText = "Keyboard closed. Finishing transcription…"
        case .completed:
            statusText = "Keyboard closed. Transcription is ready."
        case .error:
            statusText = "Keyboard service stopped"
        }
    }
}
