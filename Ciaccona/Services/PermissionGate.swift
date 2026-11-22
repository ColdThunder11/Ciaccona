import AppKit
import AVFAudio
import CoreAudio
import Foundation
import OSLog

enum PermissionProbeResult: Sendable, Equatable {
    case authorized
    case notDeterminedOrSilent
    case failed(String)
}

enum PermissionGateState: Sendable, Equatable {
    case probing
    case awaitingUser(remainingSeconds: Int)
    case authorized
    case denied(reason: String)
}

/// Handles Section 7: Mandatory System Audio Recording permission gating via self-loopback Tap probe.
@MainActor
final class PermissionGate {
    nonisolated private static let logger = Logger(subsystem: "com.coldthunder11.ciaccona", category: "PermissionGate")
    static let maxWaitSeconds = 60

    var onStateChanged: ((PermissionGateState) -> Void)?
    private var isChecking = false

    func ensureAuthorizedAtLaunch() async -> Bool {
        onStateChanged?(.probing)
        let first = await Task.detached(priority: .userInitiated) {
            Self.runLoopbackProbe()
        }.value

        switch first {
        case .authorized:
            onStateChanged?(.authorized)
            return true
        case .failed(let reason):
            onStateChanged?(.denied(reason: reason))
            return false
        case .notDeterminedOrSilent:
            break
        }

        // Wait up to 60s, probing every 1s for the user to approve the TCC prompt.
        NSApp.activate(ignoringOtherApps: true)
        for remaining in stride(from: Self.maxWaitSeconds, through: 1, by: -1) {
            onStateChanged?(.awaitingUser(remainingSeconds: remaining))
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return false }

            let result = await Task.detached(priority: .userInitiated) {
                Self.runLoopbackProbe()
            }.value

            switch result {
            case .authorized:
                onStateChanged?(.authorized)
                return true
            case .failed(let reason):
                onStateChanged?(.denied(reason: reason))
                return false
            case .notDeterminedOrSilent:
                continue
            }
        }

