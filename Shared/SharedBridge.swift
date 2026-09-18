import Foundation
import CoreFoundation

enum SharedBridge {
    static let appGroupID = "group.com.miketoryan.VoiceKey"
    static let heartbeatValidity: TimeInterval = 8
    static let resultValidity: TimeInterval = 300

    enum Key {
        static let serviceReady = "voicekey.serviceReady"
        static let heartbeatAt = "voicekey.heartbeatAt"
        static let keyboardActive = "voicekey.keyboardActive"
        static let status = "voicekey.status"
        static let requestID = "voicekey.requestID"
        static let responseRequestID = "voicekey.responseRequestID"
        static let transcribedText = "voicekey.transcribedText"
        static let resultCreatedAt = "voicekey.resultCreatedAt"
        static let lastError = "voicekey.lastError"
    }

    enum Status: String {
        case idle
        case starting
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
        static let keyboardActivated = "com.miketoryan.VoiceKey.keyboardActivated"
        static let keyboardDeactivated = "com.miketoryan.VoiceKey.keyboardDeactivated"
    }

    static var defaults: UserDefaults {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            preconditionFailure("VoiceKey App Group is not configured: \(appGroupID)")
        }
        return defaults
    }

    static var serviceReady: Bool {
        get { defaults.bool(forKey: Key.serviceReady) }
        set {
            defaults.set(newValue, forKey: Key.serviceReady)
            DarwinBus.shared.post(Event.stateChanged)
        }
    }

    static var heartbeatAt: Date? {
        get {
            let value = defaults.double(forKey: Key.heartbeatAt)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Key.heartbeatAt)
            } else {
                defaults.removeObject(forKey: Key.heartbeatAt)
            }
        }
    }

    static var isServiceAvailable: Bool {
        guard serviceReady, let heartbeatAt else { return false }
        return Date().timeIntervalSince(heartbeatAt) <= heartbeatValidity
    }

    static var keyboardActive: Bool {
        get { defaults.bool(forKey: Key.keyboardActive) }
        set { defaults.set(newValue, forKey: Key.keyboardActive) }
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

    static var requestID: String? {
        get { defaults.string(forKey: Key.requestID) }
        set { defaults.set(newValue, forKey: Key.requestID) }
    }

    static var responseRequestID: String? {
        get { defaults.string(forKey: Key.responseRequestID) }
        set { defaults.set(newValue, forKey: Key.responseRequestID) }
    }

    static var resultCreatedAt: Date? {
        get {
            let value = defaults.double(forKey: Key.resultCreatedAt)
            return value > 0 ? Date(timeIntervalSince1970: value) : nil
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: Key.resultCreatedAt)
            } else {
                defaults.removeObject(forKey: Key.resultCreatedAt)
            }
        }
    }

    static var lastError: String? {
        get { defaults.string(forKey: Key.lastError) }
        set { defaults.set(newValue, forKey: Key.lastError) }
    }

    static func touchHeartbeat() {
        heartbeatAt = Date()
    }

    static func publishKeyboardActive(_ active: Bool) {
        keyboardActive = active
        DarwinBus.shared.post(active ? Event.keyboardActivated : Event.keyboardDeactivated)
    }

    static func beginRequest(_ id: String) {
        requestID = id
        responseRequestID = nil
        transcribedText = nil
        resultCreatedAt = nil
        lastError = nil
        status = .starting
    }

    static func publishTranscription(_ text: String, requestID: String) {
        transcribedText = text
        responseRequestID = requestID
        resultCreatedAt = Date()
        status = .completed
        DarwinBus.shared.post(Event.transcriptionReady)
    }

    static func publishError(_ message: String, requestID: String? = nil) {
        lastError = message
        responseRequestID = requestID
        resultCreatedAt = Date()
        status = .error
    }

    static func isFreshResponse(for id: String) -> Bool {
        guard responseRequestID == id, let resultCreatedAt else { return false }
        return Date().timeIntervalSince(resultCreatedAt) <= resultValidity
    }

    static func clearResult() {
        transcribedText = nil
        responseRequestID = nil
        resultCreatedAt = nil
        lastError = nil
    }

    static func invalidateService() {
        serviceReady = false
        heartbeatAt = nil
        requestID = nil
        clearResult()
        status = .idle
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
