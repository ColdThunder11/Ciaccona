import AppKit
import CoreAudio
import Foundation
import OSLog

enum RoutingDecision: Equatable, Sendable {
    /// Volume == 1.0, unmuted, and following system default -> zero-overhead passthrough (no Tap/Aggregate).
    case passthrough
    /// Requires an active AppAudioSession with the given initial gain & mute flags.
    case activeSession(gain: Float, muted: Bool)

    static func decide(rule: AppRule) -> RoutingDecision {
        if rule.isDefault {
            return .passthrough
        }
        return .activeSession(gain: rule.volume, muted: rule.muted)
    }
}

struct RoutingSnapshot: Sendable {
    var activeApps: [AudioApp]
    var systemAlertApp: AudioApp = SystemAlertSound.makeApp(from: [])
    var rules: [String: AppRule]
    var preferences: AppPreferences
    var offlineAppIDs: Set<String>
    var sessionErrors: [String: String]
}

@AudioControlActor
final class RoutingEngine {
    private static let logger = Logger(subsystem: "com.coldthunder11.ciaccona", category: "RoutingEngine")

    let deviceManager: DeviceManager
    let volumeController: GlobalVolumeController
    let processMonitor: ProcessMonitor
    let ruleStore: RuleStore

    var onDevicesChanged: (@Sendable ([AudioDevice], AudioObjectID) -> Void)?
    var onSystemAlertDeviceChanged: (@Sendable (AudioObjectID) -> Void)?
    var onSnapshotUpdated: (@Sendable (RoutingSnapshot) -> Void)?
    var onPermissionRevocationSuspected: (@Sendable () -> Void)?

    private var sessions: [String: AppAudioSession] = [:]
    private var softwareVolumeSession: AppAudioSession?
    private var idlePauseTasks: [String: Task<Void, Never>] = [:]
    private var offlineAppIDs: Set<String> = []
    private var sessionErrors: [String: String] = [:]
    private var silenceWatchdogTask: Task<Void, Never>?
    private var lastSilenceWatchdogProbeAt: ContinuousClock.Instant?
    private var wakeObserver: NSObjectProtocol?

    init(
        deviceManager: DeviceManager,
        volumeController: GlobalVolumeController,
        processMonitor: ProcessMonitor,
        ruleStore: RuleStore
    ) {
        self.deviceManager = deviceManager
        self.volumeController = volumeController
        self.processMonitor = processMonitor
        self.ruleStore = ruleStore
    }

