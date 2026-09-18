import UIKit

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)

    private var observerTokens: [UUID] = []
    private var currentRequestID: String?
    private var keyboardVisible = false
    private var mayAutoInsert = false
    private var acknowledgementTask: Task<Void, Never>?
    private var transcriptionTimeoutTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        configureUI()

        observerTokens.append(
            DarwinBus.shared.observe(SharedBridge.Event.stateChanged) { [weak self] in
                DispatchQueue.main.async { self?.refreshUI() }
            }
        )
        observerTokens.append(
            DarwinBus.shared.observe(SharedBridge.Event.transcriptionReady) { [weak self] in
                DispatchQueue.main.async { self?.insertLatestTranscription() }
            }
        )

        refreshUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        keyboardVisible = true
        refreshUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        keyboardVisible = false
        mayAutoInsert = false
        super.viewWillDisappear(animated)
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        if SharedBridge.status == .transcribing {
            mayAutoInsert = false
        }
    }

    deinit {
        acknowledgementTask?.cancel()
        transcriptionTimeoutTask?.cancel()
        for token in observerTokens {
            DarwinBus.shared.remove(token)
        }
    }

    private func configureUI() {
        view.backgroundColor = .secondarySystemBackground

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.textColor = .secondaryLabel

        micButton.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        micButton.layer.cornerRadius = 16
        micButton.backgroundColor = .systemBlue
        micButton.tintColor = .white
        micButton.addTarget(self, action: #selector(toggleRecording), for: .touchUpInside)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.titleLabel?.font = .systemFont(ofSize: 18)
        globeButton.addTarget(self, action: #selector(nextKeyboard), for: .touchUpInside)

        deleteButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        deleteButton.titleLabel?.font = .systemFont(ofSize: 18)
        deleteButton.addTarget(self, action: #selector(deleteBackward), for: .touchUpInside)

        let tools = UIStackView(arrangedSubviews: [globeButton, micButton, deleteButton])
        tools.axis = .horizontal
        tools.alignment = .fill
        tools.distribution = .fillEqually
        tools.spacing = 10

        let stack = UIStackView(arrangedSubviews: [statusLabel, tools])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            micButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: 130)
        ])
    }

    @objc private func toggleRecording() {
        guard hasFullAccess else {
            statusLabel.text = "Enable Allow Full Access for VoiceKey in Settings."
            return
        }

        if SharedBridge.status == .completed,
           let requestID = SharedBridge.requestID,
           SharedBridge.isFreshResponse(for: requestID) {
            insertLatestTranscription(automatically: false)
            return
        }

        guard SharedBridge.isServiceAvailable else {
            statusLabel.text = "Open VoiceKey and start Keyboard Service first."
            micButton.setTitle(" Start Service in App ", for: .normal)
            micButton.backgroundColor = .systemGray
            return
        }

        switch SharedBridge.status {
        case .recording:
            mayAutoInsert = true
            DarwinBus.shared.post(SharedBridge.Event.stopRecording)
            scheduleTranscriptionTimeout(for: currentRequestID ?? SharedBridge.requestID)
        case .starting:
            break
        case .transcribing:
            break
        default:
            startRecordingRequest()
        }
    }

    @objc private func nextKeyboard() {
        advanceToNextInputMode()
    }

    @objc private func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }

    private func refreshUI() {
        guard hasFullAccess else {
            statusLabel.text = "Allow Full Access is required."
            micButton.setTitle(" Enable Full Access ", for: .normal)
            micButton.backgroundColor = .systemGray
            return
        }

        if SharedBridge.status == .completed,
           let requestID = SharedBridge.requestID,
           SharedBridge.isFreshResponse(for: requestID),
           SharedBridge.transcribedText != nil {
            statusLabel.text = "Transcription ready — tap to insert"
            micButton.setTitle(" Insert Result ", for: .normal)
            micButton.backgroundColor = .systemGreen
            return
        }

        guard SharedBridge.isServiceAvailable else {
            statusLabel.text = "Open VoiceKey and start Keyboard Service."
            micButton.setTitle(" Start Service in App ", for: .normal)
            micButton.backgroundColor = .systemGray
            return
        }

        switch SharedBridge.status {
        case .idle:
            statusLabel.text = "Ready"
            micButton.setTitle(" 🎙  Speak ", for: .normal)
            micButton.backgroundColor = .systemBlue
        case .starting:
            statusLabel.text = "Connecting to VoiceKey…"
            micButton.setTitle(" Starting… ", for: .normal)
            micButton.backgroundColor = .systemGray
        case .recording:
            statusLabel.text = "Recording… tap again to finish"
            micButton.setTitle(" ⏹  Stop ", for: .normal)
            micButton.backgroundColor = .systemRed
        case .transcribing:
            statusLabel.text = "ChatGPT is transcribing…"
            micButton.setTitle(" Processing… ", for: .normal)
            micButton.backgroundColor = .systemGray
        case .completed:
            SharedBridge.clearResult()
            SharedBridge.status = .idle
            refreshUI()
        case .error:
            statusLabel.text = SharedBridge.lastError ?? "Transcription failed."
            micButton.setTitle(" 🎙  Try Again ", for: .normal)
            micButton.backgroundColor = .systemOrange
        }
    }

    private func startRecordingRequest() {
        acknowledgementTask?.cancel()
        transcriptionTimeoutTask?.cancel()

        let requestID = UUID().uuidString
        currentRequestID = requestID
        mayAutoInsert = true
        SharedBridge.beginRequest(requestID)
        DarwinBus.shared.post(SharedBridge.Event.startRecording)

        acknowledgementTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self,
                  self.currentRequestID == requestID,
                  SharedBridge.requestID == requestID,
                  SharedBridge.status == .starting else { return }

            self.mayAutoInsert = false
            SharedBridge.publishError(
                "VoiceKey did not respond. Open the app and start Keyboard Service again.",
                requestID: requestID
            )
        }
    }

    private func scheduleTranscriptionTimeout(for requestID: String?) {
        guard let requestID else { return }
        transcriptionTimeoutTask?.cancel()
        transcriptionTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(75))
            } catch {
                return
            }
            guard let self,
                  self.currentRequestID == requestID,
                  SharedBridge.requestID == requestID,
                  SharedBridge.status == .transcribing else { return }

            self.mayAutoInsert = false
            SharedBridge.publishError(
                "Transcription timed out. Please try again.",
                requestID: requestID
            )
        }
    }

    private func insertLatestTranscription(automatically: Bool = true) {
        let requestID = currentRequestID ?? SharedBridge.requestID
        guard let requestID,
              SharedBridge.isFreshResponse(for: requestID) else {
            refreshUI()
            return
        }

        if automatically {
            guard keyboardVisible, mayAutoInsert, currentRequestID == requestID else {
                refreshUI()
                return
            }
        }

        guard let text = SharedBridge.transcribedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            refreshUI()
            return
        }

        textDocumentProxy.insertText(text)
        acknowledgementTask?.cancel()
        transcriptionTimeoutTask?.cancel()
        currentRequestID = nil
        mayAutoInsert = false
        SharedBridge.requestID = nil
        SharedBridge.clearResult()
        SharedBridge.status = .idle
        refreshUI()
    }
}
