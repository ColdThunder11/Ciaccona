import AppKit
import Darwin
import Foundation

struct AudioApp: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let bundleID: String?
    var processes: [AudioProcess]
    var isPlaying: Bool
    /// Non-nil when resolved from a real app on disk or running application.
    var mainPID: pid_t?
    var isRegularApp: Bool = true

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
            && lhs.displayName == rhs.displayName
            && lhs.bundleID == rhs.bundleID
            && lhs.processes == rhs.processes
            && lhs.isPlaying == rhs.isPlaying
            && lhs.mainPID == rhs.mainPID
            && lhs.isRegularApp == rhs.isRegularApp
    }
}

struct ProcessMetadata: Sendable {
    let pid: pid_t
    let parentPID: pid_t?
    let bundleID: String?
    let localizedName: String?
    let isRegularApp: Bool
}

protocol ProcessMetadataProvider {
    func metadata(for pid: pid_t) -> ProcessMetadata?
    func regularApplications() -> [ProcessMetadata]
}

struct LiveProcessMetadataProvider: ProcessMetadataProvider {
    func metadata(for pid: pid_t) -> ProcessMetadata? {
        guard pid > 0 else { return nil }
        let running = NSRunningApplication(processIdentifier: pid)
        let ppid = Self.parentPID(of: pid)
        let name = running?.localizedName ?? Self.processName(of: pid)
        return ProcessMetadata(
            pid: pid,
            parentPID: ppid,
            bundleID: running?.bundleIdentifier,
            localizedName: name,
            isRegularApp: running?.activationPolicy == .regular
        )
    }

    func regularApplications() -> [ProcessMetadata] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map {
                ProcessMetadata(
                    pid: $0.processIdentifier,
                    parentPID: nil,
                    bundleID: $0.bundleIdentifier,
                    localizedName: $0.localizedName,
                    isRegularApp: true
                )
            }
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 && ppid != pid ? ppid : nil
    }

    private static func processName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_name(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(len)).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

enum SystemAlertSound {
    static let appID = "com.apple.systemsoundserverd"

    static var displayName: String {
        displayName(language: nil)
    }

    static func displayName(language: AppLanguage?) -> String {
        L10n.tr("app.system_alert_sound", defaultValue: "System Alert Sound", language: language)
    }

    static func makeApp(from processes: [AudioProcess]) -> AudioApp {
        AudioApp(
            id: appID,
            displayName: displayName,
            bundleID: appID,
            processes: processes,
            isPlaying: processes.contains(where: \.isRunningOutput),
            mainPID: processes.first?.pid,
            isRegularApp: false
        )
    }
}

enum AppGrouping {
    private static let sharedWebKitBundleIDs: Set<String> = [
        "com.apple.WebKit.GPU",
        "com.apple.WebKit.WebContent",
        "com.apple.WebKit.Networking"
    ]

    private final class CachingProcessMetadataProvider: ProcessMetadataProvider {
        private let base: ProcessMetadataProvider
        private var cache: [pid_t: ProcessMetadata?] = [:]
        private lazy var cachedRegulars: [ProcessMetadata] = base.regularApplications()

        init(base: ProcessMetadataProvider) {
            self.base = base
        }

        func metadata(for pid: pid_t) -> ProcessMetadata? {
            if let hit = cache[pid] {
                return hit
            }
            let value = base.metadata(for: pid)
            cache[pid] = value
            return value
        }

        func regularApplications() -> [ProcessMetadata] {
            cachedRegulars
        }
    }

    static func group(
        processes: [AudioProcess],
        provider: ProcessMetadataProvider = LiveProcessMetadataProvider(),
        regularAppsOnly: Bool = false
    ) -> [AudioApp] {
        let cachedProvider = CachingProcessMetadataProvider(base: provider)
        let regularApps = cachedProvider.regularApplications()
        let regularBundleCandidates: [(ProcessMetadata, String)] = regularApps
            .compactMap { app -> (ProcessMetadata, String)? in
                guard let b = app.bundleID, !b.isEmpty else { return nil }
                return (app, b)
            }
            .sorted { $0.1.count > $1.1.count }
        var grouped: [String: AudioApp] = [:]

        for proc in processes where proc.bundleID != SystemAlertSound.appID {
            let resolved = resolveOwner(
                for: proc,
                regularBundleCandidates: regularBundleCandidates,
                provider: cachedProvider
            )
            if var existing = grouped[resolved.groupID] {
                existing.processes.append(proc)
                existing.isPlaying = existing.isPlaying || proc.isRunningOutput
                existing.isRegularApp = existing.isRegularApp || resolved.isRegularApp
                grouped[resolved.groupID] = existing
            } else {
                grouped[resolved.groupID] = AudioApp(
                    id: resolved.groupID,
                    displayName: resolved.displayName,
                    bundleID: resolved.bundleID,
                    processes: [proc],
                    isPlaying: proc.isRunningOutput,
                    mainPID: resolved.mainPID,
                    isRegularApp: resolved.isRegularApp
                )
            }
        }

        let safariIsRunning = regularApps.contains { $0.bundleID == "com.apple.Safari" }
        let values = regularAppsOnly
            ? grouped.values.filter { app in
                app.isRegularApp || (app.id == "com.apple.WebKit" && (app.isPlaying || safariIsRunning))
            }
            : Array(grouped.values)

        return sortApps(Array(values))
    }

