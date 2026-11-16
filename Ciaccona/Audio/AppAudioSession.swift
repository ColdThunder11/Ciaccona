import CoreAudio
import Foundation
import OSLog

/// Manages the Tap + Private Aggregate Device + RT IOProc pipeline for a single application.
/// Control methods are called from `@AudioControlActor`; gain/mute updates use lock-free atomics.
final class AppAudioSession: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.coldthunder11.ciaccona", category: "AppAudioSession")

    let appID: String
    let tapUUID = UUID()
    let params: RTParams

    private(set) var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private(set) var targetOutputUID: String = ""
    private(set) var isIORunning: Bool = false

    private(set) var requestedTapDeviceUID: String?
    private(set) var requestedMultichannel: Bool = false

    private var ioProcID: AudioDeviceIOProcID?
    private var renderState: UnsafeMutablePointer<RTRenderState>?
    private var lastProcesses: [AudioObjectID] = []
    private var lastTapDeviceUID: String?
    private var activeTapDeviceUID: String?
    private var activePreserveMultichannel: Bool = false
    private var isGlobalExcludeMode: Bool = false
    private var preferredBufferFrameSize: UInt32
    private var activeBufferFrameSize: UInt32
    private var activeSampleRate: Double = 48_000
    private var eqProfiles: [EQProfile] = []
    private var hasCompiledEQOnce: Bool = false

    var tappedProcesses: [AudioObjectID] {
        isGlobalExcludeMode ? [] : lastProcesses
    }

    init(
        appID: String,
        initialGain: Float = 1.0,
        initialMuted: Bool = false,
        initialBufferFrameSize: UInt32 = AudioBufferPreset.standard.frameCount
    ) {
        self.appID = appID
        self.params = RTParams(gain: initialGain, muted: initialMuted)
        self.preferredBufferFrameSize = initialBufferFrameSize
        self.activeBufferFrameSize = initialBufferFrameSize
    }

    deinit {
        stop()
    }

    func start(
        processes: [AudioObjectID],
        outputDeviceUID: String,
        tapDeviceUID: String? = nil
    ) throws {
        stop()
        requestedTapDeviceUID = tapDeviceUID
        requestedMultichannel = tapDeviceUID != nil
        do {
            let tap: AudioObjectID
            if let tapDeviceUID, !tapDeviceUID.isEmpty {
                do {
                    tap = try TapBuilder.createProcessTap(
                        name: "Ciaccona-Tap-\(appID)",
                        processes: processes,
                        tapDeviceUID: tapDeviceUID,
                        uuid: tapUUID,
                        muteBehavior: .mutedWhenTapped
                    )
                    activeTapDeviceUID = tapDeviceUID
                } catch {
                    Self.logger.warning("Multichannel tap failed for \(self.appID) on \(tapDeviceUID), falling back to stereo mixdown: \(error.localizedDescription)")
                    tap = try TapBuilder.createProcessTap(
                        name: "Ciaccona-Tap-\(appID)",
                        processes: processes,
                        uuid: tapUUID,
                        muteBehavior: .mutedWhenTapped
                    )
                    activeTapDeviceUID = nil
                }
            } else {
                tap = try TapBuilder.createProcessTap(
                    name: "Ciaccona-Tap-\(appID)",
                    processes: processes,
                    uuid: tapUUID,
                    muteBehavior: .mutedWhenTapped
                )
                activeTapDeviceUID = nil
            }
            tapID = tap
            lastProcesses = processes
            lastTapDeviceUID = nil
            activePreserveMultichannel = activeTapDeviceUID != nil
            isGlobalExcludeMode = false

            try attachAggregateAndStartIO(outputDeviceUID: outputDeviceUID)
        } catch {
            stop()
            throw error
        }
    }

    func startGlobal(
        excludingProcesses: [AudioObjectID],
        tapDeviceUID: String?,
        outputDeviceUID: String,
        preserveMultichannel: Bool = false
    ) throws {
        stop()
        requestedTapDeviceUID = tapDeviceUID
        requestedMultichannel = preserveMultichannel
        do {
            let tap: AudioObjectID
            if preserveMultichannel, let tapDeviceUID, !tapDeviceUID.isEmpty {
                do {
                    tap = try TapBuilder.createGlobalTap(
                        name: "Ciaccona-Tap-\(appID)",
                        excludingProcesses: excludingProcesses,
                        deviceUID: tapDeviceUID,
                        preserveMultichannel: true,
                        uuid: tapUUID,
                        muteBehavior: .mutedWhenTapped
                    )
                    activePreserveMultichannel = true
                } catch {
                    Self.logger.warning("Multichannel global tap failed on \(tapDeviceUID), falling back to stereo mixdown: \(error.localizedDescription)")
                    tap = try TapBuilder.createGlobalTap(
                        name: "Ciaccona-Tap-\(appID)",
                        excludingProcesses: excludingProcesses,
                        deviceUID: tapDeviceUID,
                        preserveMultichannel: false,
                        uuid: tapUUID,
                        muteBehavior: .mutedWhenTapped
                    )
                    activePreserveMultichannel = false
                }
            } else {
                tap = try TapBuilder.createGlobalTap(
                    name: "Ciaccona-Tap-\(appID)",
                    excludingProcesses: excludingProcesses,
                    deviceUID: tapDeviceUID,
                    preserveMultichannel: false,
                    uuid: tapUUID,
                    muteBehavior: .mutedWhenTapped
                )
                activePreserveMultichannel = false
            }
            tapID = tap
            lastProcesses = excludingProcesses
            lastTapDeviceUID = tapDeviceUID
            activeTapDeviceUID = nil
            isGlobalExcludeMode = true

            try attachAggregateAndStartIO(outputDeviceUID: outputDeviceUID)
        } catch {
            stop()
            throw error
        }
    }

    func updateProcesses(_ processes: [AudioObjectID]) throws {
        guard tapID != AudioObjectID(kAudioObjectUnknown), !isGlobalExcludeMode else { return }
        guard processes != lastProcesses else { return }
        try TapBuilder.updateProcesses(
            tapID: tapID,
            name: "Ciaccona-Tap-\(appID)",
            processes: processes,
            tapDeviceUID: activeTapDeviceUID,
            uuid: tapUUID,
            muteBehavior: .mutedWhenTapped
        )
        lastProcesses = processes
    }

    func updateExcludedProcesses(_ processes: [AudioObjectID], deviceUID: String?) throws {
        guard tapID != AudioObjectID(kAudioObjectUnknown), isGlobalExcludeMode else { return }
        guard processes != lastProcesses || deviceUID != lastTapDeviceUID else { return }
        try TapBuilder.updateGlobalTap(
            tapID: tapID,
            name: "Ciaccona-Tap-\(appID)",
            excludingProcesses: processes,
            deviceUID: deviceUID,
            preserveMultichannel: activePreserveMultichannel,
            uuid: tapUUID,
            muteBehavior: .mutedWhenTapped
        )
        lastProcesses = processes
        lastTapDeviceUID = deviceUID
    }

    func switchOutput(to deviceUID: String) throws {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, context: "switchOutput without active tap")
        }
        teardownAggregateAndIO()
        try attachAggregateAndStartIO(outputDeviceUID: deviceUID)
    }

    func setGain(_ gain: Float) {
        params.setGain(gain)
    }

    func setMuted(_ muted: Bool) {
        params.setMuted(muted)
    }

    func setEQProfiles(_ profiles: [EQProfile]) {
        guard eqProfiles != profiles || !hasCompiledEQOnce else { return }
        eqProfiles = profiles
        pushCompiledEQ()
    }

    private func pushCompiledEQ() {
        hasCompiledEQOnce = true
        let chain = CompiledEQChain.compile(profiles: eqProfiles, sampleRate: activeSampleRate)
        params.setEQ(chain)
    }

    func updateBufferFrameSize(_ frameSize: UInt32) {
        preferredBufferFrameSize = frameSize
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else { return }
        applyBufferFrameSize(frameSize, on: AudioObject(id: aggregateID))
    }

    func pauseIO() {
        guard isIORunning, aggregateID != AudioObjectID(kAudioObjectUnknown), let proc = ioProcID else {
            return
        }
        let status = AudioDeviceStop(aggregateID, proc)
        if status == noErr {
            isIORunning = false
        }
    }

    func resumeIO() throws {
        guard !isIORunning, aggregateID != AudioObjectID(kAudioObjectUnknown), let proc = ioProcID else {
            return
        }
        let status = AudioDeviceStart(aggregateID, proc)
        try caCheck(status, "AudioDeviceStart(resume \(appID))")
        isIORunning = true
        params.resetActivityCounters()
    }

    /// Strict reverse-order teardown: Stop -> DestroyIOProc -> Deallocate RT state -> DestroyAggregate -> DestroyTap.
    func stop() {
        teardownAggregateAndIO()
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            TapBuilder.destroyTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        lastProcesses = []
        lastTapDeviceUID = nil
        requestedTapDeviceUID = nil
        requestedMultichannel = false
        activeTapDeviceUID = nil
        activePreserveMultichannel = false
        isGlobalExcludeMode = false
    }

    func isSilentExceeding(seconds: Double = 3.0) -> Bool {
        guard isIORunning else { return false }
        let buffersPerSecond = activeSampleRate / Double(max(64, activeBufferFrameSize))
        let threshold: UInt64 = UInt64(max(15, Int(seconds * buffersPerSecond)))
        return params.loadConsecutiveSilentBuffers() >= threshold
    }

    func resetSilenceCounter() {
        params.resetActivityCounters()
    }

    private func applyBufferFrameSize(_ requestedFrames: UInt32, on aggObj: AudioObject) {
        var target = requestedFrames
        let range: AudioValueRange? = (try? aggObj.get(kAudioDevicePropertyBufferFrameSizeRange))
            ?? (try? aggObj.get(kAudioDevicePropertyBufferFrameSizeRange, scope: kAudioDevicePropertyScopeOutput))
        if let range, range.mMaximum >= range.mMinimum, range.mMinimum > 0 {
            let minFrames = UInt32(max(1, range.mMinimum))
            let maxFrames = UInt32(max(Double(minFrames), range.mMaximum))
            target = min(max(target, minFrames), maxFrames)
        }

        do {
            if aggObj.isSettable(kAudioDevicePropertyBufferFrameSize, scope: kAudioObjectPropertyScopeGlobal) {
                try aggObj.set(kAudioDevicePropertyBufferFrameSize, value: target, scope: kAudioObjectPropertyScopeGlobal)
            } else if aggObj.isSettable(kAudioDevicePropertyBufferFrameSize, scope: kAudioDevicePropertyScopeOutput) {
                try aggObj.set(kAudioDevicePropertyBufferFrameSize, value: target, scope: kAudioDevicePropertyScopeOutput)
            }
            activeBufferFrameSize = (try? aggObj.get(kAudioDevicePropertyBufferFrameSize)) ?? target
        } catch {
            Self.logger.warning("Failed setting buffer frame size \(target) on \(self.appID): \(error.localizedDescription)")
        }
    }

    private func attachAggregateAndStartIO(outputDeviceUID: String) throws {
        let aggID = try AggregateDeviceBuilder.createPrivateAggregateDevice(
            name: "Ciaccona-\(appID)",
            outputDeviceUID: outputDeviceUID,
            tapUUID: tapUUID,
            tapAutoStart: true
        )
        aggregateID = aggID
        targetOutputUID = outputDeviceUID

        let aggObj = AudioObject(id: aggID)
        applyBufferFrameSize(preferredBufferFrameSize, on: aggObj)

        let tapFormat = (try? TapBuilder.readFormat(tapID: tapID)) ?? AudioStreamBasicDescription()
        let inFormat: AudioStreamBasicDescription = (try? aggObj.get(
            kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeInput
        )) ?? tapFormat
        let outFormat: AudioStreamBasicDescription = (try? aggObj.get(
            kAudioDevicePropertyStreamFormat,
            scope: kAudioDevicePropertyScopeOutput
        )) ?? inFormat
        activeSampleRate = outFormat.mSampleRate > 0 ? outFormat.mSampleRate : 48_000

        if inFormat.mSampleRate > 0, outFormat.mSampleRate > 0,
           abs(inFormat.mSampleRate - outFormat.mSampleRate) > 1.0 {
            Self.logger.warning("Sample rate mismatch on \(self.appID): tap=\(inFormat.mSampleRate), out=\(outFormat.mSampleRate)")
        }

        let parsedInLayout = RTStreamLayout.from(asbd: inFormat)
        let parsedOutLayout = RTStreamLayout.from(asbd: outFormat)
        let aggInChannels = max(parsedInLayout.channels, aggObj.channelCount(scope: kAudioDevicePropertyScopeInput))
        let aggOutChannels = max(parsedOutLayout.channels, aggObj.channelCount(scope: kAudioDevicePropertyScopeOutput))
        let inLayout = RTStreamLayout(
            channels: aggInChannels,
            isNonInterleaved: parsedInLayout.isNonInterleaved,
            sampleRate: parsedInLayout.sampleRate
        )
        let outLayout = RTStreamLayout(
            channels: aggOutChannels,
            isNonInterleaved: parsedOutLayout.isNonInterleaved,
            sampleRate: parsedOutLayout.sampleRate
        )

        let scratchFrames = max(2_048, Int(activeBufferFrameSize) * 2)
        let scratchChannels = max(2, max(aggInChannels, aggOutChannels))
        let statePtr = RTRenderState.allocate(
            initialGain: params.loadEffectiveGain(),
            maxFrames: scratchFrames,
            maxChannels: scratchChannels
        )
        renderState = statePtr
        pushCompiledEQ()

        let capturedParams = params
        var newProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID,
            aggID,
            nil
        ) { _, inInputData, _, outOutputData, _ in
            RTRenderer.renderIO(
                inInputData: inInputData,
                outOutputData: outOutputData,
                inputLayout: inLayout,
                outputLayout: outLayout,
                params: capturedParams,
                state: statePtr
            )
        }
        try caCheck(createStatus, "AudioDeviceCreateIOProcIDWithBlock(\(appID))")
        ioProcID = newProcID

        let startStatus = AudioDeviceStart(aggID, newProcID)
        try caCheck(startStatus, "AudioDeviceStart(\(appID))")
        isIORunning = true
        params.resetActivityCounters()
    }

    private func teardownAggregateAndIO() {
        if let proc = ioProcID, aggregateID != AudioObjectID(kAudioObjectUnknown) {
            if isIORunning {
                _ = AudioDeviceStop(aggregateID, proc)
            }
            _ = AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        isIORunning = false

        if let state = renderState {
            RTRenderState.deallocate(state)
            renderState = nil
        }

        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AggregateDeviceBuilder.destroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
