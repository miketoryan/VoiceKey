import UIKit

final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let micButton = UIButton(type: .system)
    private let globeButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)

    private var observerTokens: [UUID] = []

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
        refreshUI()
        if SharedBridge.status == .completed {
            insertLatestTranscription()
        }
    }

    deinit {
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

        guard SharedBridge.serviceReady else {
            statusLabel.text = "Open VoiceKey and start Keyboard Service first."
            return
        }

        switch SharedBridge.status {
        case .recording:
            DarwinBus.shared.post(SharedBridge.Event.stopRecording)
        case .transcribing:
            break
        default:
            SharedBridge.transcribedText = nil
            DarwinBus.shared.post(SharedBridge.Event.startRecording)
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

        guard SharedBridge.serviceReady else {
            statusLabel.text = "Open VoiceKey and start Keyboard Service."
            micButton.setTitle(" Start Service in App ", for: .normal)
            micButton.backgroundColor = .systemGray
            return
        }

        switch SharedBridge.status {
        case .idle, .completed:
            statusLabel.text = "Ready"
            micButton.setTitle(" 🎙  Speak ", for: .normal)
            micButton.backgroundColor = .systemBlue
        case .recording:
            statusLabel.text = "Recording… tap again to finish"
            micButton.setTitle(" ⏹  Stop ", for: .normal)
            micButton.backgroundColor = .systemRed
        case .transcribing:
            statusLabel.text = "ChatGPT is transcribing…"
            micButton.setTitle(" Processing… ", for: .normal)
            micButton.backgroundColor = .systemGray
        case .error:
            statusLabel.text = SharedBridge.lastError ?? "Transcription failed."
            micButton.setTitle(" 🎙  Try Again ", for: .normal)
            micButton.backgroundColor = .systemOrange
        }
    }

    private func insertLatestTranscription() {
        guard let text = SharedBridge.transcribedText,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            refreshUI()
            return
        }

        textDocumentProxy.insertText(text)
        SharedBridge.transcribedText = nil
        SharedBridge.status = .idle
        refreshUI()
    }
}
