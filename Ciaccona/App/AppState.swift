import AppKit
import CoreAudio
import Foundation
import Observation
import OSLog
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
@Observable
final class ObservableAppRule {
    var rule: AppRule

    init(rule: AppRule = .default) {
        self.rule = rule
    }
}

@MainActor
@Observable
final class AppState {
    private static let logger = Logger(subsystem: "com.coldthunder11.ciaccona", category: "AppState")

    var isAuthorized = false
    var permissionGateState: PermissionGateState = .probing

    var outputDevices: [AudioDevice] = []
    var defaultOutputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    var globalVolume: Float = 1.0
    var isGlobalMuted: Bool = false
    var canSetGlobalVolume: Bool = true
    var canMuteGlobal: Bool = true
    var isUsingSoftwareGlobalVolume: Bool = false
    var isUsingSoftwareGlobalMute: Bool = false
    var needsMediaKeyAccessibilityPermission: Bool = false

    var activeApps: [AudioApp] = []
    private(set) var playingApps: [AudioApp] = []
    private(set) var activeIdleApps: [AudioApp] = []
    var systemAlertApp: AudioApp = SystemAlertSound.makeApp(from: [])
    var rules: [String: AppRule] = [:]
    var eqPresets: [EQProfile] = []
    var deviceEQs: [String: UUID] = [:]
    var preferences: AppPreferences = AppPreferences()
    var offlineAppIDs: Set<String> = []
    var sessionErrors: [String: String] = [:]

    @ObservationIgnored private var routingEngine: RoutingEngine?
    @ObservationIgnored private var volumeThrottleTask: Task<Void, Never>?
    @ObservationIgnored private var pendingGlobalVolume: Float?
    @ObservationIgnored private var lastGlobalVolumeSentAt: ContinuousClock.Instant = .now - .seconds(1)
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored private var missingIconAppIDs: Set<String> = []
    @ObservationIgnored private var rawRules: [String: AppRule] = [:]
    @ObservationIgnored private var ruleModels: [String: ObservableAppRule] = [:]
    @ObservationIgnored private let mediaKeyMonitor = MediaKeyMonitor()
    @ObservationIgnored private let volumeHUD = VolumeHUDWindowController()

    init() {
        mediaKeyMonitor.shouldIntercept = { [weak self] action in
            self?.shouldInterceptMediaKey(action) ?? false
        }
        mediaKeyMonitor.onMediaKey = { [weak self] action, fineStep in
            self?.handleMediaKeyAction(action, fineStep: fineStep)
        }
        mediaKeyMonitor.onPermissionStateChanged = { [weak self] needsPermission in
            self?.needsMediaKeyAccessibilityPermission = needsPermission
        }
    }

    var defaultOutputDevice: AudioDevice? {
        outputDevices.first { $0.id == defaultOutputDeviceID }
    }

    var currentDefaultDeviceEQ: EQProfile? {
        guard let uid = defaultOutputDevice?.uid, let id = deviceEQs[uid] else { return nil }
        return eqPresets.first { $0.id == id }
    }

    func eqPreset(for rule: AppRule) -> EQProfile? {
        guard let id = rule.eqPresetID else { return nil }
        return eqPresets.first { $0.id == id }
    }

