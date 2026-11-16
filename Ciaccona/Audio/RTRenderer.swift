import Accelerate
import CoreAudio
import Foundation
import Synchronization

/// Lock-free, allocation-free parameter block shared between control threads and the Core Audio RT thread.
final class RTParams: Sendable {
    private let targetGainBits: Atomic<UInt32>
    private let mutedFlag: Atomic<UInt32>
    private let maxObservedRmsBits: Atomic<UInt32>
    private let consecutiveSilentBuffers: Atomic<UInt64>

    init(gain: Float = 1.0, muted: Bool = false) {
        self.targetGainBits = Atomic(gain.bitPattern)
        self.mutedFlag = Atomic(muted ? 1 : 0)
        self.maxObservedRmsBits = Atomic(Float(0).bitPattern)
        self.consecutiveSilentBuffers = Atomic(0)
    }

    @inline(__always)
    func setGain(_ gain: Float) {
        let clamped = max(0.0, min(1.5, gain))
        targetGainBits.store(clamped.bitPattern, ordering: .relaxed)
    }

    @inline(__always)
    func setMuted(_ muted: Bool) {
        mutedFlag.store(muted ? 1 : 0, ordering: .relaxed)
    }

    @inline(__always)
    func loadEffectiveGain() -> Float {
        if mutedFlag.load(ordering: .relaxed) != 0 {
            return 0.0
        }
        return Float(bitPattern: targetGainBits.load(ordering: .relaxed))
    }

    @inline(__always)
    func recordInputActivity(rms: Float) {
        let prev = Float(bitPattern: maxObservedRmsBits.load(ordering: .relaxed))
        if rms > prev {
            maxObservedRmsBits.store(rms.bitPattern, ordering: .relaxed)
        }
        if rms > 1e-6 {
            if consecutiveSilentBuffers.load(ordering: .relaxed) != 0 {
                consecutiveSilentBuffers.store(0, ordering: .relaxed)
            }
        } else {
            consecutiveSilentBuffers.add(1, ordering: .relaxed)
        }
    }

    func loadMaxObservedRMS() -> Float {
        Float(bitPattern: maxObservedRmsBits.load(ordering: .relaxed))
    }

    func loadConsecutiveSilentBuffers() -> UInt64 {
        consecutiveSilentBuffers.load(ordering: .relaxed)
    }

    func resetActivityCounters() {
        maxObservedRmsBits.store(Float(0).bitPattern, ordering: .relaxed)
        consecutiveSilentBuffers.store(0, ordering: .relaxed)
    }
}

struct RTStreamLayout: Sendable, Equatable {
    let channels: Int
    let isNonInterleaved: Bool
    let sampleRate: Double

    static func from(asbd: AudioStreamBasicDescription) -> RTStreamLayout {
        RTStreamLayout(
            channels: max(1, Int(asbd.mChannelsPerFrame)),
            isNonInterleaved: (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0,
            sampleRate: asbd.mSampleRate
        )
    }
}

/// Pre-allocated mutable state exclusively owned by the Core Audio RT IOProc.
/// Never accessed concurrently while IO is running; allocated before AudioDeviceStart and freed after AudioDeviceDestroyIOProcID.
struct RTRenderState {
    var currentGain: Float
    let maxFrames: Int
    let maxChannels: Int
    let scratchStorage: UnsafeMutablePointer<Float>

    @inline(__always)
    func scratchChannel(_ index: Int) -> UnsafeMutablePointer<Float> {
        scratchStorage + index * maxFrames
    }

    static func allocate(
        initialGain: Float,
        maxFrames: Int = 4_096,
        maxChannels: Int = 2
    ) -> UnsafeMutablePointer<RTRenderState> {
        let resolvedFrames = max(1, maxFrames)
        let resolvedChannels = max(2, maxChannels)
        let state = UnsafeMutablePointer<RTRenderState>.allocate(capacity: 1)
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: resolvedFrames * resolvedChannels)
        storage.initialize(repeating: 0, count: resolvedFrames * resolvedChannels)
        state.initialize(to: RTRenderState(
            currentGain: initialGain,
            maxFrames: resolvedFrames,
            maxChannels: resolvedChannels,
            scratchStorage: storage
        ))
        return state
    }