    static func sortApps(_ apps: [AudioApp]) -> [AudioApp] {
        apps.sorted { lhs, rhs in
            if lhs.isPlaying != rhs.isPlaying {
                return lhs.isPlaying && !rhs.isPlaying
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private struct ResolvedOwner {
        let groupID: String
        let displayName: String
        let bundleID: String?
        let mainPID: pid_t?
        let isRegularApp: Bool
    }

    private static func resolveOwner(
        for process: AudioProcess,
        regularBundleCandidates: [(ProcessMetadata, String)],
        provider: ProcessMetadataProvider
    ) -> ResolvedOwner {
        // 0. Special-case shared WebKit GPU/WebContent processes (Section 6.2 warning).
        if let bid = process.bundleID, sharedWebKitBundleIDs.contains(bid) {
            // Try parent chain first in case it's owned by a regular app; otherwise show Safari / WebKit.
            if let parentOwner = findRegularAncestor(startingAt: process.pid, provider: provider) {
                let id = parentOwner.bundleID ?? "pid:\(parentOwner.pid)"
                return ResolvedOwner(
                    groupID: id,
                    displayName: parentOwner.localizedName ?? id,
                    bundleID: parentOwner.bundleID,
                    mainPID: parentOwner.pid,
                    isRegularApp: true
                )
            }
            return ResolvedOwner(
                groupID: "com.apple.WebKit",
                displayName: "Safari / WebKit",
                bundleID: "com.apple.WebKit",
                mainPID: process.pid,
                isRegularApp: false
            )
        }

        // 1 & 2. Direct regular app or walk parent process chain via sysctl(KERN_PROC_PID).
        if let ancestor = findRegularAncestor(startingAt: process.pid, provider: provider) {
            let id = ancestor.bundleID ?? "pid:\(ancestor.pid)"
            return ResolvedOwner(
                groupID: id,
                displayName: ancestor.localizedName ?? ancestor.bundleID ?? "PID \(ancestor.pid)",
                bundleID: ancestor.bundleID,
                mainPID: ancestor.pid,
                isRegularApp: true
            )
        }

        // 3. Bundle ID prefix matching (e.g. com.google.Chrome.helper -> com.google.Chrome).
        if let procBundle = process.bundleID {
            if let best = regularBundleCandidates.first(where: { _, hostBundle in
                procBundle == hostBundle || procBundle.hasPrefix(hostBundle + ".")
            }) {
                return ResolvedOwner(
                    groupID: best.1,
                    displayName: best.0.localizedName ?? best.1,
                    bundleID: best.1,
                    mainPID: best.0.pid,
                    isRegularApp: true
                )
            }
        }

        // 4. Fallback: standalone entry.
        let meta = provider.metadata(for: process.pid)
        let bundle = process.bundleID ?? meta?.bundleID
        let groupID = bundle ?? "pid:\(process.pid)"
        let name = meta?.localizedName ?? bundle ?? "Process \(process.pid)"
        return ResolvedOwner(
            groupID: groupID,
            displayName: name,
            bundleID: bundle,
            mainPID: process.pid,
            isRegularApp: meta?.isRegularApp ?? false
        )
    }

    private static func findRegularAncestor(
        startingAt pid: pid_t,
        provider: ProcessMetadataProvider
    ) -> ProcessMetadata? {
        var currentPID: pid_t? = pid
        var visited: Set<pid_t> = []
        let maxDepth = 16

        for _ in 0..<maxDepth {
            guard let pid = currentPID, pid > 1, !visited.contains(pid) else {
                return nil
            }
            visited.insert(pid)
            guard let meta = provider.metadata(for: pid) else {
                return nil
            }
            if meta.isRegularApp {
                return meta
            }
            currentPID = meta.parentPID
        }
        return nil
    }
}
