import CoreAudio
import Foundation
import Synchronization
import Testing
@testable import Ciaccona

@Suite("AudioObject Tests")
struct AudioObjectTests {
    @Test("Default output device query via try? fallback infers AudioObjectID cleanly")
    func defaultOutputDeviceInference() {
        let defaultID: AudioObjectID = (try? AudioObject.system.get(kAudioHardwarePropertyDefaultOutputDevice))
            ?? AudioObjectID(kAudioObjectUnknown)
        #expect(AudioDevice.load(id: AudioObjectID(kAudioObjectUnknown)) == nil)

        if defaultID != AudioObjectID(kAudioObjectUnknown), let device = AudioDevice.load(id: defaultID) {
            #expect(device.hasOutput)
            #expect(device.sampleRate > 0)
        }
    }

    @Test("isSelectableOutput filters transient Core Audio aggregates, private aggregates, and hidden devices")
    func filtersSystemTransientAndHiddenDevices() {
        let transient = AudioDevice(
            id: 1,
            uid: "CADefaultDeviceAggregate-17953-0",
            name: "CADefaultDeviceAggregate-17953-0",
            transport: kAudioDeviceTransportTypeAggregate,
            hasOutput: true,
            outputChannelCount: 2,
            canSetVolume: false,
            canMute: false,
            sampleRate: 48_000
        )
        let privateAgg = AudioDevice(
            id: 2,
            uid: AudioDevice.privateAggregateUIDPrefix + "1234",
            name: "Ciaccona-Tap",
            transport: kAudioDeviceTransportTypeAggregate,
            hasOutput: true,
            outputChannelCount: 2,
            canSetVolume: false,
            canMute: false,
            sampleRate: 48_000
        )
        let hidden = AudioDevice(
            id: 3,
            uid: "HiddenVirtualDevice",
            name: "Hidden Virtual",
            transport: kAudioDeviceTransportTypeVirtual,
            hasOutput: true,
            outputChannelCount: 2,
            canSetVolume: true,
            canMute: true,
            sampleRate: 48_000,
            isHidden: true
        )
        let userAggregate = AudioDevice(
            id: 4,
            uid: "AppleUSBAudioEngine:UserAggregate",
            name: "我的多输出设备",
            transport: kAudioDeviceTransportTypeAggregate,
            hasOutput: true,
            outputChannelCount: 2,
            canSetVolume: false,
            canMute: false,
            sampleRate: 48_000
        )
        let speaker = AudioDevice(
            id: 5,
            uid: "BuiltInSpeakerDevice",
            name: "MacBook Air扬声器",
            transport: kAudioDeviceTransportTypeBuiltIn,
            hasOutput: true,
            outputChannelCount: 2,
            canSetVolume: true,
            canMute: true,
            sampleRate: 48_000
        )

        #expect(!transient.isSelectableOutput)
        #expect(!privateAgg.isSelectableOutput)
        #expect(!hidden.isSelectableOutput)
        #expect(userAggregate.isSelectableOutput)
        #expect(speaker.isSelectableOutput)
    }

    @Test("RoutingEngine delivers output devices on start without overwriting callback")
    func routingEngineDeliversDevices() async {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ciaccona-engine-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let result: (
            devicesFired: Bool,
            alertFired: Bool,
            deliveredDevices: [AudioDevice],
            deliveredDefaultID: AudioObjectID,
            deliveredAlertID: AudioObjectID,
            expectedDevices: [AudioDevice],
            expectedDefaultID: AudioObjectID,
            expectedAlertID: AudioObjectID
        ) = await Task { @AudioControlActor in
            let dm = DeviceManager()
            let gvc = GlobalVolumeController()
            let pm = ProcessMonitor()
            let rs = RuleStore(fileURL: tempDir.appendingPathComponent("rules.json"))
            let engine = RoutingEngine(
                deviceManager: dm,
                volumeController: gvc,
                processMonitor: pm,
                ruleStore: rs
            )

            let captured = Mutex<(Bool, Bool, [AudioDevice], AudioObjectID, AudioObjectID)>(
                (false, false, [], AudioObjectID(kAudioObjectUnknown), AudioObjectID(kAudioObjectUnknown))
            )
            engine.onDevicesChanged = { devices, defaultID in
                captured.withLock { state in
                    state.0 = true
                    state.2 = devices
                    state.3 = defaultID
                }
            }
            engine.onSystemAlertDeviceChanged = { alertID in
                captured.withLock { state in
                    state.1 = true
                    state.4 = alertID
                }
            }

            engine.start()
            let expectedDevices = dm.outputDevices
            let expectedDefaultID = dm.defaultOutputDeviceID
            let expectedAlertID = dm.defaultSystemOutputDeviceID
            engine.stopAll()
            let snapshot = captured.withLock { $0 }
            return (
                snapshot.0,
                snapshot.1,
                snapshot.2,
                snapshot.3,
                snapshot.4,
                expectedDevices,
                expectedDefaultID,
                expectedAlertID
            )
        }.value

        #expect(result.devicesFired)
        #expect(result.alertFired)
        #expect(result.deliveredDevices == result.expectedDevices)
        #expect(result.deliveredDefaultID == result.expectedDefaultID)
        #expect(result.deliveredAlertID == result.expectedAlertID)
    }

