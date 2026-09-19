import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var signedIn: Bool
    @Published private(set) var accountEmail: String?
    @Published private(set) var serviceReady = false
    @Published private(set) var statusText = "Idle"
    @Published private(set) var pictureInPictureActive = false
    @Published private(set) var pictureInPictureSupported: Bool
    @Published var lastError: String?

    let pictureInPictureService: PictureInPictureService

    private let auth: ChatGPTAuthManager
    private let audio = AudioService()
    private let transcriber = ChatGPTTranscriptionService()
    private let localBridge = LocalBridgeServer()
    private let serverID = UUID().uuidString

    private var stateRevision: UInt64 = 0
    private var activeRecordingURL: URL?
    private var activeRequestID: String?
    private var bridgeStatus: BridgeStatus = .idle
    private var responseText: String?
    private var resultCreatedAt: Date?
    private var bridgeError: String?
    private var lastKeyboardHeartbeat: Date?
    private var keyboardHasConnected = false
    private var keyboardMonitorTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?

    init() {
        let auth = ChatGPTAuthManager()
        let pictureInPictureService = PictureInPictureService()

        self.auth = auth
        self.pictureInPictureService = pictureInPictureService
        self.pictureInPictureSupported = pictureInPictureService.isSupported
        self.signedIn = auth.isSignedIn
        self.accountEmail = auth.credential?.email

        pictureInPictureService.onActiveChanged = { [weak self] active in
            self?.handlePictureInPictureStateChanged(active)
        }
        pictureInPictureService.onError = { [weak self] message in
            self?.lastError = message
        }

        do {
            try localBridge.start { [weak self] request in
                guard let self else {
                    return BridgeState.unavailable("VoiceKey is not running.")
                }
                return await self.handleBridgeRequest(request)
            }
        } catch {
            lastError = error.localizedDescription
            statusText = "Local keyboard connection failed"
        }
    }

    deinit {
        keyboardMonitorTask?.cancel()
        transcriptionTask?.cancel()
        localBridge.stop()
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
            keyboardMonitorTask?.cancel()
            keyboardMonitorTask = nil

            try prepareStandbyAudio()
            serviceReady = true
            statusText = pictureInPictureActive
                ? "Skip App Switching is ready"
                : "Waiting for VoiceKey keyboard"
            activeRecordingURL = nil
            activeRequestID = nil
            bridgeStatus = .idle
            clearResult()
            lastKeyboardHeartbeat = nil
            keyboardHasConnected = false
            markStateChanged()
        } catch {
            publishError(error.localizedDescription)
        }
    }

    func stopService() {
        keyboardMonitorTask?.cancel()
        keyboardMonitorTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil

        pictureInPictureService.stop()

        if let url = audio.endCapture() ?? activeRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        activeRecordingURL = nil
        activeRequestID = nil
        audio.disarm()
        serviceReady = false
        statusText = "Idle"
        bridgeStatus = .idle
        clearResult()
        lastKeyboardHeartbeat = nil
        keyboardHasConnected = false
        markStateChanged()
    }

    func enableSkipAppSwitching() async {
        lastError = nil

        if !serviceReady {
            await startService()
            guard serviceReady else { return }
        }

        do {
            try audio.enterPictureInPictureStandby()
            statusText = "Starting Skip App Switching…"
            markStateChanged()
            try await pictureInPictureService.start()
        } catch {
            lastError = error.localizedDescription
            statusText = "Skip App Switching could not start"
            try? audio.enterStandby()
            markStateChanged()
        }
    }

    func disableSkipAppSwitching() {
        pictureInPictureService.stop()
    }

    private func handlePictureInPictureStateChanged(_ active: Bool) {
        pictureInPictureActive = active

        guard serviceReady else {
            markStateChanged()
            return
        }

        if bridgeStatus != .recording && bridgeStatus != .starting {
            do {
                try prepareStandbyAudio()
            } catch {
                lastError = error.localizedDescription
            }
        }

        statusText = active
            ? "Skip App Switching is ready"
            : "Waiting for VoiceKey keyboard"
        markStateChanged()
    }

    private func handleBridgeRequest(_ request: BridgeRequest) async -> BridgeState {
        switch request.action {
        case .state:
            break

        case .heartbeat:
            noteKeyboardHeartbeat()

        case .startRecording:
            noteKeyboardHeartbeat()
            startRecordingFromKeyboard(requestID: request.requestID)

        case .stopRecording:
            noteKeyboardHeartbeat()
            beginFinishingRecording(
                expectedRequestID: request.requestID,
                deactivateMicrophoneAfterCapture: true
            )

        case .acknowledgeResult:
            acknowledgeResult(requestID: request.requestID)
        }

        return currentBridgeState()
    }

    private func noteKeyboardHeartbeat() {
        guard serviceReady else { return }

        lastKeyboardHeartbeat = Date()
        keyboardHasConnected = true

        if keyboardMonitorTask == nil {
            startKeyboardMonitor()
        }
    }

    private func startRecordingFromKeyboard(requestID: String?) {
        guard serviceReady else {
            publishError(
                "Open VoiceKey and start Keyboard Service first.",
                requestID: requestID
            )
            return
        }
        guard let requestID, !requestID.isEmpty else {
            publishError("VoiceKey received an invalid recording request.")
            return
        }
        guard bridgeStatus != .recording,
              bridgeStatus != .starting,
              bridgeStatus != .transcribing else {
            return
        }

        bridgeStatus = .starting
        activeRequestID = requestID
        clearResult(keepingRequest: true)
        markStateChanged()

        do {
            try audio.arm()
            activeRecordingURL = try audio.beginCapture()
            bridgeStatus = .recording
            statusText = "Recording…"
            pictureInPictureService.showRecording()
            lastError = nil
            bridgeError = nil
            markStateChanged()
        } catch {
            try? prepareStandbyAudio()
            publishError(error.localizedDescription, requestID: requestID)
        }
    }

    private func finishRecordingFromKeyboard(
        expectedRequestID: String?,
        deactivateMicrophoneAfterCapture: Bool
    ) async {
        guard bridgeStatus == .recording else { return }
        guard let requestID = activeRequestID,
              expectedRequestID == nil || expectedRequestID == requestID else { return }

        let capturedURL = audio.endCapture() ?? activeRecordingURL
        activeRecordingURL = nil

        guard let url = capturedURL else {
            publishError("No recording was captured.", requestID: requestID)
            return
        }

        bridgeStatus = .transcribing
        statusText = "Transcribing…"
        pictureInPictureService.showTranscribing()
        markStateChanged()

        if deactivateMicrophoneAfterCapture {
            do {
                try prepareStandbyAudio()
            } catch {
                publishError(error.localizedDescription, requestID: requestID)
                try? FileManager.default.removeItem(at: url)
                return
            }
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
            responseText = text
            resultCreatedAt = Date()
            bridgeError = nil
            bridgeStatus = .completed
            statusText = "Transcription ready"
            pictureInPictureService.showReady()
            signedIn = true
            accountEmail = credential.email
            markStateChanged()
        } catch {
            guard !Task.isCancelled else { return }
            pictureInPictureService.showReady()
            publishError(error.localizedDescription, requestID: requestID)
            statusText = "Transcription failed"
        }
    }

    private func beginFinishingRecording(
        expectedRequestID: String?,
        deactivateMicrophoneAfterCapture: Bool
    ) {
        guard bridgeStatus == .recording else { return }
        transcriptionTask?.cancel()
        transcriptionTask = Task { [weak self] in
            await self?.finishRecordingFromKeyboard(
                expectedRequestID: expectedRequestID,
                deactivateMicrophoneAfterCapture: deactivateMicrophoneAfterCapture
            )
        }
    }

    private func startKeyboardMonitor() {
        keyboardMonitorTask?.cancel()
        keyboardMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }

                guard let self, self.serviceReady else { return }
                guard self.keyboardHasConnected,
                      let heartbeat = self.lastKeyboardHeartbeat,
                      Date().timeIntervalSince(heartbeat) >= LocalBridge.keyboardExitGracePeriod else {
                    continue
                }

                self.lastKeyboardHeartbeat = nil
                self.keyboardHasConnected = false
                self.keyboardMonitorTask = nil

                if self.bridgeStatus == .recording {
                    self.beginFinishingRecording(
                        expectedRequestID: self.activeRequestID,
                        deactivateMicrophoneAfterCapture: true
                    )
                } else if self.audio.isRunning {
                    do {
                        try self.prepareStandbyAudio()
                    } catch {
                        self.publishError(error.localizedDescription)
                    }
                }

                switch self.bridgeStatus {
                case .starting, .idle:
                    self.activeRequestID = nil
                    self.bridgeStatus = .idle
                    self.statusText = self.pictureInPictureActive
                        ? "Skip App Switching is ready"
                        : "Waiting for VoiceKey keyboard"
                case .recording:
                    break
                case .transcribing:
                    self.statusText = "Keyboard closed. Finishing transcription…"
                case .completed:
                    self.statusText = "Keyboard closed. Transcription is ready."
                case .error:
                    self.statusText = self.pictureInPictureActive
                        ? "Skip App Switching is ready"
                        : "Waiting for VoiceKey keyboard"
                }
                self.markStateChanged()
                return
            }
        }
    }

    private func prepareStandbyAudio() throws {
        if pictureInPictureActive {
            try audio.enterPictureInPictureStandby()
        } else {
            try audio.enterStandby()
        }
    }

    private func acknowledgeResult(requestID: String?) {
        guard requestID == nil || requestID == activeRequestID else { return }
        activeRequestID = nil
        clearResult()
        if bridgeStatus == .completed || bridgeStatus == .error {
            bridgeStatus = .idle
        }
        if serviceReady {
            statusText = pictureInPictureActive
                ? "Skip App Switching is ready"
                : "Waiting for VoiceKey keyboard"
        }
        markStateChanged()
    }

    private func clearResult(keepingRequest: Bool = false) {
        responseText = nil
        resultCreatedAt = nil
        bridgeError = nil
        if !keepingRequest {
            activeRequestID = nil
        }
    }

    private func publishError(_ message: String, requestID: String? = nil) {
        if let requestID {
            activeRequestID = requestID
        }
        responseText = nil
        resultCreatedAt = Date()
        bridgeError = message
        bridgeStatus = .error
        lastError = message
        markStateChanged()
    }

    private func currentBridgeState() -> BridgeState {
        BridgeState(
            serverID: serverID,
            revision: stateRevision,
            serviceReady: serviceReady,
            skipAppSwitchingReady: pictureInPictureActive,
            status: bridgeStatus,
            requestID: activeRequestID,
            transcribedText: responseText,
            resultCreatedAt: resultCreatedAt,
            lastError: bridgeError
        )
    }

    private func markStateChanged() {
        stateRevision &+= 1
    }
}