    func start() {
        deviceManager.onDevicesChanged = { [weak self] _, _ in
            self?.handleDevicesChanged()
        }
        deviceManager.onSystemAlertDeviceChanged = { [weak self] alertID in
            self?.onSystemAlertDeviceChanged?(alertID)
        }
        deviceManager.onSampleRateChanged = { [weak self] _, uid in
            self?.handleSampleRateChanged(deviceUID: uid)
        }
        deviceManager.onServiceRestarted = { [weak self] in
            self?.handleCoreAudioRestarted()
        }
        processMonitor.onAppsChanged = { [weak self] _ in
            self?.reconcileAllSessions()
        }
        processMonitor.onProcessRunningChanged = { [weak self] appID in
            self?.handleAppRunningChanged(appID: appID)
        }

        volumeController.softwareRuleProvider = { [ruleStore] uid in
            ruleStore.deviceVolumeRule(for: uid)
        }
        deviceManager.start()
        onDevicesChanged?(deviceManager.outputDevices, deviceManager.defaultOutputDeviceID)
        onSystemAlertDeviceChanged?(deviceManager.defaultSystemOutputDeviceID)
        processMonitor.includeAllProcesses = ruleStore.preferences.showAllProcesses
        processMonitor.start()
        bindGlobalVolumeToDefault()
        startSilenceWatchdog()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @AudioControlActor in
                self?.onPermissionRevocationSuspected?()
                self?.rebuildAllSessions()
            }
        }

        reconcileAllSessions()
    }

    func stopAll() {
        silenceWatchdogTask?.cancel()
        silenceWatchdogTask = nil
        idlePauseTasks.values.forEach { $0.cancel() }
        idlePauseTasks.removeAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }

        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        softwareVolumeSession?.stop()
        softwareVolumeSession = nil
        volumeController.unbind()
        processMonitor.stop()
        deviceManager.stop()
        ruleStore.flush()
    }

    // MARK: - User Actions

    func setDefaultOutputDevice(_ deviceID: AudioObjectID) throws {
        try deviceManager.setDefaultOutputDevice(deviceID)
        syncSystemAlertHardwareDevice(for: ruleStore.rule(for: SystemAlertSound.appID).output)
        bindGlobalVolumeToDefault()
        reconcileAllSessions()
    }

    func setGlobalVolume(_ value: Float) {
        let quantized = VolumeLevel.quantize(value, max: 1.0)
        guard let dev = deviceManager.defaultOutputDevice else { return }
        if dev.canSetVolume {
            try? volumeController.setVolume(quantized, of: dev)
        } else {
            var rule = ruleStore.deviceVolumeRule(for: dev.uid)
            rule.volume = quantized
            ruleStore.setDeviceVolumeRule(rule, for: dev.uid)
            updateSoftwareVolumeForDevice(dev)
        }
    }

    func setGlobalMuted(_ muted: Bool) {
        guard let dev = deviceManager.defaultOutputDevice else { return }
        if dev.canMute {
            try? volumeController.setMuted(muted, of: dev)
        } else {
            var rule = ruleStore.deviceVolumeRule(for: dev.uid)
            rule.muted = muted
            ruleStore.setDeviceVolumeRule(rule, for: dev.uid)
            updateSoftwareVolumeForDevice(dev)
        }
    }

    func updateAppVolume(appID: String, volume: Float) {
        var rule = ruleStore.rule(for: appID)
        let quantized = VolumeLevel.quantize(volume, max: 1.5)
        guard quantized != rule.volume else { return }
        rule.volume = quantized

        if let session = sessions[appID],
           case let .activeSession(gain, _) = RoutingDecision.decide(rule: rule) {
            ruleStore.setRule(rule, for: appID)
            let devAdj = deviceSoftwareAdjustment(forUID: session.targetOutputUID)
            session.setGain(gain * devAdj.gain)
            return
        }

        applyRule(rule, for: appID)
    }

    func updateAppMuted(appID: String, muted: Bool) {
        var rule = ruleStore.rule(for: appID)
        rule.muted = muted
        applyRule(rule, for: appID)
    }

    func updateAppOutput(appID: String, target: OutputTarget) {
        var rule = ruleStore.rule(for: appID)
        rule.output = target
        applyRule(rule, for: appID, forceOutputRefresh: true)
        if appID == SystemAlertSound.appID {
            syncSystemAlertHardwareDevice(for: target)
        }
    }

    func resetAppRule(appID: String) {
        ruleStore.removeRule(for: appID)
        destroySession(for: appID)
        offlineAppIDs.remove(appID)
        sessionErrors.removeValue(forKey: appID)
        if appID == SystemAlertSound.appID {
            syncSystemAlertHardwareDevice(for: .followSystemDefault)
        }
        reconcileSoftwareVolumeSession()
        emitSnapshot()
    }

    func resetAllAppRules() {
        ruleStore.removeAllRules()
        for appID in Array(sessions.keys) {
            destroySession(for: appID)
        }
        offlineAppIDs.removeAll()
        sessionErrors.removeAll()
        syncSystemAlertHardwareDevice(for: .followSystemDefault)
        reconcileSoftwareVolumeSession()
        emitSnapshot()
    }

    func updatePreferences(_ mutate: @Sendable (inout AppPreferences) -> Void) {
        let prevBufferSize = ruleStore.preferences.bufferFrameSize
        let prevPauseIdleSessions = ruleStore.preferences.pauseIdleSessions
        ruleStore.updatePreferences(mutate)
        let newBufferSize = ruleStore.preferences.bufferFrameSize
        if newBufferSize != prevBufferSize {
            let frames = newBufferSize.frameCount
            sessions.values.forEach { $0.updateBufferFrameSize(frames) }
            softwareVolumeSession?.updateBufferFrameSize(frames)
        }
        let pauseIdle = ruleStore.preferences.pauseIdleSessions
        if !pauseIdle {
            idlePauseTasks.values.forEach { $0.cancel() }
            idlePauseTasks.removeAll()
            for session in sessions.values where !session.isIORunning {
                try? session.resumeIO()
            }
        }
        let showAll = ruleStore.preferences.showAllProcesses
        if processMonitor.includeAllProcesses != showAll {
            processMonitor.setIncludeAllProcesses(showAll)
            reconcileAllSessions()
            return
        }
        if !prevPauseIdleSessions && pauseIdle {
            reconcileAllSessions()
            return
        }
        emitSnapshot()
    }

    func retrySession(appID: String) {
        sessionErrors.removeValue(forKey: appID)
        reconcileSession(for: appID)
        reconcileSoftwareVolumeSession()
        emitSnapshot()
    }

    // MARK: - Reconciliation

    private func applyRule(_ rule: AppRule, for appID: String, forceOutputRefresh: Bool = false) {
        ruleStore.setRule(rule, for: appID)
        let decision = RoutingDecision.decide(rule: rule)

        switch decision {
        case .passthrough:
            destroySession(for: appID)
            offlineAppIDs.remove(appID)
            sessionErrors.removeValue(forKey: appID)
            reconcileSoftwareVolumeSession()
            emitSnapshot()
        case let .activeSession(gain, muted):
            if let session = sessions[appID], !forceOutputRefresh {
                let targetUID = resolveOutputUID(for: rule.output).uid ?? session.targetOutputUID
                let devAdj = deviceSoftwareAdjustment(forUID: targetUID)
                session.setGain(gain * devAdj.gain)
                session.setMuted(muted || devAdj.muted)
                if sessionErrors.removeValue(forKey: appID) != nil {
                    emitSnapshot()
                }
            } else {
                reconcileSession(for: appID)
                reconcileSoftwareVolumeSession()
                emitSnapshot()
            }
        }
    }

    private func handleAppRunningChanged(appID: String) {
        if let app = manageableApps.first(where: { $0.id == appID }) {
            if let session = sessions[appID] {
                handleOnDemandState(appID: appID, app: app, session: session)
            } else if case .activeSession = RoutingDecision.decide(rule: ruleStore.rule(for: appID)) {
                reconcileSession(for: appID)
                reconcileSoftwareVolumeSession()
            }
        }
        emitSnapshot()
    }

    private func handleDevicesChanged() {
        onDevicesChanged?(deviceManager.outputDevices, deviceManager.defaultOutputDeviceID)
        syncSystemAlertHardwareDevice(for: ruleStore.rule(for: SystemAlertSound.appID).output)
        bindGlobalVolumeToDefault()
        reconcileAllSessions()
    }

    private func bindGlobalVolumeToDefault() {
        volumeController.bind(to: deviceManager.defaultOutputDevice)
    }

    private func handleSampleRateChanged(deviceUID: String) {
        for (appID, session) in sessions where session.targetOutputUID == deviceUID {
            Self.logger.info("Rebuilding session \(appID) due to sample rate change on \(deviceUID)")
            rebuildSession(appID: appID)
        }
        if softwareVolumeSession?.targetOutputUID == deviceUID {
            Self.logger.info("Rebuilding global software volume session due to sample rate change on \(deviceUID)")
            softwareVolumeSession?.stop()
            softwareVolumeSession = nil
        }
        reconcileSoftwareVolumeSession()
        emitSnapshot()
    }

    private func handleCoreAudioRestarted() {
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        softwareVolumeSession?.stop()
        softwareVolumeSession = nil
        idlePauseTasks.values.forEach { $0.cancel() }
        idlePauseTasks.removeAll()
        onDevicesChanged?(deviceManager.outputDevices, deviceManager.defaultOutputDeviceID)
        onSystemAlertDeviceChanged?(deviceManager.defaultSystemOutputDeviceID)
        bindGlobalVolumeToDefault()
        reconcileAllSessions()
    }

    private func rebuildAllSessions() {
        let appIDs = Array(sessions.keys)
        for appID in appIDs {
            rebuildSession(appID: appID)
        }
        softwareVolumeSession?.stop()
        softwareVolumeSession = nil
        reconcileSoftwareVolumeSession()
        emitSnapshot()
    }

    private func rebuildSession(appID: String) {
        destroySession(for: appID)
        reconcileSession(for: appID)
    }

    private var manageableApps: [AudioApp] {
        [processMonitor.systemAlertApp] + processMonitor.apps
    }

    private func reconcileAllSessions() {
        let activeAppIDs = Set(manageableApps.map(\.id))

        // 1. Tear down sessions whose apps exited.
        for appID in Array(sessions.keys) where !activeAppIDs.contains(appID) {
            destroySession(for: appID)
            offlineAppIDs.remove(appID)
            sessionErrors.removeValue(forKey: appID)
        }

        // 2. Ensure active apps match their rules & target outputs.
        for app in manageableApps {
            reconcileSession(for: app.id)
        }

        // 3. Reconcile global software volume tap (excluding per-app tapped processes & Ciaccona itself).
        reconcileSoftwareVolumeSession()

        emitSnapshot()
    }

    private func reconcileSession(for appID: String) {
        guard let app = manageableApps.first(where: { $0.id == appID }) else {
            destroySession(for: appID)
            return
        }

        let rule = ruleStore.rule(for: appID)
        guard case let .activeSession(gain, muted) = RoutingDecision.decide(rule: rule) else {
            destroySession(for: appID)
            offlineAppIDs.remove(appID)
            sessionErrors.removeValue(forKey: appID)
            return
        }

        let resolvedTarget = resolveOutputUID(for: rule.output)
        if resolvedTarget.isOffline {
            offlineAppIDs.insert(appID)
        } else {
            offlineAppIDs.remove(appID)
        }

        guard let outputUID = resolvedTarget.uid else {
            destroySession(for: appID)
            sessionErrors[appID] = L10n.tr(
                "routing.error.no_output_device",
                defaultValue: "No audio output device available"
            )
            return
        }

        let processIDs = app.processes.map(\.id)
        guard !processIDs.isEmpty else {
            if appID == SystemAlertSound.appID {
                destroySession(for: appID)
            }
            return
        }

        let devAdj = deviceSoftwareAdjustment(forUID: outputUID)
        let effectiveGain = gain * devAdj.gain
        let effectiveMuted = muted || devAdj.muted

        if let existing = sessions[appID] {
            existing.setGain(effectiveGain)
            existing.setMuted(effectiveMuted)

            do {
                try existing.updateProcesses(processIDs)
                if existing.targetOutputUID != outputUID {
                    try existing.switchOutput(to: outputUID)
                }
                handleOnDemandState(appID: appID, app: app, session: existing)
                sessionErrors.removeValue(forKey: appID)
            } catch {
                Self.logger.error("Failed updating session for \(appID): \(error)")
                sessionErrors[appID] = error.localizedDescription
                destroySession(for: appID)
                onPermissionRevocationSuspected?()
            }
        } else {
            // Only create session immediately if app is currently playing OR user explicitly changed away from default.
            let session = AppAudioSession(
                appID: appID,
                initialGain: effectiveGain,
                initialMuted: effectiveMuted,
                initialBufferFrameSize: ruleStore.preferences.bufferFrameSize.frameCount
            )
            do {
                try session.start(processes: processIDs, outputDeviceUID: outputUID)
                sessions[appID] = session
                sessionErrors.removeValue(forKey: appID)
                handleOnDemandState(appID: appID, app: app, session: session)
            } catch {
                Self.logger.error("Failed starting session for \(appID): \(error)")
                sessionErrors[appID] = error.localizedDescription
                session.stop()
                onPermissionRevocationSuspected?()
            }
        }
    }

    private func deviceSoftwareAdjustment(forUID uid: String) -> (gain: Float, muted: Bool, activeForDevice: Bool) {
        guard let dev = deviceManager.defaultOutputDevice, dev.uid == uid else {
            return (1.0, false, false)
        }
        let rule = ruleStore.deviceVolumeRule(for: uid)
        let swGain: Float = dev.canSetVolume ? 1.0 : rule.volume
        let swMuted: Bool = dev.canMute ? false : rule.muted
        let active = (!dev.canSetVolume && abs(swGain - 1.0) >= 0.001) || (!dev.canMute && swMuted)
        return (swGain, swMuted, active)
    }

    private func updateSoftwareVolumeForDevice(_ dev: AudioDevice) {
        let adj = deviceSoftwareAdjustment(forUID: dev.uid)
        if adj.activeForDevice,
           let swSession = softwareVolumeSession,
           swSession.targetOutputUID == dev.uid {
            swSession.setGain(adj.gain)
            swSession.setMuted(adj.muted)
        } else {
            reconcileSoftwareVolumeSession()
        }

        for (appID, session) in sessions where session.targetOutputUID == dev.uid {
            let rule = ruleStore.rule(for: appID)
            if case let .activeSession(gain, muted) = RoutingDecision.decide(rule: rule) {
                session.setGain(gain * adj.gain)
                session.setMuted(muted || adj.muted)
            }
        }

        volumeController.refreshSnapshot(for: dev)
    }

    private func resolveSelfProcessObjectID() -> AudioObjectID? {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let objID: AudioObjectID = try? AudioObject.system.get(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            qualifier: pid
        ), objID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }
        return objID
    }

    private func reconcileSoftwareVolumeSession() {
        guard let dev = deviceManager.defaultOutputDevice else {
            softwareVolumeSession?.stop()
            softwareVolumeSession = nil
            return
        }

        let adj = deviceSoftwareAdjustment(forUID: dev.uid)
        guard adj.activeForDevice else {
            softwareVolumeSession?.stop()
            softwareVolumeSession = nil
            return
        }

        var excludedSet = Set(sessions.values.flatMap(\.tappedProcesses))
        if let selfObjID = resolveSelfProcessObjectID() {
            excludedSet.insert(selfObjID)
        }
        let excluded = Array(excludedSet).sorted()

        if let existing = softwareVolumeSession {
            if existing.targetOutputUID != dev.uid {
                existing.stop()
                softwareVolumeSession = nil
            } else {
                existing.setGain(adj.gain)
                existing.setMuted(adj.muted)
                do {
                    try existing.updateExcludedProcesses(excluded, deviceUID: dev.uid)
                    if !existing.isIORunning {
                        try existing.resumeIO()
                    }
                    return
                } catch {
                    Self.logger.error("Failed updating global software volume session for \(dev.uid): \(error)")
                    existing.stop()
                    softwareVolumeSession = nil
                }
            }
        }

        let session = AppAudioSession(
            appID: "__global_software_volume__",
            initialGain: adj.gain,
            initialMuted: adj.muted,
            initialBufferFrameSize: ruleStore.preferences.bufferFrameSize.frameCount
        )
        do {
            try session.startGlobal(
                excludingProcesses: excluded,
                tapDeviceUID: dev.uid,
                outputDeviceUID: dev.uid
            )
            softwareVolumeSession = session
        } catch {
            Self.logger.error("Failed starting global software volume session for \(dev.uid): \(error)")
            session.stop()
            softwareVolumeSession = nil
        }
    }

    private func handleOnDemandState(appID: String, app: AudioApp, session: AppAudioSession) {
        // Keep System Alert Sound IO running whenever non-default so short alert beeps are never clipped.
        if !ruleStore.preferences.pauseIdleSessions || appID == SystemAlertSound.appID {
            idlePauseTasks[appID]?.cancel()
            idlePauseTasks.removeValue(forKey: appID)
            if !session.isIORunning {
                try? session.resumeIO()
            }
            return
        }

        if app.isPlaying {
            idlePauseTasks[appID]?.cancel()
            idlePauseTasks.removeValue(forKey: appID)
            if !session.isIORunning {
                try? session.resumeIO()
            }
        } else if session.isIORunning, idlePauseTasks[appID] == nil {
            idlePauseTasks[appID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.pauseSessionIfStillIdle(appID: appID)
            }
        }
    }

    private func pauseSessionIfStillIdle(appID: String) {
        idlePauseTasks.removeValue(forKey: appID)
        guard ruleStore.preferences.pauseIdleSessions,
              let app = processMonitor.apps.first(where: { $0.id == appID }),
              !app.isPlaying,
              let session = sessions[appID] else {
            return
        }
        session.pauseIO()
    }

    private func destroySession(for appID: String) {
        idlePauseTasks[appID]?.cancel()
        idlePauseTasks.removeValue(forKey: appID)
        if let session = sessions.removeValue(forKey: appID) {
            session.stop()
        }
    }

    private func resolveOutputUID(for target: OutputTarget) -> (uid: String?, isOffline: Bool) {
        switch target {
        case .followSystemDefault:
            return (deviceManager.defaultOutputDevice?.uid, false)
        case let .device(uid, _):
            if let device = deviceManager.device(forUID: uid) {
                return (device.uid, false)
            }
            // Device unplugged -> fall back to system default and mark offline.
            return (deviceManager.defaultOutputDevice?.uid, true)
        }
    }

    private func startSilenceWatchdog() {
        silenceWatchdogTask?.cancel()
        silenceWatchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, let self else { break }

                let runningPlayingSessions = self.processMonitor.apps
                    .filter(\.isPlaying)
                    .compactMap { self.sessions[$0.id] }
                    .filter(\.isIORunning)
                guard !runningPlayingSessions.isEmpty,
                      runningPlayingSessions.allSatisfy({ $0.isSilentExceeding(seconds: 3.0) }) else {
                    continue
                }

                // Avoid re-running the heavy loopback probe every 3s for apps that legitimately stream silence.
                let now = ContinuousClock.now
                if let lastProbe = self.lastSilenceWatchdogProbeAt,
                   now - lastProbe < .seconds(60) {
                    continue
                }

                self.lastSilenceWatchdogProbeAt = now
                runningPlayingSessions.forEach { $0.resetSilenceCounter() }
                self.onPermissionRevocationSuspected?()
            }
        }
    }

    private func syncSystemAlertHardwareDevice(for target: OutputTarget) {
        let targetID: AudioObjectID?
        switch target {
        case .followSystemDefault:
            targetID = deviceManager.defaultOutputDevice?.id
        case let .device(uid, _):
            targetID = deviceManager.device(forUID: uid)?.id
        }
        guard let targetID, targetID != deviceManager.defaultSystemOutputDeviceID else { return }
        try? deviceManager.setDefaultSystemOutputDevice(targetID)
    }

    private func emitSnapshot() {
        let snapshot = RoutingSnapshot(
            activeApps: processMonitor.apps,
            systemAlertApp: processMonitor.systemAlertApp,
            rules: ruleStore.rules,
            preferences: ruleStore.preferences,
            offlineAppIDs: offlineAppIDs,
            sessionErrors: sessionErrors
        )
        onSnapshotUpdated?(snapshot)
    }
}