    static func deallocate(_ state: UnsafeMutablePointer<RTRenderState>) {
        state.pointee.scratchStorage.deallocate()
        state.deinitialize(count: 1)
        state.deallocate()
    }
}

enum RTRenderer {
    /// Core Audio IOProc entry point. Strictly lock-free, allocation-free, Objective-C/Swift-ARC-free.
    @inline(__always)
    static func renderIO(
        inInputData: UnsafePointer<AudioBufferList>?,
        outOutputData: UnsafeMutablePointer<AudioBufferList>?,
        inputLayout: RTStreamLayout,
        outputLayout: RTStreamLayout,
        params: RTParams,
        state: UnsafeMutablePointer<RTRenderState>
    ) {
        guard let outOutputData else { return }
        let outBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
        guard let firstOut = outBuffers.first, firstOut.mDataByteSize > 0 else { return }

        let outChannelsPerFirstBuf = max(1, Int(firstOut.mNumberChannels))
        let outFrames = Int(firstOut.mDataByteSize) / (outChannelsPerFirstBuf * MemoryLayout<Float>.size)
        guard outFrames > 0 else { return }

        let targetGain = params.loadEffectiveGain()

        guard let inInputData else {
            zeroOutput(outBuffers: outBuffers)
            params.recordInputActivity(rms: 0)
            state.pointee.currentGain = targetGain
            return
        }

        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        let frames = min(outFrames, state.pointee.maxFrames)
        let startGain = state.pointee.currentGain

        // Fast path 1: steady-state mute skips scratch copies and DSP while still tracking input activity.
        if startGain == 0 && targetGain == 0 {
            zeroOutput(outBuffers: outBuffers)
            let (inFrames, activity) = measureInputActivityDirectly(
                inBuffers: inBuffers,
                layout: inputLayout,
                maxFrames: outFrames
            )
            params.recordInputActivity(rms: inFrames > 0 ? activity : 0)
            state.pointee.currentGain = 0
            return
        }

        // Fast path 2: matching layout without soft clipping (gain <= 1.0) writes directly
        // from input to output via vDSP / memcpy, bypassing scratch round-trips.
        if startGain <= 1.0 && targetGain <= 1.0,
           let (inFrames, activity) = renderDirectIfMatchingLayout(
               inBuffers: inBuffers,
               inputLayout: inputLayout,
               outBuffers: outBuffers,
               outputLayout: outputLayout,
               maxFrames: outFrames,
               outFrames: outFrames,
               startGain: startGain,
               targetGain: targetGain
           ) {
            params.recordInputActivity(rms: inFrames > 0 ? activity : 0)
            state.pointee.currentGain = targetGain
            return
        }

        // Extract up to `state.pointee.maxChannels` planar channels from input AudioBufferList.
        let (inFramesAvailable, extractedChannels) = extractInputChannels(
            inBuffers: inBuffers,
            layout: inputLayout,
            outputChannelCount: outputLayout.channels,
            maxFrames: frames,
            state: state
        )

        guard inFramesAvailable > 0, extractedChannels > 0 else {
            zeroOutput(outBuffers: outBuffers)
            params.recordInputActivity(rms: 0)
            state.pointee.currentGain = targetGain
            return
        }

        // Measure input RMS before gain for silence / permission probe detection across all active channels.
        var maxRMS: Float = 0
        for c in 0..<extractedChannels {
            var chRMS: Float = 0
            vDSP_rmsqv(state.pointee.scratchChannel(c), 1, &chRMS, vDSP_Length(inFramesAvailable))
            if chRMS > maxRMS {
                maxRMS = chRMS
            }
        }
        params.recordInputActivity(rms: maxRMS)

        // Apply smoothed linear gain ramp + soft limiting if needed across all extracted channels.
        processChannelsInPlace(
            state: state,
            frameCount: inFramesAvailable,
            channelCount: extractedChannels,
            startGain: startGain,
            targetGain: targetGain
        )
        state.pointee.currentGain = targetGain

        // If outFrames exceeded inFramesAvailable (unlikely, defensive), zero tail.
        if inFramesAvailable < outFrames {
            zeroOutput(outBuffers: outBuffers)
        }

        writeChannelsToOutput(
            state: state,
            frameCount: inFramesAvailable,
            channelCount: extractedChannels,
            outBuffers: outBuffers,
            outputLayout: outputLayout
        )
    }

