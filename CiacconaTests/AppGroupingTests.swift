import CoreAudio
import Testing
@testable import Ciaccona

private struct MockProcessProvider: ProcessMetadataProvider {
    let items: [pid_t: ProcessMetadata]
    let regulars: [ProcessMetadata]

    func metadata(for pid: pid_t) -> ProcessMetadata? {
        items[pid]
    }

    func regularApplications() -> [ProcessMetadata] {
        regulars
    }
}

@Suite("AppGrouping Tests")
struct AppGroupingTests {
    @Test("Direct regular app and child helper processes merge into one AudioApp")
    func mergesHelperViaParentChain() {
        let chromeMain = ProcessMetadata(
            pid: 100,
            parentPID: 1,
            bundleID: "com.google.Chrome",
            localizedName: "Google Chrome",
            isRegularApp: true
        )
        let chromeHelper = ProcessMetadata(
            pid: 101,
            parentPID: 100,
            bundleID: "com.google.Chrome.helper",
            localizedName: "Google Chrome Helper",
            isRegularApp: false
        )
        let provider = MockProcessProvider(
            items: [100: chromeMain, 101: chromeHelper],
            regulars: [chromeMain]
        )

        let processes = [
            AudioProcess(id: 10, pid: 100, bundleID: "com.google.Chrome", isRunningOutput: false),
            AudioProcess(id: 11, pid: 101, bundleID: "com.google.Chrome.helper", isRunningOutput: true)
        ]

        let grouped = AppGrouping.group(processes: processes, provider: provider)
        #expect(grouped.count == 1)
        #expect(grouped[0].id == "com.google.Chrome")
        #expect(grouped[0].displayName == "Google Chrome")
        #expect(grouped[0].processes.count == 2)
        #expect(grouped[0].isPlaying == true)
    }

    @Test("Bundle ID prefix fallback matches when parent chain is broken")
    func bundleIDPrefixFallback() {
        let electronApp = ProcessMetadata(
            pid: 200,
            parentPID: 1,
            bundleID: "com.tinyspeck.slackmacgap",
            localizedName: "Slack",
            isRegularApp: true
        )
        let orphanHelper = ProcessMetadata(
            pid: 205,
            parentPID: 1,
            bundleID: "com.tinyspeck.slackmacgap.helper",
            localizedName: "Slack Helper",
            isRegularApp: false
        )
        let provider = MockProcessProvider(
            items: [200: electronApp, 205: orphanHelper],
            regulars: [electronApp]
        )

        let processes = [
            AudioProcess(id: 21, pid: 205, bundleID: "com.tinyspeck.slackmacgap.helper", isRunningOutput: true)
        ]

        let grouped = AppGrouping.group(processes: processes, provider: provider)
        #expect(grouped.count == 1)
        #expect(grouped[0].id == "com.tinyspeck.slackmacgap")
        #expect(grouped[0].displayName == "Slack")
    }

    @Test("Shared WebKit process without regular ancestor maps to Safari / WebKit")
    func sharedWebKitFallback() {
        let webkit = ProcessMetadata(
            pid: 300,
            parentPID: 1,
            bundleID: "com.apple.WebKit.GPU",
            localizedName: "WebKit GPU",
            isRegularApp: false
        )
        let provider = MockProcessProvider(items: [300: webkit], regulars: [])
        let processes = [
            AudioProcess(id: 31, pid: 300, bundleID: "com.apple.WebKit.GPU", isRunningOutput: true)
        ]

        let grouped = AppGrouping.group(processes: processes, provider: provider)
        #expect(grouped.count == 1)
        #expect(grouped[0].id == "com.apple.WebKit")
        #expect(grouped[0].displayName == "Safari / WebKit")
    }

    @Test("Playing apps sort ahead of idle apps")
    func playingAppsSortFirst() {
        let appA = ProcessMetadata(pid: 400, parentPID: 1, bundleID: "com.a.app", localizedName: "Alpha", isRegularApp: true)
        let appZ = ProcessMetadata(pid: 401, parentPID: 1, bundleID: "com.z.app", localizedName: "Zeta", isRegularApp: true)
        let provider = MockProcessProvider(items: [400: appA, 401: appZ], regulars: [appA, appZ])

        let processes = [
            AudioProcess(id: 41, pid: 400, bundleID: "com.a.app", isRunningOutput: false),
            AudioProcess(id: 42, pid: 401, bundleID: "com.z.app", isRunningOutput: true)
        ]

        let grouped = AppGrouping.group(processes: processes, provider: provider)
        #expect(grouped.map(\.displayName) == ["Zeta", "Alpha"])
    }