    @Test("ProcessMonitor enumerates and groups live Core Audio processes without failing on headless hosts")
    func processMonitorEnumeratesApps() async {
        let selfPID = ProcessInfo.processInfo.processIdentifier
        let snapshot: (regularApps: [AudioApp], allApps: [AudioApp], alertApp: AudioApp) = await Task { @AudioControlActor in
            let pm = ProcessMonitor()
            pm.refresh()
            let regularApps = pm.apps
            pm.setIncludeAllProcesses(true)
            return (regularApps, pm.apps, pm.systemAlertApp)
        }.value

        #expect(snapshot.alertApp.id == SystemAlertSound.appID)
        #expect(snapshot.allApps.count >= snapshot.regularApps.count)
        #expect(Set(snapshot.regularApps.map(\.id)).isSubset(of: Set(snapshot.allApps.map(\.id))))
        #expect(Set(snapshot.allApps.map(\.id)).count == snapshot.allApps.count)
        #expect(!snapshot.allApps.contains { $0.id == SystemAlertSound.appID })
        #expect(snapshot.allApps.allSatisfy { app in
            !app.processes.isEmpty && !app.processes.contains { $0.pid == selfPID }
        })
    }
}

@Suite("PermissionGate Tests")
struct PermissionGateTests {
    @MainActor
    private func runRecheck(sequence: [PermissionProbeResult]) async -> Bool {
        let index = Mutex(0)
        return await PermissionGate.evaluateRuntimeRecheck(
            maxAttempts: sequence.count,
            requiredSilentChecks: 2,
            retryDelay: .zero,
            probe: {
                let current = index.withLock { idx -> Int in
                    let value = idx
                    idx += 1
                    return value
                }
                return sequence[min(current, sequence.count - 1)]
            },
            sleep: { _ in }
        )
    }

    @Test("Runtime recheck stays authorized when wake failures recover to authorized")
    @MainActor
    func transientWakeFailureRecovers() async {
        let ok = await runRecheck(sequence: [
            .failed("No default audio output device found"),
            .notDeterminedOrSilent,
            .authorized
        ])
        #expect(ok)
    }

    @Test("Runtime recheck does not falsely revoke permission when all attempts fail due to unavailable audio device")
    @MainActor
    func unavailableDeviceDoesNotRevoke() async {
        let ok = await runRecheck(sequence: [
            .failed("No default audio output device found"),
            .failed("No default audio output device found"),
            .failed("Failed to start probe audio engine"),
            .failed("No default audio output device found")
        ])
        #expect(ok)
    }

    @Test("Runtime recheck requires repeated clean silent taps before treating permission as revoked")
    @MainActor
    func singleSilentWithFailuresDoesNotRevoke() async {
        let ok = await runRecheck(sequence: [
            .failed("Transient HAL error"),
            .notDeterminedOrSilent,
            .failed("Device disconnected"),
            .failed("Device disconnected")
        ])
        #expect(ok)
    }

    @Test("Runtime recheck detects genuine revocation on repeated clean silent taps")
    @MainActor
    func repeatedCleanSilenceDetectsRevocation() async {
        let ok = await runRecheck(sequence: [
            .notDeterminedOrSilent,
            .notDeterminedOrSilent,
            .notDeterminedOrSilent,
            .notDeterminedOrSilent
        ])
        #expect(!ok)
    }
}