    /// Processes stereo buffers in-place with linear gain ramping and soft clipping for gain > 1.0.
    static func processStereoInPlace(
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        frameCount: Int,
        startGain: Float,
        targetGain: Float
    ) {
        processChannelInPlace(left, frameCount: frameCount, startGain: startGain, targetGain: targetGain)
        processChannelInPlace(right, frameCount: frameCount, startGain: startGain, targetGain: targetGain)
    }

    @inline(__always)
    private static func processChannelsInPlace(
        state: UnsafeMutablePointer<RTRenderState>,
        frameCount: Int,
        channelCount: Int,
        startGain: Float,
        targetGain: Float
    ) {
        guard frameCount > 0, channelCount > 0 else { return }
        for c in 0..<channelCount {
            processChannelInPlace(
                state.pointee.scratchChannel(c),
                frameCount: frameCount,
                startGain: startGain,
                targetGain: targetGain
            )
        }
    }

    @inline(__always)
    private static func processChannelInPlace(
        _ ptr: UnsafeMutablePointer<Float>,
        frameCount: Int,
        startGain: Float,
        targetGain: Float
    ) {
        guard frameCount > 0 else { return }

        if startGain == 0 && targetGain == 0 {
            vDSP_vclr(ptr, 1, vDSP_Length(frameCount))
            return
        }

        if startGain == targetGain {
            if targetGain != 1.0 {
                var g = targetGain
                vDSP_vsmul(ptr, 1, &g, ptr, 1, vDSP_Length(frameCount))
            }
        } else {
            var step = (targetGain - startGain) / Float(frameCount)
            var g = startGain
            vDSP_vrampmul(ptr, 1, &g, &step, ptr, 1, vDSP_Length(frameCount))
        }

        if startGain > 1.0 || targetGain > 1.0 {
            softClipInPlace(ptr, count: frameCount)
        }
    }

    /// Smooth soft-knee limiter above 0.90, hard-bounded strictly within [-1.0, 1.0].
    @inline(__always)
    static func softClipSample(_ x: Float) -> Float {
        let absX = abs(x)
        let threshold: Float = 0.9
        if absX <= threshold {
            return x
        }
        // Maps [0.9, +inf) smoothly onto [0.9, 1.0) via 0.9 + 0.1 * tanh((absX - 0.9) / 0.1)
        let excess = (absX - threshold) / (1.0 - threshold)
        let limited = threshold + (1.0 - threshold) * tanhf(excess)
        return x >= 0 ? limited : -limited
    }

    @inline(__always)
    private static func softClipInPlace(_ ptr: UnsafeMutablePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var maxMag: Float = 0
        vDSP_maxmgv(ptr, 1, &maxMag, vDSP_Length(count))
        guard maxMag > 0.9 else { return }

        let threshold: Float = 0.9
        let kneeRange: Float = 0.1
        let invKneeRange: Float = 10.0
        for i in 0..<count {
            let x = ptr[i]
            let absX = abs(x)
            if absX > threshold {
                let limited = threshold + kneeRange * tanhf((absX - threshold) * invKneeRange)
                ptr[i] = x >= 0 ? limited : -limited
            }
        }
    }

    @inline(__always)
    private static func measureInputActivityDirectly(
        inBuffers: UnsafeMutableAudioBufferListPointer,
        layout: RTStreamLayout,
        maxFrames: Int
    ) -> (frames: Int, level: Float) {
        guard !inBuffers.isEmpty, maxFrames > 0 else { return (0, 0) }

        if layout.isNonInterleaved || inBuffers.count > 1 {
            var frames = maxFrames
            var maxRMS: Float = 0
            var validChannels = 0
            for c in 0..<inBuffers.count {
                guard let ptr = inBuffers[c].mData?.assumingMemoryBound(to: Float.self) else {
                    continue
                }
                let bufFrames = Int(inBuffers[c].mDataByteSize) / MemoryLayout<Float>.size
                guard bufFrames > 0 else { continue }
                let count = min(frames, bufFrames)
                frames = count
                validChannels += 1
                var chRMS: Float = 0
                vDSP_rmsqv(ptr, 1, &chRMS, vDSP_Length(count))
                if chRMS > maxRMS {
                    maxRMS = chRMS
                }
            }
            return validChannels > 0 ? (frames, maxRMS) : (0, 0)
        } else {
            let buf = inBuffers[0]
            guard let raw = buf.mData?.assumingMemoryBound(to: Float.self) else { return (0, 0) }
            let channels = max(1, Int(buf.mNumberChannels))
            let frames = min(maxFrames, Int(buf.mDataByteSize) / (channels * MemoryLayout<Float>.size))
            guard frames > 0 else { return (0, 0) }
            // Single contiguous vector peak scan across all interleaved channels.
            var peak: Float = 0
            vDSP_maxmgv(raw, 1, &peak, vDSP_Length(frames * channels))
            return (frames, peak)
        }
    }