    @Test("regularAppsOnly hides system daemons and accessory apps while keeping regular apps")
    func regularAppsOnlyFiltersNonRegular() {
        let chromeMain = ProcessMetadata(pid: 500, parentPID: 1, bundleID: "com.google.Chrome", localizedName: "Google Chrome", isRegularApp: true)
        let chromeHelper = ProcessMetadata(pid: 501, parentPID: 500, bundleID: "com.google.Chrome.helper", localizedName: "Chrome Helper", isRegularApp: false)
        let daemon = ProcessMetadata(pid: 502, parentPID: 1, bundleID: "com.apple.audiomxd", localizedName: "audiomxd", isRegularApp: false)
        let accessory = ProcessMetadata(pid: 503, parentPID: 1, bundleID: "com.apple.controlcenter", localizedName: "控制中心", isRegularApp: false)
        let idleWebKit = ProcessMetadata(pid: 504, parentPID: 1, bundleID: "com.apple.WebKit.GPU", localizedName: "WebKit GPU", isRegularApp: false)

        let provider = MockProcessProvider(
            items: [500: chromeMain, 501: chromeHelper, 502: daemon, 503: accessory, 504: idleWebKit],
            regulars: [chromeMain]
        )
        let processes = [
            AudioProcess(id: 50, pid: 501, bundleID: "com.google.Chrome.helper", isRunningOutput: false),
            AudioProcess(id: 51, pid: 502, bundleID: "com.apple.audiomxd", isRunningOutput: false),
            AudioProcess(id: 52, pid: 503, bundleID: "com.apple.controlcenter", isRunningOutput: false),
            AudioProcess(id: 53, pid: 504, bundleID: "com.apple.WebKit.GPU", isRunningOutput: false)
        ]

        let regularOnly = AppGrouping.group(processes: processes, provider: provider, regularAppsOnly: true)
        #expect(regularOnly.map(\.id) == ["com.google.Chrome"])

        let all = AppGrouping.group(processes: processes, provider: provider, regularAppsOnly: false)
        #expect(all.count == 4)
    }

    @Test("systemsoundserverd is excluded from regular and all-process grouping to avoid duplicating System Alert row")
    func excludesSystemSoundServerFromGroupedApps() {
        let sysSound = ProcessMetadata(
            pid: 372,
            parentPID: 1,
            bundleID: SystemAlertSound.appID,
            localizedName: "systemsoundserverd",
            isRegularApp: false
        )
        let provider = MockProcessProvider(items: [372: sysSound], regulars: [])
        let processes = [
            AudioProcess(id: 97, pid: 372, bundleID: SystemAlertSound.appID, isRunningOutput: true)
        ]

        #expect(AppGrouping.group(processes: processes, provider: provider, regularAppsOnly: false).isEmpty)
        let alertApp = SystemAlertSound.makeApp(from: processes)
        #expect(alertApp.id == SystemAlertSound.appID)
        #expect(alertApp.displayName == SystemAlertSound.displayName)
        #expect(alertApp.isPlaying == true)
    }

    @Test("AppGrouping caches per-PID metadata lookups and regular applications within a grouping pass")
    func cachesMetadataLookupsPerGroupingPass() {
        final class CountingProvider: ProcessMetadataProvider {
            let items: [pid_t: ProcessMetadata]
            let regulars: [ProcessMetadata]
            var metadataLookups: [pid_t: Int] = [:]
            var regularCalls = 0

            init(items: [pid_t: ProcessMetadata], regulars: [ProcessMetadata]) {
                self.items = items
                self.regulars = regulars
            }

            func metadata(for pid: pid_t) -> ProcessMetadata? {
                metadataLookups[pid, default: 0] += 1
                return items[pid]
            }

            func regularApplications() -> [ProcessMetadata] {
                regularCalls += 1
                return regulars
            }
        }

        let main = ProcessMetadata(pid: 800, parentPID: 1, bundleID: "com.google.Chrome", localizedName: "Google Chrome", isRegularApp: true)
        let h1 = ProcessMetadata(pid: 801, parentPID: 800, bundleID: "com.google.Chrome.helper", localizedName: "Helper 1", isRegularApp: false)
        let h2 = ProcessMetadata(pid: 802, parentPID: 800, bundleID: "com.google.Chrome.helper", localizedName: "Helper 2", isRegularApp: false)
        let h3 = ProcessMetadata(pid: 803, parentPID: 800, bundleID: "com.google.Chrome.helper", localizedName: "Helper 3", isRegularApp: false)
        let provider = CountingProvider(
            items: [800: main, 801: h1, 802: h2, 803: h3],
            regulars: [main]
        )

        let processes = [
            AudioProcess(id: 81, pid: 801, bundleID: "com.google.Chrome.helper", isRunningOutput: true),
            AudioProcess(id: 82, pid: 802, bundleID: "com.google.Chrome.helper", isRunningOutput: false),
            AudioProcess(id: 83, pid: 803, bundleID: "com.google.Chrome.helper", isRunningOutput: false)
        ]

        let grouped = AppGrouping.group(processes: processes, provider: provider)
        #expect(grouped.count == 1)
        #expect(provider.regularCalls == 1)
        // Shared parent PID 800 should only be queried once across all three helpers.
        #expect(provider.metadataLookups[800] == 1)
    }
}

