import Foundation
import CoreFoundation

enum SharedBridge {
    static let appGroupID = "group.com.miketoryan.VoiceKey"

    enum Key {
        static let serviceReady = "voicekey.serviceReady"
        static let status = "voicekey.status"
        static let transcribedText = "voicekey.transcribedText"
        static let lastError = "voicekey.lastError"
    }

    enum Status: String {
        case idle
        case recording
        case transcribing
        case completed
        case error
    }

    enum Event {
        static let startRecording = "com.miketoryan.VoiceKey.startRecording"
        static let stopRecording = "com.miketoryan.VoiceKey.stopRecording"
        static let stateChanged = "com.miketoryan.VoiceKey.stateChanged"
        static let transcriptionReady = "com.miketoryan.VoiceKey.transcriptionReady"
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static var serviceReady: Bool {
        get { defaults.bool(forKey: Key.serviceReady) }
        set {
            defaults.set(newValue, forKey: Key.serviceReady)
            DarwinBus.shared.post(Event.stateChanged)
        }
    }

    static var status: Status {
        get {
            guard let raw = defaults.string(forKey: Key.status),
                  let value = Status(rawValue: raw) else { return .idle }
            return value
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.status)
            DarwinBus.shared.post(Event.stateChanged)
        }
    }

    static var transcribedText: String? {
        get { defaults.string(forKey: Key.transcribedText) }
        set { defaults.set(newValue, forKey: Key.transcribedText) }
    }

    static var lastError: String? {
        get { defaults.string(forKey: Key.lastError) }
        set { defaults.set(newValue, forKey: Key.lastError) }
    }

    static func publishTranscription(_ text: String) {
        transcribedText = text
        status = .completed
        DarwinBus.shared.post(Event.transcriptionReady)
    }

    static func publishError(_ message: String) {
        lastError = message
        status = .error
    }
}

private final class DarwinToken: @unchecked Sendable {
    let id = UUID()
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }
}

private let darwinCallback: CFNotificationCallback = { _, observer, _, _, _ in
    guard let observer else { return }
    let token = Unmanaged<DarwinToken>.fromOpaque(observer).takeUnretainedValue()
    token.handler()
}

final class DarwinBus: @unchecked Sendable {
    static let shared = DarwinBus()

    private let center = CFNotificationCenterGetDarwinNotifyCenter()
    private let lock = NSLock()
    private var tokens: [UUID: DarwinToken] = [:]

    private init() {}

    @discardableResult
    func observe(_ name: String, handler: @escaping () -> Void) -> UUID {
        let token = DarwinToken(handler: handler)

        lock.lock()
        tokens[token.id] = token
        lock.unlock()

        CFNotificationCenterAddObserver(
            center,
            Unmanaged.passUnretained(token).toOpaque(),
            darwinCallback,
            name as CFString,
            nil,
            .deliverImmediately
        )
        return token.id
    }

    func remove(_ id: UUID) {
        lock.lock()
        let token = tokens.removeValue(forKey: id)
        lock.unlock()

        guard let token else { return }
        CFNotificationCenterRemoveObserver(
            center,
            Unmanaged.passUnretained(token).toOpaque(),
            nil,
            nil
        )
    }

    func post(_ name: String) {
        CFNotificationCenterPostNotification(
            center,
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}