    @inline(__always)
    private static func renderDirectIfMatchingLayout(
        inBuffers: UnsafeMutableAudioBufferListPointer,
        inputLayout: RTStreamLayout,
        outBuffers: UnsafeMutableAudioBufferListPointer,
        outputLayout: RTStreamLayout,
        maxFrames: Int,
        outFrames: Int,
        startGain: Float,
        targetGain: Float
    ) -> (frames: Int, level: Float)? {
        guard !inBuffers.isEmpty, !outBuffers.isEmpty, maxFrames > 0 else { return nil }

        let inNonInterleaved = inputLayout.isNonInterleaved || inBuffers.count > 1
        let outNonInterleaved = outputLayout.isNonInterleaved || outBuffers.count > 1

        if inNonInterleaved && outNonInterleaved {
            // Multi-channel to mono requires downmix in scratch path.
            if inBuffers.count >= 2 && outBuffers.count == 1 {
                return nil
            }

            let inCount = inBuffers.count
            let outCount = outBuffers.count
            let mappedChannels = min(inCount, outCount)
            let duplicateMonoToStereo = (inCount == 1 && outCount >= 2)
            let targetWriteChannels = duplicateMonoToStereo ? 2 : mappedChannels

            var frames = maxFrames
            for c in 0..<mappedChannels {
                guard inBuffers[c].mData != nil else {
                    zeroOutput(outBuffers: outBuffers)
                    return (0, 0)
                }
                frames = min(frames, Int(inBuffers[c].mDataByteSize) / MemoryLayout<Float>.size)
            }
            for c in 0..<targetWriteChannels {
                guard outBuffers[c].mData != nil else {
                    zeroOutput(outBuffers: outBuffers)
                    return (0, 0)
                }
                frames = min(frames, Int(outBuffers[c].mDataByteSize) / MemoryLayout<Float>.size)
            }
            guard frames > 0 else {
                zeroOutput(outBuffers: outBuffers)
                return (0, 0)
            }

            var maxRMS: Float = 0
            let vCount = vDSP_Length(frames)
            for c in 0..<mappedChannels {
                let inPtr = inBuffers[c].mData!.assumingMemoryBound(to: Float.self)
                var chRMS: Float = 0
                vDSP_rmsqv(inPtr, 1, &chRMS, vCount)
                if chRMS > maxRMS {
                    maxRMS = chRMS
                }
            }

            if frames < outFrames {
                zeroOutput(outBuffers: outBuffers)
            }

            let byteCount = frames * MemoryLayout<Float>.size
            for c in 0..<targetWriteChannels {
                let srcIdx = duplicateMonoToStereo ? 0 : c
                let inPtr = inBuffers[srcIdx].mData!.assumingMemoryBound(to: Float.self)
                let dstPtr = outBuffers[c].mData!.assumingMemoryBound(to: Float.self)
                if startGain == 1.0 && targetGain == 1.0 {
                    memcpy(dstPtr, inPtr, byteCount)
                } else if startGain == targetGain {
                    var gain = targetGain
                    vDSP_vsmul(inPtr, 1, &gain, dstPtr, 1, vCount)
                } else {
                    var step = (targetGain - startGain) / Float(frames)
                    var g = startGain
                    vDSP_vrampmul(inPtr, 1, &g, &step, dstPtr, 1, vCount)
                }
            }

            if outCount > targetWriteChannels {
                for c in targetWriteChannels..<outCount {
                    if let dstExtra = outBuffers[c].mData {
                        memset(dstExtra, 0, Int(outBuffers[c].mDataByteSize))
                    }
                }
            }
            return (frames, maxRMS)
        }

        if !inNonInterleaved && !outNonInterleaved && inBuffers.count == 1 && outBuffers.count == 1,
           let raw = inBuffers[0].mData?.assumingMemoryBound(to: Float.self),
           let dst = outBuffers[0].mData?.assumingMemoryBound(to: Float.self),
           inBuffers[0].mNumberChannels >= 1,
           inBuffers[0].mNumberChannels == outBuffers[0].mNumberChannels {
            let channels = Int(inBuffers[0].mNumberChannels)
            let frames = min(
                maxFrames,
                Int(inBuffers[0].mDataByteSize) / (channels * MemoryLayout<Float>.size),
                Int(outBuffers[0].mDataByteSize) / (channels * MemoryLayout<Float>.size)
            )
            guard frames > 0 else {
                zeroOutput(outBuffers: outBuffers)
                return (0, 0)
            }
            let totalSamples = frames * channels
            var peak: Float = 0
            vDSP_maxmgv(raw, 1, &peak, vDSP_Length(totalSamples))

            if frames < outFrames {
                zeroOutput(outBuffers: outBuffers)
            }
            if startGain == 1.0 && targetGain == 1.0 {
                memcpy(dst, raw, totalSamples * MemoryLayout<Float>.size)
            } else if startGain == targetGain {
                var gain = targetGain
                vDSP_vsmul(raw, 1, &gain, dst, 1, vDSP_Length(totalSamples))
            } else if channels == 1 {
                var step = (targetGain - startGain) / Float(frames)
                var g = startGain
                vDSP_vrampmul(raw, 1, &g, &step, dst, 1, vDSP_Length(frames))
            } else {
                let stride = vDSP_Stride(channels)
                let frameLen = vDSP_Length(frames)
                for c in 0..<channels {
                    var step = (targetGain - startGain) / Float(frames)
                    var g = startGain
                    vDSP_vrampmul(raw + c, stride, &g, &step, dst + c, stride, frameLen)
                }
            }
            return (frames, peak)
        }

        return nil
    }

