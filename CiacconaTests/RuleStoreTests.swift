import AppKit
import CoreAudio
import Foundation
import Observation
import Synchronization
import Testing
@testable import Ciaccona

@Suite("RuleStore Tests")
struct RuleStoreTests {
    private func makeTempFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ciaccona-test-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    @Test("Persists rules and prunes entries reset to default")
    func persistAndPruneDefault() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = RuleStore(fileURL: url, debounceInterval: .milliseconds(20))
        store.setRule(
            AppRule(
                volume: 0.6,
                muted: false,
                output: .device(uid: "BuiltInSpeakerDevice", lastKnownName: "MacBook Pro 扬声器")
            ),
            for: "com.spotify.client"
        )
        store.setRule(
            AppRule(volume: 1.2, muted: false, output: .followSystemDefault),
            for: "us.zoom.xos"
        )
        store.flush()

        let reloaded = RuleStore(fileURL: url)
        #expect(reloaded.rule(for: "com.spotify.client").volume == 0.6)
        #expect(
            reloaded.rule(for: "com.spotify.client").output
                == .device(uid: "BuiltInSpeakerDevice", lastKnownName: "MacBook Pro 扬声器")
        )
        #expect(reloaded.rule(for: "us.zoom.xos").volume == 1.2)
        #expect(reloaded.rule(for: "us.zoom.xos").output == .followSystemDefault)

        // Resetting to default removes the entry from stored rules.
        reloaded.setRule(.default, for: "us.zoom.xos")
        reloaded.flush()

        let afterPrune = RuleStore(fileURL: url)
        #expect(afterPrune.rules["us.zoom.xos"] == nil)
        #expect(afterPrune.rules["com.spotify.client"] != nil)
    }

    @Test("Encodes followSystemDefault as string matching Section 8 schema")
    func jsonSchemaMatchesSpec() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = RuleStore(fileURL: url)
        store.setRule(AppRule(volume: 1.2, muted: false, output: .followSystemDefault), for: "us.zoom.xos")
        store.flush()

        let jsonString = try String(contentsOf: url, encoding: .utf8)
        #expect(jsonString.contains("\"followSystemDefault\""))
        #expect(jsonString.contains("\"version\" : 1"))
    }

    @Test("showAllProcesses defaults to false even on legacy preferences JSON and persists updates")
    func showAllProcessesPreference() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "version": 1,
          "rules": {},
          "preferences": {
            "linkSystemAlertDevice": true,
            "keepSessionsRunning": false,
            "launchAtLogin": false
          }
        }
        """
        try legacyJSON.data(using: .utf8)?.write(to: url)

        let store = RuleStore(fileURL: url)
        #expect(store.preferences.showAllProcesses == false)
        #expect(store.preferences.pauseIdleSessions == false)

        store.updatePreferences { $0.showAllProcesses = true }
        store.flush()

        let reloaded = RuleStore(fileURL: url)
        #expect(reloaded.preferences.showAllProcesses == true)
    }

    @Test("DeviceVolumeRule persists per-device volume, prunes defaults, and decodes legacy JSON")
    func deviceVolumeRulePersistence() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "version": 1,
          "rules": {},
          "preferences": {
            "linkSystemAlertDevice": true,
            "keepSessionsRunning": false,
            "launchAtLogin": false
          }
        }
        """
        try legacyJSON.data(using: .utf8)?.write(to: url)

        let store = RuleStore(fileURL: url)
        #expect(store.deviceVolumeRule(for: "HDMI-Display-1") == .default)

        store.setDeviceVolumeRule(DeviceVolumeRule(volume: 0.45, muted: true), for: "HDMI-Display-1")
        store.flush()

        let reloaded = RuleStore(fileURL: url)
        let loaded = reloaded.deviceVolumeRule(for: "HDMI-Display-1")
        #expect(loaded.volume == 0.45)
        #expect(loaded.muted == true)

        reloaded.setDeviceVolumeRule(.default, for: "HDMI-Display-1")
        reloaded.flush()

        let afterPrune = RuleStore(fileURL: url)
        #expect(afterPrune.deviceVolumeRule(for: "HDMI-Display-1") == .default)
        let jsonString = try String(contentsOf: url, encoding: .utf8)
        #expect(!jsonString.contains("HDMI-Display-1"))
    }

    @Test("GlobalVolumeController uses software volume and mute when device lacks hardware control")
    @AudioControlActor
    func externalControlDeviceUsesSoftwareVolume() {
        let controller = GlobalVolumeController()
        controller.softwareRuleProvider = { uid in
            if uid == "ExternalHDMI" {
                return DeviceVolumeRule(volume: 0.35, muted: true)
            }
            return .default
        }

        let hdmi = AudioDevice(
            id: AudioObjectID(999),
            uid: "ExternalHDMI",
            name: "External Monitor",
            transport: kAudioDeviceTransportTypeHDMI,
            hasOutput: true,
            outputChannelCount: 2,
            canSetVolume: false,
            canMute: false,
            sampleRate: 48000
        )

        let snap = controller.snapshot(of: hdmi)
        #expect(snap.canSetVolume == true)
        #expect(snap.canMute == true)
        #expect(snap.isSoftwareVolume == true)
        #expect(snap.isSoftwareMute == true)
        #expect(snap.volume == 0.35)
        #expect(snap.isMuted == true)
    }

    @Test("AudioBufferPreset offers 128/256/512/1024 tiers and persists in preferences")
    func bufferFrameSizePresetPersistence() throws {
        #expect(AudioBufferPreset.allCases.map(\.frameCount) == [128, 256, 512, 1024])
        #expect(AudioBufferPreset.allCases.map { $0.displayName(language: .english) } == ["Ultra Low", "Low", "Standard", "High"])
        #expect(AudioBufferPreset.allCases.map { $0.displayName(language: .simplifiedChinese) } == ["极低", "低", "标准", "较高"])

        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "version": 1,
          "rules": {},
          "preferences": {
            "linkSystemAlertDevice": true,
            "keepSessionsRunning": false,
            "launchAtLogin": false
          }
        }
        """
        try legacyJSON.data(using: .utf8)?.write(to: url)

        let store = RuleStore(fileURL: url)
        #expect(store.preferences.bufferFrameSize == .standard)

        store.updatePreferences { $0.bufferFrameSize = .high }
        store.flush()

        let reloaded = RuleStore(fileURL: url)
        #expect(reloaded.preferences.bufferFrameSize == .high)
        #expect(reloaded.preferences.bufferFrameSize.frameCount == 1024)
    }

    @Test("removeAllRules clears all app routing rules while preserving preferences")
    func removeAllRulesPreservesPreferences() throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = RuleStore(fileURL: url)
        store.setRule(AppRule(volume: 0.5, muted: false, output: .followSystemDefault), for: "com.spotify.client")
        store.setRule(
            AppRule(volume: 1.0, muted: true, output: .device(uid: "BuiltInSpeakerDevice", lastKnownName: "扬声器")),
            for: SystemAlertSound.appID
        )
        store.updatePreferences { prefs in
            prefs.showAllProcesses = true
            prefs.pauseIdleSessions = true
            prefs.bufferFrameSize = .low
        }
        store.flush()

        store.removeAllRules()
        store.flush()

        let reloaded = RuleStore(fileURL: url)
        #expect(reloaded.rules.isEmpty)
        #expect(reloaded.preferences.showAllProcesses == true)
        #expect(reloaded.preferences.pauseIdleSessions == true)
        #expect(reloaded.preferences.bufferFrameSize == .low)
    }

    @Test("AppLanguage defaults to system with English fallback and persists manual overrides")
    func languageResolutionAndPersistence() throws {
        #expect(L10n.resolvedLanguageCode(for: .english, preferredLanguages: ["zh-Hans-CN"]) == "en")
        #expect(L10n.resolvedLanguageCode(for: .simplifiedChinese, preferredLanguages: ["en-US"]) == "zh-Hans")
        #expect(L10n.resolvedLanguageCode(for: .system, preferredLanguages: ["en-US"]) == "en")
        #expect(L10n.resolvedLanguageCode(for: .system, preferredLanguages: ["zh-Hans-CN"]) == "zh-Hans")
        #expect(L10n.resolvedLanguageCode(for: .system, preferredLanguages: ["ja-JP"]) == "en")

        #expect(L10n.tr("settings.language.system", defaultValue: "Follow System", language: .english) == "Follow System")
        #expect(L10n.tr("settings.language.system", defaultValue: "Follow System", language: .simplifiedChinese) == "跟随系统")

        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = RuleStore(fileURL: url)
        #expect(store.preferences.language == .system)

        store.updatePreferences { $0.language = .english }
        store.flush()
        #expect(RuleStore(fileURL: url).preferences.language == .english)

        store.updatePreferences { $0.language = .simplifiedChinese }
        store.flush()
        #expect(RuleStore(fileURL: url).preferences.language == .simplifiedChinese)
    }

    @Test("VolumeLevel quantizes volumes to integer percents on write and load")
    func volumeIntegerPercentQuantization() throws {
        #expect(VolumeLevel.quantize(1.001449, max: 1.5) == 1.0)
        #expect(VolumeLevel.quantize(0.654, max: 1.0) == 0.65)
        #expect(VolumeLevel.quantize(0.656, max: 1.0) == 0.66)
        #expect(VolumeLevel.percent(1.001449, max: 1.5) == 100)

        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let legacyJSON = """
        {
          "version": 1,
          "rules": {
            "com.google.Chrome": { "volume": 1.001449, "muted": false, "output": "followSystemDefault" },
            "com.test.app": { "volume": 0.424, "muted": false, "output": "followSystemDefault" }
          },
          "deviceVolumes": {
            "HDMI-1": { "volume": 0.996, "muted": false }
          }
        }
        """
        try legacyJSON.data(using: .utf8)?.write(to: url)

        let store = RuleStore(fileURL: url)
        #expect(store.rules["com.google.Chrome"] == nil)
        #expect(store.rule(for: "com.test.app").volume == 0.42)
        #expect(store.deviceVolumeRule(for: "HDMI-1") == .default)

        store.setRule(AppRule(volume: 0.746, muted: false, output: .followSystemDefault), for: "com.test.app")
        #expect(store.rule(for: "com.test.app").volume == 0.75)
    }

    @Test("RuleStore coalesces rapid volume updates into final debounced disk write")
    func coalescedDebouncedSaveWritesLatestRule() async throws {
        let url = makeTempFileURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let store = RuleStore(fileURL: url, debounceInterval: .milliseconds(30))
        for pct in 20...75 {
            store.setRule(
                AppRule(volume: Float(pct) / 100.0, muted: false, output: .followSystemDefault),
                for: "com.google.Chrome"
            )
        }

        // Wait past debounce window so the coalesced save loop persists the final state.
        try await Task.sleep(for: .milliseconds(120))
        let reloaded = RuleStore(fileURL: url)
        #expect(reloaded.rule(for: "com.google.Chrome").volume == 0.75)
    }

    @Test("AppState.ruleModel isolates SwiftUI observation per app during volume updates")
    @MainActor
    func appStateRuleModelObservationIsolation() {
        let state = AppState()
        let chromeChanged = Mutex(false)
        let safariChanged = Mutex(false)

        withObservationTracking {
            _ = state.ruleModel(for: "com.google.Chrome").rule
        } onChange: {
            chromeChanged.withLock { $0 = true }
        }

        withObservationTracking {
            _ = state.ruleModel(for: "com.apple.Safari").rule
        } onChange: {
            safariChanged.withLock { $0 = true }
        }

        state.setAppVolume(0.42, for: "com.google.Chrome")

        #expect(chromeChanged.withLock { $0 } == true)
        #expect(safariChanged.withLock { $0 } == false)
        #expect(state.ruleModel(for: "com.google.Chrome").rule.volume == 0.42)
    }

    @Test("AppState.compactIcon downsamples oversized icons to single 40x40 bitmap representation")
    @MainActor
    func compactIconDownsamplesRepresentation() {
        let largeRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 512,
            pixelsHigh: 512,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        largeRep.size = NSSize(width: 512, height: 512)
        let source = NSImage(size: NSSize(width: 512, height: 512))
        source.addRepresentation(largeRep)

        let compact = AppState.compactIcon(from: source)
        #expect(compact.size == NSSize(width: 20, height: 20))
        #expect(compact.representations.count == 1)
        let bitmap = compact.representations.first as? NSBitmapImageRep
        #expect(bitmap?.pixelsWide == 40)
        #expect(bitmap?.pixelsHigh == 40)
    }

    @Test("SingleInstanceGuard prevents duplicate lock ownership until released")
    func singleInstanceGuardMutualExclusion() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ciaccona-lock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let lockURL = tempDir.appendingPathComponent(".instance.lock")

        let first = SingleInstanceGuard(lockFileURL: lockURL)
        let second = SingleInstanceGuard(lockFileURL: lockURL)

        #expect(first.acquire(bundleIdentifier: nil, currentPID: 1001) == true)
        #expect(second.acquire(bundleIdentifier: nil, currentPID: 1002) == false)

        first.release()
        #expect(second.acquire(bundleIdentifier: nil, currentPID: 1002) == true)
        second.release()
    }
}
