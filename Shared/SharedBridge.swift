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

private let darwinCallback: CFNotificationCallback = { _, observer, name, _, _ in
    guard let observer, let name else { return }
    let bus = Unmanaged<DarwinBus>.fromOpaque(observer).takeUnretainedValue()
    bus.deliver(name.rawValue as String)
}

final class DarwinBus {
    static let shared = DarwinBus()

    private let center = CFNotificationCenterGetDarwinNotifyCenter()
    private let lock = NSLock()
    private var handlers: [String: [UUID: () -> Void]] = [:]
    private var registeredNames = Set<String>()

    private init() {}

    @discardableResult
    func observe(_ name: String, handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        handlers[name, default: [:]][id] = handler
        let shouldRegister = registeredNames.insert(name).inserted
        lock.unlock()

        if shouldRegister {
            CFNotificationCenterAddObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                darwinCallback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
        return id
    }

    func remove(_ id: UUID) {
        lock.lock()
        for name in handlers.keys {
            handlers[name]?[id] = nil
        }
        lock.unlock()
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

    fileprivate func deliver(_ name: String) {
        lock.lock()
        let callbacks = handlers[name].map { Array($0.values) } ?? []
        lock.unlock()
        callbacks.forEach { $0() }
    }
}