    @inline(__always)
    private static func zeroOutput(outBuffers: UnsafeMutableAudioBufferListPointer) {
        for i in 0..<outBuffers.count {
            if let data = outBuffers[i].mData {
                memset(data, 0, Int(outBuffers[i].mDataByteSize))
            }
        }
    }

    @inline(__always)
    private static func extractInputChannels(
        inBuffers: UnsafeMutableAudioBufferListPointer,
        layout: RTStreamLayout,
        outputChannelCount: Int,
        maxFrames: Int,
        state: UnsafeMutablePointer<RTRenderState>
    ) -> (frames: Int, channelCount: Int) {
        guard !inBuffers.isEmpty, maxFrames > 0 else { return (0, 0) }
        let maxChannels = state.pointee.maxChannels

        if layout.isNonInterleaved || inBuffers.count > 1 {
            let availableCh = min(inBuffers.count, maxChannels)
            guard availableCh > 0, let ptr0 = inBuffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return (0, 0)
            }
            var frames = min(maxFrames, Int(inBuffers[0].mDataByteSize) / MemoryLayout<Float>.size)
            for c in 1..<availableCh {
                guard inBuffers[c].mData != nil else { return (0, 0) }
                frames = min(frames, Int(inBuffers[c].mDataByteSize) / MemoryLayout<Float>.size)
            }
            guard frames > 0 else { return (0, 0) }

            let byteCount = frames * MemoryLayout<Float>.size
            memcpy(state.pointee.scratchChannel(0), ptr0, byteCount)
            if availableCh == 1 && outputChannelCount >= 2 && maxChannels >= 2 {
                memcpy(state.pointee.scratchChannel(1), ptr0, byteCount)
                return (frames, 2)
            }
            for c in 1..<availableCh {
                let src = inBuffers[c].mData!.assumingMemoryBound(to: Float.self)
                memcpy(state.pointee.scratchChannel(c), src, byteCount)
            }
            return (frames, availableCh)
        } else {
            let buf = inBuffers[0]
            guard let raw = buf.mData?.assumingMemoryBound(to: Float.self) else { return (0, 0) }
            let inCh = max(1, Int(buf.mNumberChannels))
            let frames = min(maxFrames, Int(buf.mDataByteSize) / (inCh * MemoryLayout<Float>.size))
            guard frames > 0 else { return (0, 0) }

            if inCh == 1 {
                let byteCount = frames * MemoryLayout<Float>.size
                memcpy(state.pointee.scratchChannel(0), raw, byteCount)
                if outputChannelCount >= 2 && maxChannels >= 2 {
                    memcpy(state.pointee.scratchChannel(1), raw, byteCount)
                    return (frames, 2)
                }
                return (frames, 1)
            } else if inCh == 2 && maxChannels >= 2 {
                var split = DSPSplitComplex(
                    realp: state.pointee.scratchChannel(0),
                    imagp: state.pointee.scratchChannel(1)
                )
                raw.withMemoryRebound(to: DSPComplex.self, capacity: frames) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(frames))
                }
                return (frames, 2)
            } else {
                let availableCh = min(inCh, maxChannels)
                for f in 0..<frames {
                    let base = f * inCh
                    for c in 0..<availableCh {
                        state.pointee.scratchChannel(c)[f] = raw[base + c]
                    }
                }
                return (frames, availableCh)
            }
        }
    }

    @inline(__always)
    private static func writeChannelsToOutput(
        state: UnsafeMutablePointer<RTRenderState>,
        frameCount: Int,
        channelCount: Int,
        outBuffers: UnsafeMutableAudioBufferListPointer,
        outputLayout: RTStreamLayout
    ) {
        guard !outBuffers.isEmpty, frameCount > 0, channelCount > 0 else { return }

        if outputLayout.isNonInterleaved || outBuffers.count > 1 {
            let bufCount = outBuffers.count
            if bufCount == 1, let dst = outBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
                if channelCount >= 2 {
                    var half: Float = 0.5
                    vDSP_vasm(
                        state.pointee.scratchChannel(0), 1,
                        state.pointee.scratchChannel(1), 1,
                        &half,
                        dst, 1,
                        vDSP_Length(frameCount)
                    )
                } else {
                    memcpy(dst, state.pointee.scratchChannel(0), frameCount * MemoryLayout<Float>.size)
                }
            } else {
                let mappedCh = min(channelCount, bufCount)
                let byteCount = frameCount * MemoryLayout<Float>.size
                for c in 0..<mappedCh {
                    if let dst = outBuffers[c].mData?.assumingMemoryBound(to: Float.self) {
                        memcpy(dst, state.pointee.scratchChannel(c), byteCount)
                    }
                }
                if bufCount > mappedCh {
                    for c in mappedCh..<bufCount {
                        if let dstExtra = outBuffers[c].mData {
                            memset(dstExtra, 0, Int(outBuffers[c].mDataByteSize))
                        }
                    }
                }
            }
        } else {
            let buf = outBuffers[0]
            guard let dst = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
            let outCh = max(1, Int(buf.mNumberChannels))
            if outCh == 1 {
                if channelCount >= 2 {
                    var half: Float = 0.5
                    vDSP_vasm(
                        state.pointee.scratchChannel(0), 1,
                        state.pointee.scratchChannel(1), 1,
                        &half,
                        dst, 1,
                        vDSP_Length(frameCount)
                    )
                } else {
                    memcpy(dst, state.pointee.scratchChannel(0), frameCount * MemoryLayout<Float>.size)
                }
            } else if outCh == 2 && channelCount >= 2 {
                var split = DSPSplitComplex(
                    realp: state.pointee.scratchChannel(0),
                    imagp: state.pointee.scratchChannel(1)
                )
                dst.withMemoryRebound(to: DSPComplex.self, capacity: frameCount) { complexPtr in
                    vDSP_ztoc(&split, 1, complexPtr, 2, vDSP_Length(frameCount))
                }
            } else {
                let mappedCh = min(channelCount, outCh)
                if mappedCh < outCh {
                    memset(dst, 0, Int(buf.mDataByteSize))
                }
                for f in 0..<frameCount {
                    let base = f * outCh
                    for c in 0..<mappedCh {
                        dst[base + c] = state.pointee.scratchChannel(c)[f]
                    }
                }
            }
        }
    }
}