    var menuBarSymbolName: String {
        if isGlobalMuted || globalVolume <= 0.001 {
            return "speaker.slash.fill"
        } else if globalVolume < 0.34 {
            return "speaker.wave.1.fill"
        } else if globalVolume < 0.67 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    func attachEngine(_ engine: RoutingEngine) {
        self.routingEngine = engine
    }

    func updateDevices(_ devices: [AudioDevice], defaultID: AudioObjectID) {
        if self.outputDevices != devices {
            self.outputDevices = devices
        }
        if self.defaultOutputDeviceID != defaultID {
            self.defaultOutputDeviceID = defaultID
        }
    }

    func updateGlobalVolumeSnapshot(_ snapshot: GlobalVolumeSnapshot) {
        if self.globalVolume != snapshot.volume {
            self.globalVolume = snapshot.volume
        }
        if self.isGlobalMuted != snapshot.isMuted {
            self.isGlobalMuted = snapshot.isMuted
        }
        if self.canSetGlobalVolume != snapshot.canSetVolume {
            self.canSetGlobalVolume = snapshot.canSetVolume
        }
        if self.canMuteGlobal != snapshot.canMute {
            self.canMuteGlobal = snapshot.canMute
        }
        if self.isUsingSoftwareGlobalVolume != snapshot.isSoftwareVolume {
            self.isUsingSoftwareGlobalVolume = snapshot.isSoftwareVolume
        }
        if self.isUsingSoftwareGlobalMute != snapshot.isSoftwareMute {
            self.isUsingSoftwareGlobalMute = snapshot.isSoftwareMute
        }
    }

    func applyRoutingSnapshot(_ snapshot: RoutingSnapshot) {
        if self.activeApps != snapshot.activeApps {
            self.activeApps = snapshot.activeApps
            self.playingApps = snapshot.activeApps.filter(\.isPlaying)
            self.activeIdleApps = snapshot.activeApps.filter { !$0.isPlaying }
        }
        if self.systemAlertApp != snapshot.systemAlertApp {
            self.systemAlertApp = snapshot.systemAlertApp
        }
        if self.rawRules != snapshot.rules {
            self.rawRules = snapshot.rules
            for (appID, model) in ruleModels {
                let target = snapshot.rules[appID] ?? .default
                if model.rule != target {
                    model.rule = target
                }
            }
        }
        pruneInactiveCaches()
        if self.rules != snapshot.rules {
            self.rules = snapshot.rules
        }
        if self.eqPresets != snapshot.eqPresets {
            self.eqPresets = snapshot.eqPresets
        }
        if self.deviceEQs != snapshot.deviceEQs {
            self.deviceEQs = snapshot.deviceEQs
        }
        if self.preferences != snapshot.preferences {
            let prevTakeOverMediaKeys = self.preferences.takeOverVolumeMediaKeys
            self.preferences = snapshot.preferences
            L10n.currentLanguage = snapshot.preferences.language
            if prevTakeOverMediaKeys != snapshot.preferences.takeOverVolumeMediaKeys {
                mediaKeyMonitor.setEnabled(snapshot.preferences.takeOverVolumeMediaKeys, promptIfNeeded: false)
            }
        }
        if self.offlineAppIDs != snapshot.offlineAppIDs {
            self.offlineAppIDs = snapshot.offlineAppIDs
        }
        if self.sessionErrors != snapshot.sessionErrors {
            self.sessionErrors = snapshot.sessionErrors
        }
    }

    // MARK: - User Intents

    func selectDefaultOutputDevice(_ deviceID: AudioObjectID) {
        let prevID = defaultOutputDeviceID
        defaultOutputDeviceID = deviceID
        let engine = routingEngine
        Task { @AudioControlActor in
            do {
                try engine?.setDefaultOutputDevice(deviceID)
            } catch {
                await MainActor.run {
                    if self.defaultOutputDeviceID == deviceID {
                        self.defaultOutputDeviceID = prevID
                    }
                }
            }
        }
    }

    /// Throttles HAL volume writes to ~30 Hz while keeping UI slider responsive.
    func setGlobalVolume(_ value: Float) {
        let quantized = VolumeLevel.quantize(value, max: 1.0)
        guard quantized != globalVolume else { return }
        globalVolume = quantized
        pendingGlobalVolume = quantized

        let now = ContinuousClock.now
        let minInterval = Duration.milliseconds(33)
        if now - lastGlobalVolumeSentAt >= minInterval {
            flushPendingGlobalVolume()
        } else if volumeThrottleTask == nil {
            let remaining = minInterval - (now - lastGlobalVolumeSentAt)
            volumeThrottleTask = Task { [weak self] in
                try? await Task.sleep(for: remaining)
                guard !Task.isCancelled else { return }
                self?.volumeThrottleTask = nil
                self?.flushPendingGlobalVolume()
            }
        }
    }

    private func flushPendingGlobalVolume() {
        guard let value = pendingGlobalVolume else { return }
        pendingGlobalVolume = nil
        lastGlobalVolumeSentAt = .now
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.setGlobalVolume(value)
        }
    }

