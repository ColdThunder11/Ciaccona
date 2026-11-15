import AppKit
import CoreAudio
import Foundation

@AudioControlActor
final class ProcessMonitor {
    private(set) var apps: [AudioApp] = []
    private(set) var systemAlertApp: AudioApp = SystemAlertSound.makeApp(from: [])
    var includeAllProcesses: Bool = false
    var onAppsChanged: (@AudioControlActor @Sendable ([AudioApp]) -> Void)?
    var onProcessRunningChanged: (@AudioControlActor @Sendable (String) -> Void)?

    private let metadataProvider: ProcessMetadataProvider
    private var listToken: ListenerToken?
    private var processTokens: [AudioObjectID: ListenerToken] = [:]
    private var processesByID: [AudioObjectID: AudioProcess] = [:]
    private var selfProcessIDs: Set<AudioObjectID> = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let selfPID = ProcessInfo.processInfo.processIdentifier

    init(metadataProvider: ProcessMetadataProvider = LiveProcessMetadataProvider()) {
        self.metadataProvider = metadataProvider
    }

    func setIncludeAllProcesses(_ includeAll: Bool) {
        guard includeAllProcesses != includeAll else { return }
        includeAllProcesses = includeAll
        rebuildApps(from: processesByID.values.sorted { $0.id < $1.id })
    }

    func start() {
        stop()
        refresh()

        let q = AudioControlActor.queue
        listToken = AudioObject.system.observe(kAudioHardwarePropertyProcessObjectList, queue: q) { [weak self] in
            AudioControlActor.assumeIsolatedOnQueue {
                self?.refresh()
            }
        }

        let center = NSWorkspace.shared.notificationCenter
        let launchObs = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @AudioControlActor in
                self?.refresh()
            }
        }
        let termObs = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @AudioControlActor in
                self?.refresh()
            }
        }
        workspaceObservers = [launchObs, termObs]
    }

    func stop() {
        listToken?.invalidate()
        listToken = nil
        processTokens.values.forEach { $0.invalidate() }
        processTokens.removeAll()
        processesByID.removeAll()
        selfProcessIDs.removeAll()
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    func refresh() {
        let ids: [AudioObjectID] = (try? AudioObject.system.getArray(kAudioHardwarePropertyProcessObjectList)) ?? []
        let liveIDs = Set(ids)
        processesByID = processesByID.filter { liveIDs.contains($0.key) }
        selfProcessIDs.formIntersection(liveIDs)

        var processes: [AudioProcess] = []
        processes.reserveCapacity(ids.count)

        for id in ids where !selfProcessIDs.contains(id) {
            if var cached = processesByID[id] {
                let obj = AudioObject(id: id)
                if obj.isValid {
                    let runningRaw: UInt32 = (try? obj.get(kAudioProcessPropertyIsRunningOutput)) ?? 0
                    cached.isRunningOutput = runningRaw != 0
                    processesByID[id] = cached
                    processes.append(cached)
                } else {
                    processesByID.removeValue(forKey: id)
                }
            } else if let proc = AudioProcess.load(id: id) {
                if proc.pid == selfPID {
                    selfProcessIDs.insert(id)
                } else {
                    processesByID[id] = proc
                    processes.append(proc)
                }
            }
        }

        syncProcessObservers(for: processes)
        rebuildApps(from: processes)
    }

    /// Seeds cached process state directly for deterministic unit tests without hitting live HAL objects.
    func updateProcessesSnapshot(_ processes: [AudioProcess]) {
        let filtered = processes.filter { $0.pid != selfPID }
        processesByID = Dictionary(uniqueKeysWithValues: filtered.map { ($0.id, $0) })
        selfProcessIDs.removeAll()
        rebuildApps(from: filtered)
    }

    private func rebuildApps(from processes: [AudioProcess]) {
        let systemAlertProcesses = processes.filter { $0.bundleID == SystemAlertSound.appID }
        systemAlertApp = SystemAlertSound.makeApp(from: systemAlertProcesses)
        apps = AppGrouping.group(
            processes: processes,
            provider: metadataProvider,
            regularAppsOnly: !includeAllProcesses
        )
        onAppsChanged?(apps)
    }

    private func handleProcessRunningOutputChanged(_ procID: AudioObjectID) {
        guard !selfProcessIDs.contains(procID) else { return }
        guard processesByID[procID] != nil else {
            refresh()
            return
        }
        let runningRaw: UInt32 = (try? AudioObject(id: procID).get(kAudioProcessPropertyIsRunningOutput)) ?? 0
        applyRunningOutputChange(for: procID, isRunningOutput: runningRaw != 0)
    }

    func applyRunningOutputChange(for procID: AudioObjectID, isRunningOutput: Bool) {
        guard var proc = processesByID[procID] else { return }
        guard proc.isRunningOutput != isRunningOutput else { return }

        proc.isRunningOutput = isRunningOutput
        processesByID[procID] = proc

        var updatedSystemAlert = false
        if proc.bundleID == SystemAlertSound.appID,
           let sysProcIndex = systemAlertApp.processes.firstIndex(where: { $0.id == procID }) {
            systemAlertApp.processes[sysProcIndex].isRunningOutput = isRunningOutput
            systemAlertApp.isPlaying = systemAlertApp.processes.contains(where: \.isRunningOutput)
            updatedSystemAlert = true
        }

        guard let appIndex = apps.firstIndex(where: { $0.processes.contains { $0.id == procID } }),
              let procIndex = apps[appIndex].processes.firstIndex(where: { $0.id == procID }) else {
            if !updatedSystemAlert && isRunningOutput {
                rebuildApps(from: processesByID.values.sorted { $0.id < $1.id })
                return
            }
            if updatedSystemAlert {
                onProcessRunningChanged?(SystemAlertSound.appID)
            }
            return
        }

        apps[appIndex].processes[procIndex].isRunningOutput = isRunningOutput
        apps[appIndex].isPlaying = apps[appIndex].processes.contains(where: \.isRunningOutput)
        let updatedAppID = apps[appIndex].id

        // Hidden Safari/WebKit visibility depends on `app.isPlaying || safariIsRunning`.
        if updatedAppID == "com.apple.WebKit" && !apps[appIndex].isPlaying && !includeAllProcesses {
            rebuildApps(from: processesByID.values.sorted { $0.id < $1.id })
            return
        }

        apps = AppGrouping.sortApps(apps)
        onProcessRunningChanged?(updatedAppID)
        if updatedSystemAlert, updatedAppID != SystemAlertSound.appID {
            onProcessRunningChanged?(SystemAlertSound.appID)
        }
    }

    private func syncProcessObservers(for processes: [AudioProcess]) {
        let currentIDs = Set(processes.map(\.id))
        for (id, token) in processTokens where !currentIDs.contains(id) {
            token.invalidate()
            processTokens.removeValue(forKey: id)
        }

        let q = AudioControlActor.queue
        for proc in processes where processTokens[proc.id] == nil {
            let procID = proc.id
            // coreaudiod delivers notifications for `kAudioProcessPropertyIsRunning` ('pir?'),
            // not `kAudioProcessPropertyIsRunningOutput` ('piro'); the handler still reads
            // `kAudioProcessPropertyIsRunningOutput` to filter out input-only activity.
            if let token = AudioObject(id: procID).observe(
                kAudioProcessPropertyIsRunning,
                queue: q,
                handler: { [weak self] in
                    AudioControlActor.assumeIsolatedOnQueue {
                        self?.handleProcessRunningOutputChanged(procID)
                    }
                }
            ) {
                processTokens[procID] = token
            }
        }
    }
}
