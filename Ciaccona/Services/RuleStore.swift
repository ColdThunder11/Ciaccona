import Foundation
import OSLog
import Synchronization

enum OutputTarget: Codable, Equatable, Sendable {
    case followSystemDefault
    case device(uid: String, lastKnownName: String)

    private enum CodingKeys: String, CodingKey {
        case device
    }

    private struct DevicePayload: Codable, Equatable {
        let uid: String
        let lastKnownName: String
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(),
           let str = try? single.decode(String.self),
           str == "followSystemDefault" {
            self = .followSystemDefault
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let payload = try container.decode(DevicePayload.self, forKey: .device)
        self = .device(uid: payload.uid, lastKnownName: payload.lastKnownName)
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .followSystemDefault:
            var single = encoder.singleValueContainer()
            try single.encode("followSystemDefault")
        case let .device(uid, lastKnownName):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(DevicePayload(uid: uid, lastKnownName: lastKnownName), forKey: .device)
        }
    }
}

enum VolumeLevel {
    static func quantize(_ value: Float, max maxValue: Float) -> Float {
        Float(percent(value, max: maxValue)) / 100.0
    }

    static func percent(_ value: Float, max maxValue: Float) -> Int {
        let clamped = Swift.max(0.0, Swift.min(maxValue, value))
        return Int((clamped * 100.0).rounded())
    }
}

struct AppRule: Codable, Equatable, Sendable {
    var volume: Float = 1.0
    var muted: Bool = false
    var output: OutputTarget = .followSystemDefault

    var isDefault: Bool {
        abs(volume - 1.0) < 0.001 && !muted && output == .followSystemDefault
    }

    static let `default` = AppRule()
}

enum AudioBufferPreset: Int, Codable, CaseIterable, Identifiable, Sendable {
    case ultraLow = 128
    case low = 256
    case standard = 512
    case high = 1024

    var id: Int { rawValue }
    var frameCount: UInt32 { UInt32(rawValue) }

    var displayName: String {
        displayName(language: nil)
    }

    func displayName(language: AppLanguage?) -> String {
        switch self {
        case .ultraLow:
            return L10n.tr("settings.buffer.ultra_low", defaultValue: "Ultra Low", language: language)
        case .low:
            return L10n.tr("settings.buffer.low", defaultValue: "Low", language: language)
        case .standard:
            return L10n.tr("settings.buffer.standard", defaultValue: "Standard", language: language)
        case .high:
            return L10n.tr("settings.buffer.high", defaultValue: "High", language: language)
        }
    }
}

struct AppPreferences: Codable, Equatable, Sendable {
    var pauseIdleSessions: Bool = false
    var launchAtLogin: Bool = false
    var showAllProcesses: Bool = false
    var takeOverVolumeMediaKeys: Bool = false
    var bufferFrameSize: AudioBufferPreset = .standard
    var language: AppLanguage = .system

    init(
        pauseIdleSessions: Bool = false,
        launchAtLogin: Bool = false,
        showAllProcesses: Bool = false,
        takeOverVolumeMediaKeys: Bool = false,
        bufferFrameSize: AudioBufferPreset = .standard,
        language: AppLanguage = .system
    ) {
        self.pauseIdleSessions = pauseIdleSessions
        self.launchAtLogin = launchAtLogin
        self.showAllProcesses = showAllProcesses
        self.takeOverVolumeMediaKeys = takeOverVolumeMediaKeys
        self.bufferFrameSize = bufferFrameSize
        self.language = language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.pauseIdleSessions = try container.decodeIfPresent(Bool.self, forKey: .pauseIdleSessions) ?? false
        self.launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        self.showAllProcesses = try container.decodeIfPresent(Bool.self, forKey: .showAllProcesses) ?? false
        self.takeOverVolumeMediaKeys = try container.decodeIfPresent(Bool.self, forKey: .takeOverVolumeMediaKeys) ?? false
        self.bufferFrameSize = try container.decodeIfPresent(AudioBufferPreset.self, forKey: .bufferFrameSize) ?? .standard
        self.language = try container.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .system
    }
}

struct DeviceVolumeRule: Codable, Equatable, Sendable {
    var volume: Float = 1.0
    var muted: Bool = false

    var isDefault: Bool {
        abs(volume - 1.0) < 0.001 && !muted
    }

    static let `default` = DeviceVolumeRule()
}

struct PersistedRuleFile: Codable, Equatable, Sendable {
    var version: Int = 1
    var rules: [String: AppRule] = [:]
    var deviceVolumes: [String: DeviceVolumeRule] = [:]
    var preferences: AppPreferences = AppPreferences()

    init(
        version: Int = 1,
        rules: [String: AppRule] = [:],
        deviceVolumes: [String: DeviceVolumeRule] = [:],
        preferences: AppPreferences = AppPreferences()
    ) {
        self.version = version
        self.rules = rules
        self.deviceVolumes = deviceVolumes
        self.preferences = preferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.rules = try container.decodeIfPresent([String: AppRule].self, forKey: .rules) ?? [:]
        self.deviceVolumes = try container.decodeIfPresent([String: DeviceVolumeRule].self, forKey: .deviceVolumes) ?? [:]
        self.preferences = try container.decodeIfPresent(AppPreferences.self, forKey: .preferences) ?? AppPreferences()
    }
}