        onStateChanged?(.denied(reason: L10n.trFormat(
            "permission.timeout",
            defaultValue: "Authorization timed out (%d s)",
            Self.maxWaitSeconds
        )))
        return false
    }

    func recheckPermission() async -> Bool {
        guard !isChecking else { return true }
        isChecking = true
        defer { isChecking = false }

        return await Self.evaluateRuntimeRecheck {
            await Task.detached(priority: .userInitiated) {
                Self.runLoopbackProbe(pollIterations: 30)
            }.value
        }
    }

    /// Distinguishes genuine TCC audio-capture revocation (repeated clean silent taps)
    /// from transient wake or audio-device unavailability failures.
    static func evaluateRuntimeRecheck(
        maxAttempts: Int = 4,
        requiredSilentChecks: Int = 2,
        retryDelay: Duration = .seconds(2),
        probe: @escaping @Sendable () async -> PermissionProbeResult,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool {
        let attempts = max(1, maxAttempts)
        var cleanSilentCount = 0

        for attempt in 0..<attempts {
            let result = await probe()
            switch result {
            case .authorized:
                return true
            case .notDeterminedOrSilent:
                cleanSilentCount += 1
                logger.info("Runtime permission probe observed silent tap (\(attempt + 1)/\(attempts))")
            case .failed(let reason):
                logger.warning("Runtime permission probe failed transiently (\(attempt + 1)/\(attempts)): \(reason)")
            }

            if attempt + 1 < attempts {
                await sleep(retryDelay)
            }
        }

        if cleanSilentCount >= requiredSilentChecks {
            return false
        }

        logger.warning("Runtime permission recheck was inconclusive after transient probe failures; keeping session alive")
        return true
    }

    func openSystemAudioCaptureSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for str in urls {
            if let url = URL(string: str), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func presentDenialAlertAndTerminate(reason: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.tr(
            "permission.denied.title",
            defaultValue: "Ciaccona will quit because System Audio Recording permission was not granted."
        )
        let baseInfo = L10n.tr(
            "permission.denied.body",
            defaultValue: "Ciaccona needs \"System Audio Recording\" permission to adjust volume and output devices per app. Allow Ciaccona in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch."
        )
        if let reason, !reason.isEmpty {
            alert.informativeText = "\(baseInfo)\n\n(\(reason))"
        } else {
            alert.informativeText = baseInfo
        }
        alert.addButton(withTitle: L10n.tr("permission.open_system_settings", defaultValue: "Open System Settings"))
        alert.addButton(withTitle: L10n.tr("permission.quit", defaultValue: "Quit"))

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openSystemAudioCaptureSettings()
        }
        NSApp.terminate(nil)
    }

    /// Executes the self-loopback probe off the MainActor using only public Core Audio & AVFAudio APIs.
    nonisolated static func runLoopbackProbe(pollIterations: Int = 14) -> PermissionProbeResult {
        // 1. Resolve our own process AudioObjectID.
        let pid = ProcessInfo.processInfo.processIdentifier
        let selfProcessID: AudioObjectID
        do {
            selfProcessID = try AudioObject.system.get(
                kAudioHardwarePropertyTranslatePIDToProcessObject,
                qualifier: pid
            )
        } catch {
            return .failed(L10n.trFormat(
                "permission.probe.self_process_failed",
                defaultValue: "Unable to resolve current process audio object: %@",
                String(describing: error)
            ))
        }

        // 2. Find default output device.
        let defaultOutputID: AudioObjectID = (try? AudioObject.system.get(kAudioHardwarePropertyDefaultOutputDevice))
            ?? AudioObjectID(kAudioObjectUnknown)
        guard defaultOutputID != AudioObjectID(kAudioObjectUnknown),
              let outputUID = AudioObject(id: defaultOutputID).getOptionalString(kAudioDevicePropertyDeviceUID) else {
            return .failed(L10n.tr(
                "permission.probe.no_default_output",
                defaultValue: "No default audio output device found"
            ))
        }

        let tapUUID = UUID()
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var renderState: UnsafeMutablePointer<RTRenderState>?
        let engine = AVAudioEngine()

        defer {
            engine.stop()
            if let proc = ioProcID, aggID != AudioObjectID(kAudioObjectUnknown) {
                _ = AudioDeviceStop(aggID, proc)
                _ = AudioDeviceDestroyIOProcID(aggID, proc)
            }
            if let renderState {
                RTRenderState.deallocate(renderState)
            }
            if aggID != AudioObjectID(kAudioObjectUnknown) {
                AggregateDeviceBuilder.destroyAggregateDevice(aggID)
            }
            if tapID != AudioObjectID(kAudioObjectUnknown) {
                TapBuilder.destroyTap(tapID)
            }
        }

        // 3. Create a private global tap (.unmuted so other apps are never muted) to trigger TCC kTCCServiceAudioCapture.
        do {
            tapID = try TapBuilder.createGlobalTap(
                name: "Ciaccona-PermissionProbe",
                excludingProcesses: [],
                uuid: tapUUID,
                muteBehavior: .unmuted
            )
        } catch {
            logger.error("Process tap creation failed during probe: \(error)")
            return .failed(L10n.trFormat(
                "permission.probe.tap_failed",
                defaultValue: "Failed to create audio tap: %@",
                error.localizedDescription
            ))
        }
        _ = selfProcessID

        // 4. Create private aggregate device with tapAutoStart = false so IOProc pulls immediately.
        do {
            aggID = try AggregateDeviceBuilder.createPrivateAggregateDevice(
                name: "Ciaccona-ProbeAgg",
                outputDeviceUID: outputUID,
                tapUUID: tapUUID,
                tapAutoStart: false
            )
        } catch {
            logger.error("Probe aggregate creation failed: \(error)")
            return .failed(L10n.trFormat(
                "permission.probe.aggregate_failed",
                defaultValue: "Failed to create probe aggregate device: %@",
                error.localizedDescription
            ))
        }

        let aggObj = AudioObject(id: aggID)
        let tapFmt = (try? TapBuilder.readFormat(tapID: tapID)) ?? AudioStreamBasicDescription()
        let inFmt: AudioStreamBasicDescription = (try? aggObj.get(
            kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeInput
        )) ?? tapFmt
        let outFmt: AudioStreamBasicDescription = (try? aggObj.get(
            kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeOutput
        )) ?? inFmt

        let inLayout = RTStreamLayout.from(asbd: inFmt)
        let outLayout = RTStreamLayout.from(asbd: outFmt)
        let params = RTParams(gain: 0.0, muted: true) // Output muted; we only measure input RMS.
        let statePtr = RTRenderState.allocate(initialGain: 0.0, maxFrames: 64)
        renderState = statePtr

        var newProc: AudioDeviceIOProcID?
        let createIOStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggID, nil) { _, inInputData, _, outOutputData, _ in
            RTRenderer.renderIO(
                inInputData: inInputData,
                outOutputData: outOutputData,
                inputLayout: inLayout,
                outputLayout: outLayout,
                params: params,
                state: statePtr
            )
        }
        guard createIOStatus == noErr, let proc = newProc else {
            return .failed(L10n.trFormat(
                "permission.probe.ioproc_failed",
                defaultValue: "Failed to create probe IOProc (OSStatus %d)",
                createIOStatus
            ))
        }
        ioProcID = proc

        let startIOStatus = AudioDeviceStart(aggID, proc)
        guard startIOStatus == noErr else {
            return .failed(L10n.trFormat(
                "permission.probe.start_io_failed",
                defaultValue: "Failed to start probe IO (OSStatus %d)",
                startIOStatus
            ))
        }

        // 5. Play an inaudible -54 dBFS 1 kHz sine wave from our own process via AVAudioSourceNode.
        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = Float(outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48_000)
        let amplitude: Float = 0.002 // -54 dBFS
        let frequency: Float = 1_000.0
        let sourceNode = AVAudioSourceNode { _, timestamp, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let startSample = timestamp.pointee.mSampleTime
            let omega = 2.0 * Float.pi * frequency / sampleRate
            for buf in abl {
                guard let ptr = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(1, Int(buf.mNumberChannels))
                for f in 0..<Int(frameCount) {
                    let sample = amplitude * sinf(omega * Float(startSample + Double(f)))
                    let base = f * channels
                    for c in 0..<channels {
                        ptr[base + c] = sample
                    }
                }
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: outputFormat)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
        } catch {
            return .failed(L10n.trFormat(
                "permission.probe.engine_failed",
                defaultValue: "Failed to start probe audio engine: %@",
                error.localizedDescription
            ))
        }

        // Poll for non-zero tapped RMS (default ~280ms; longer when checking after wake).
        for _ in 0..<max(1, pollIterations) {
            Thread.sleep(forTimeInterval: 0.02)
            if params.loadMaxObservedRMS() > 1e-5 {
                return .authorized
            }
        }

        return .notDeterminedOrSilent
    }
}
