import AVFoundation
import Foundation

final class AudioService: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var outputFile: AVAudioFile?
    private var currentURL: URL?
    private var tapInstalled = false

    private(set) var isArmed = false

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func arm() throws {
        guard !isArmed else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.mixWithOthers, .allowBluetoothHFP]
        )
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioError.noInput
        }

        if !tapInstalled {
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
            tapInstalled = true
        }

        engine.prepare()
        try engine.start()
        isArmed = true
    }

    func beginCapture() throws -> URL {
        guard isArmed, engine.isRunning else { throw AudioError.notArmed }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicekey-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        let format = engine.inputNode.inputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        lock.lock()
        outputFile = file
        currentURL = url
        lock.unlock()

        return url
    }

    func endCapture() -> URL? {
        lock.lock()
        outputFile = nil
        let url = currentURL
        currentURL = nil
        lock.unlock()
        return url
    }

    func disarm() {
        lock.lock()
        outputFile = nil
        currentURL = nil
        lock.unlock()

        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isArmed = false
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = outputFile
        if let file {
            try? file.write(from: buffer)
        }
        lock.unlock()
    }

    enum AudioError: LocalizedError {
        case noInput
        case notArmed

        var errorDescription: String? {
            switch self {
            case .noInput: "No microphone input is available."
            case .notArmed: "Start the VoiceKey keyboard service first."
            }
        }
    }
}