final class RuleStore: Sendable {
    private static let logger = Logger(subsystem: "com.coldthunder11.ciaccona", category: "RuleStore")

    private struct State: @unchecked Sendable {
        var data: PersistedRuleFile
        var saveTask: Task<Void, Never>?
        var saveDeadline: ContinuousClock.Instant?
        var saveLoopActive: Bool = false
    }

    let fileURL: URL
    private let debounceInterval: Duration
    private let state: Mutex<State>

    var rules: [String: AppRule] {
        state.withLock { $0.data.rules }
    }

    var preferences: AppPreferences {
        state.withLock { $0.data.preferences }
    }

    static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Ciaccona", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    init(fileURL: URL = RuleStore.defaultFileURL, debounceInterval: Duration = .seconds(1)) {
        self.fileURL = fileURL
        self.debounceInterval = debounceInterval
        self.state = Mutex(State(data: Self.load(from: fileURL), saveTask: nil))
    }

    func rule(for appID: String) -> AppRule {
        state.withLock { $0.data.rules[appID] ?? .default }
    }

    func setRule(_ rule: AppRule, for appID: String) {
        var normalized = rule
        normalized.volume = VolumeLevel.quantize(rule.volume, max: 1.5)
        state.withLock { st in
            if normalized.isDefault {
                st.data.rules.removeValue(forKey: appID)
            } else {
                st.data.rules[appID] = normalized
            }
        }
        scheduleSave()
    }

    func removeRule(for appID: String) {
        let removed = state.withLock { $0.data.rules.removeValue(forKey: appID) != nil }
        if removed {
            scheduleSave()
        }
    }

    func removeAllRules() {
        let hadRules = state.withLock { st in
            guard !st.data.rules.isEmpty else { return false }
            st.data.rules.removeAll()
            return true
        }
        if hadRules {
            scheduleSave()
        }
    }

    func deviceVolumeRule(for deviceUID: String) -> DeviceVolumeRule {
        state.withLock { $0.data.deviceVolumes[deviceUID] ?? .default }
    }

    func setDeviceVolumeRule(_ rule: DeviceVolumeRule, for deviceUID: String) {
        var normalized = rule
        normalized.volume = VolumeLevel.quantize(rule.volume, max: 1.0)
        state.withLock { st in
            if normalized.isDefault {
                st.data.deviceVolumes.removeValue(forKey: deviceUID)
            } else {
                st.data.deviceVolumes[deviceUID] = normalized
            }
        }
        scheduleSave()
    }

    func updatePreferences(_ mutate: (inout AppPreferences) -> Void) {
        state.withLock { st in
            mutate(&st.data.preferences)
        }
        scheduleSave()
    }

    func flush() {
        let snapshot: PersistedRuleFile = state.withLock { st in
            st.saveDeadline = nil
            st.saveLoopActive = false
            st.saveTask?.cancel()
            st.saveTask = nil
            return st.data
        }
        writeNow(snapshot)
    }

    private func scheduleSave() {
        let nextDeadline = ContinuousClock.now + debounceInterval
        let shouldLaunch = state.withLock { st -> Bool in
            st.saveDeadline = nextDeadline
            guard !st.saveLoopActive else { return false }
            st.saveLoopActive = true
            return true
        }
        guard shouldLaunch else { return }

        // Reuse a single sleep loop while dragging sliders instead of cancelling/spawning a Task per tick.
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let next: (deadline: ContinuousClock.Instant?, snapshot: PersistedRuleFile?) = self.state.withLock { st in
                    guard let deadline = st.saveDeadline else {
                        st.saveLoopActive = false
                        st.saveTask = nil
                        return (nil, nil)
                    }
                    if ContinuousClock.now < deadline {
                        return (deadline, nil)
                    }
                    st.saveDeadline = nil
                    st.saveLoopActive = false
                    st.saveTask = nil
                    return (nil, st.data)
                }
                if let snapshot = next.snapshot {
                    self.writeNow(snapshot)
                    return
                }
                guard let deadline = next.deadline else { return }
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
            self?.state.withLock { st in
                st.saveLoopActive = false
                st.saveTask = nil
            }
        }
        state.withLock { st in
            if st.saveLoopActive {
                st.saveTask = task
            } else {
                task.cancel()
            }
        }
    }

    private func writeNow(_ snapshot: PersistedRuleFile) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(snapshot)
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Failed to save rules.json: \(error.localizedDescription)")
        }
    }

    private static func load(from url: URL) -> PersistedRuleFile {
        guard let raw = try? Data(contentsOf: url) else {
            return PersistedRuleFile()
        }
        do {
            var decoded = try JSONDecoder().decode(PersistedRuleFile.self, from: raw)
            decoded.rules = decoded.rules.compactMapValues { rule in
                var normalized = rule
                normalized.volume = VolumeLevel.quantize(rule.volume, max: 1.5)
                return normalized.isDefault ? nil : normalized
            }
            decoded.deviceVolumes = decoded.deviceVolumes.compactMapValues { rule in
                var normalized = rule
                normalized.volume = VolumeLevel.quantize(rule.volume, max: 1.0)
                return normalized.isDefault ? nil : normalized
            }
            return decoded
        } catch {
            logger.error("Failed to decode rules.json, using defaults: \(error.localizedDescription)")
            return PersistedRuleFile()
        }
    }
}