    func toggleGlobalMute() {
        let next = !isGlobalMuted
        isGlobalMuted = next
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.setGlobalMuted(next)
        }
    }

    func rule(for appID: String) -> AppRule {
        rules[appID] ?? .default
    }

    /// Returns a per-app observable rule box without subscribing the caller to the global `rules` dictionary.
    func ruleModel(for appID: String) -> ObservableAppRule {
        if let existing = ruleModels[appID] {
            return existing
        }
        let model = ObservableAppRule(rule: rawRules[appID] ?? .default)
        ruleModels[appID] = model
        return model
    }

    func setAppVolume(_ volume: Float, for appID: String) {
        let quantized = VolumeLevel.quantize(volume, max: 2.0)
        var r = rawRules[appID] ?? .default
        guard quantized != r.volume else { return }
        r.volume = quantized
        updateLocalRule(r, for: appID)
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.updateAppVolume(appID: appID, volume: quantized)
        }
    }

    func toggleAppMute(for appID: String) {
        var r = rule(for: appID)
        r.muted.toggle()
        updateLocalRule(r, for: appID)
        let muted = r.muted
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.updateAppMuted(appID: appID, muted: muted)
        }
    }

    func setAppOutput(_ target: OutputTarget, for appID: String) {
        var r = rule(for: appID)
        r.output = target
        updateLocalRule(r, for: appID)
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.updateAppOutput(appID: appID, target: target)
        }
    }

    func selectAppEQPreset(_ presetID: UUID?, for appID: String) {
        var r = rule(for: appID)
        r.eqPresetID = presetID
        updateLocalRule(r, for: appID)
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.updateAppEQPreset(presetID, for: appID)
        }
    }

    func selectDefaultDeviceEQPreset(_ presetID: UUID?) {
        guard let uid = defaultOutputDevice?.uid else { return }
        if let presetID {
            deviceEQs[uid] = presetID
        } else {
            deviceEQs.removeValue(forKey: uid)
        }
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.updateDeviceEQPreset(presetID, for: uid)
        }
    }

    func deleteEQPreset(id: UUID) {
        eqPresets.removeAll { $0.id == id }
        for (appID, var rule) in rawRules where rule.eqPresetID == id {
            rule.eqPresetID = nil
            updateLocalRule(rule, for: appID)
        }
        for (uid, presetID) in deviceEQs where presetID == id {
            deviceEQs.removeValue(forKey: uid)
        }
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.removeEQPreset(id: id)
        }
    }

    func importEQPresetsFromPanel() {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText]
        panel.message = L10n.tr(
            "eq.import.panel.library_message",
            defaultValue: "Select parametric EQ (.txt) files to import into Ciaccona"
        )

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        var imported: [EQProfile] = []
        var firstError: Error?

        for fileURL in panel.urls {
            do {
                let content: String
                if let utf8 = try? String(contentsOf: fileURL, encoding: .utf8) {
                    content = utf8
                } else {
                    content = try String(contentsOf: fileURL, encoding: .isoLatin1)
                }
                let presetName = fileURL.deletingPathExtension().lastPathComponent
                let profile = try ParametricEQParser.parse(content, name: presetName)
                imported.append(profile)
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if !imported.isEmpty {
            eqPresets.append(contentsOf: imported)
            let batch = imported
            let engine = routingEngine
            Task { @AudioControlActor in
                engine?.addEQPresets(batch)
            }
        }

        if let firstError {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.tr("eq.import.error.title", defaultValue: "Failed to Import EQ")
            alert.informativeText = firstError.localizedDescription
            alert.addButton(withTitle: L10n.tr("instance.already_running.ok", defaultValue: "OK"))
            alert.runModal()
        }
    }

    func resetAppRule(for appID: String) {
        rawRules.removeValue(forKey: appID)
        rules.removeValue(forKey: appID)
        if let model = ruleModels[appID], model.rule != .default {
            model.rule = .default
        }
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.resetAppRule(appID: appID)
        }
    }

    func retrySession(for appID: String) {
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.retrySession(appID: appID)
        }
    }

    func setPauseIdleSessions(_ enabled: Bool) {
        preferences.pauseIdleSessions = enabled
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.updatePreferences { $0.pauseIdleSessions = enabled }
        }
    }

    func setShowAllProcesses(_ enabled: Bool) {
        preferences.showAllProcesses = enabled
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.updatePreferences { $0.showAllProcesses = enabled }
        }
    }

    func setTakeOverVolumeMediaKeys(_ enabled: Bool) {
        preferences.takeOverVolumeMediaKeys = enabled
        mediaKeyMonitor.setEnabled(enabled, promptIfNeeded: enabled)
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.updatePreferences { $0.takeOverVolumeMediaKeys = enabled }
        }
    }

    func openMediaKeyAccessibilitySettings() {
        mediaKeyMonitor.openAccessibilitySettings()
    }

    func stopMediaKeyMonitor() {
        mediaKeyMonitor.setEnabled(false)
    }

    func shouldInterceptMediaKey(_ action: MediaKeyAction) -> Bool {
        guard preferences.takeOverVolumeMediaKeys, defaultOutputDevice != nil else {
            return false
        }
        switch action {
        case .volumeUp, .volumeDown:
            return isUsingSoftwareGlobalVolume
        case .muteToggle:
            return isUsingSoftwareGlobalMute
        }
    }

    func handleMediaKeyAction(_ action: MediaKeyAction, fineStep: Bool) {
        let step: Float = fineStep ? 0.01 : (1.0 / 16.0)
        switch action {
        case .volumeUp:
            if isGlobalMuted && isUsingSoftwareGlobalMute {
                toggleGlobalMute()
            }
            let next = VolumeLevel.quantize(min(1.0, globalVolume + step), max: 1.0)
            setGlobalVolume(next)
        case .volumeDown:
            let next = VolumeLevel.quantize(max(0.0, globalVolume - step), max: 1.0)
            setGlobalVolume(next)
        case .muteToggle:
            toggleGlobalMute()
        }

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            volumeHUD.show(
                volume: globalVolume,
                isMuted: isGlobalMuted,
                deviceName: defaultOutputDevice?.name ?? ""
            )
        }
    }

    func setBufferFrameSize(_ preset: AudioBufferPreset) {
        preferences.bufferFrameSize = preset
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.updatePreferences { $0.bufferFrameSize = preset }
        }
    }

    func setLanguage(_ language: AppLanguage) {
        preferences.language = language
        L10n.currentLanguage = language
        L10n.applySystemLanguageOverride(language)
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.updatePreferences { $0.language = language }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            preferences.launchAtLogin = enabled
            let engine = routingEngine
            Task { @AudioControlActor in
                engine?.updatePreferences { $0.launchAtLogin = enabled }
            }
        } catch {
            Self.logger.error("Failed updating SMAppService launchAtLogin: \(error.localizedDescription)")
        }
    }

    func resetAllRoutingRules() {
        rawRules.removeAll()
        rules.removeAll()
        for model in ruleModels.values where model.rule != .default {
            model.rule = .default
        }
        offlineAppIDs.removeAll()
        sessionErrors.removeAll()
        let engine = routingEngine
        Task { @AudioControlActor in
            engine?.resetAllAppRules()
        }
    }

    // MARK: - App Icon Resolution

    func icon(for app: AudioApp) -> NSImage? {
        if let cached = iconCache[app.id] {
            return cached
        }
        if missingIconAppIDs.contains(app.id) {
            return nil
        }
        if let pid = app.mainPID,
           let running = NSRunningApplication(processIdentifier: pid),
           let icon = running.icon {
            let compact = Self.compactIcon(from: icon)
            iconCache[app.id] = compact
            return compact
        }
        if let bundleID = app.bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            let compact = Self.compactIcon(from: icon)
            iconCache[app.id] = compact
            return compact
        }
        if app.bundleID == nil && !app.isRegularApp {
            missingIconAppIDs.insert(app.id)
        }
        return nil
    }

    /// Downsamples multi-resolution app icons (often up to 1024x1024) to a single 20pt @2x (40x40px) bitmap.
    static func compactIcon(from source: NSImage, pointSize: CGFloat = 20, scale: CGFloat = 2) -> NSImage {
        let pixelSide = max(1, Int((pointSize * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSide,
            pixelsHigh: pixelSide,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return source
        }
        rep.size = NSSize(width: pointSize, height: pointSize)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = ctx
            ctx.imageInterpolation = .high
            source.draw(
                in: NSRect(x: 0, y: 0, width: pointSize, height: pointSize),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
        }

        let compact = NSImage(size: NSSize(width: pointSize, height: pointSize))
        compact.addRepresentation(rep)
        return compact
    }

    private func updateLocalRule(_ rule: AppRule, for appID: String) {
        if rule.isDefault {
            rawRules.removeValue(forKey: appID)
            rules.removeValue(forKey: appID)
        } else {
            rawRules[appID] = rule
            rules[appID] = rule
        }
        if let model = ruleModels[appID], model.rule != rule {
            model.rule = rule
        }
    }

    private func pruneInactiveCaches() {
        let limit = activeApps.count + 4
        guard ruleModels.count > limit || iconCache.count > limit || missingIconAppIDs.count > limit else {
            return
        }
        let activeIDs = Set(activeApps.map(\.id))
        if ruleModels.count > limit {
            ruleModels = ruleModels.filter { id, _ in
                id == SystemAlertSound.appID || activeIDs.contains(id) || rawRules[id] != nil
            }
        }
        if iconCache.count > limit {
            iconCache = iconCache.filter { id, _ in
                activeIDs.contains(id)
            }
        }
        if missingIconAppIDs.count > limit {
            missingIconAppIDs.formIntersection(activeIDs)
        }
    }
}