@Suite("ProcessMonitor Incremental Tests")
struct ProcessMonitorTests {
    @Test("applyRunningOutputChange updates state and sorting without firing full onAppsChanged rebuild")
    @AudioControlActor
    func incrementalRunningOutputToggle() async {
        let alpha = ProcessMetadata(pid: 600, parentPID: 1, bundleID: "com.test.alpha", localizedName: "Alpha", isRegularApp: true)
        let zeta = ProcessMetadata(pid: 601, parentPID: 1, bundleID: "com.test.zeta", localizedName: "Zeta", isRegularApp: true)
        let provider = MockProcessProvider(items: [600: alpha, 601: zeta], regulars: [alpha, zeta])

        let monitor = ProcessMonitor(metadataProvider: provider)
        var fullRebuildCount = 0
        var incrementalAppIDs: [String] = []
        monitor.onAppsChanged = { _ in fullRebuildCount += 1 }
        monitor.onProcessRunningChanged = { incrementalAppIDs.append($0) }

        monitor.updateProcessesSnapshot([
            AudioProcess(id: 61, pid: 600, bundleID: "com.test.alpha", isRunningOutput: false),
            AudioProcess(id: 62, pid: 601, bundleID: "com.test.zeta", isRunningOutput: false)
        ])
        #expect(fullRebuildCount == 1)
        #expect(monitor.apps.map(\.id) == ["com.test.alpha", "com.test.zeta"])

        // No-op update with identical value should not notify.
        monitor.applyRunningOutputChange(for: 62, isRunningOutput: false)
        #expect(fullRebuildCount == 1)
        #expect(incrementalAppIDs.isEmpty)

        // Starting playback on Zeta moves it first via incremental path only.
        monitor.applyRunningOutputChange(for: 62, isRunningOutput: true)
        #expect(fullRebuildCount == 1)
        #expect(incrementalAppIDs == ["com.test.zeta"])
        #expect(monitor.apps.map(\.id) == ["com.test.zeta", "com.test.alpha"])
        #expect(monitor.apps[0].isPlaying == true)

        // Stopping playback restores alphabetical order via incremental path only.
        monitor.applyRunningOutputChange(for: 62, isRunningOutput: false)
        #expect(fullRebuildCount == 1)
        #expect(incrementalAppIDs == ["com.test.zeta", "com.test.zeta"])
        #expect(monitor.apps.map(\.id) == ["com.test.alpha", "com.test.zeta"])
        #expect(monitor.apps[1].isPlaying == false)
    }

    @Test("Hidden WebKit falls back to rebuild when playback starts or stops")
    @AudioControlActor
    func webKitVisibilityFallback() {
        let webkit = ProcessMetadata(pid: 700, parentPID: 1, bundleID: "com.apple.WebKit.GPU", localizedName: "WebKit GPU", isRegularApp: false)
        let provider = MockProcessProvider(items: [700: webkit], regulars: [])

        let monitor = ProcessMonitor(metadataProvider: provider)
        var fullRebuildCount = 0
        monitor.onAppsChanged = { _ in fullRebuildCount += 1 }

        monitor.updateProcessesSnapshot([
            AudioProcess(id: 71, pid: 700, bundleID: "com.apple.WebKit.GPU", isRunningOutput: false)
        ])
        #expect(monitor.apps.isEmpty)
        #expect(fullRebuildCount == 1)

        monitor.applyRunningOutputChange(for: 71, isRunningOutput: true)
        #expect(monitor.apps.map(\.id) == ["com.apple.WebKit"])
        #expect(fullRebuildCount == 2)

        monitor.applyRunningOutputChange(for: 71, isRunningOutput: false)
        #expect(monitor.apps.isEmpty)
        #expect(fullRebuildCount == 3)
    }

    @Test("AudioControlActor.assumeIsolatedOnQueue executes synchronously on the actor queue")
    func assumeIsolatedOnActorQueue() async {
        await withCheckedContinuation { continuation in
            AudioControlActor.queue.async {
                AudioControlActor.assumeIsolatedOnQueue {
                    let monitor = ProcessMonitor()
                    #expect(monitor.apps.isEmpty)
                    continuation.resume()
                }
            }
        }
    }
}
