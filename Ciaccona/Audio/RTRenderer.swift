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
    let scratchL: UnsafeMutablePointer<Float>
    let scratchR: UnsafeMutablePointer<Float>

    static func allocate(initialGain: Float, maxFrames: Int = 4_096) -> UnsafeMutablePointer<RTRenderState> {
        let state = UnsafeMutablePointer<RTRenderState>.allocate(capacity: 1)
        let l = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        let r = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames)
        l.initialize(repeating: 0, count: maxFrames)
        r.initialize(repeating: 0, count: maxFrames)
        state.initialize(to: RTRenderState(
            currentGain: initialGain,
            maxFrames: maxFrames,
            scratchL: l,
            scratchR: r
        ))
        return state
    }

    static func deallocate(_ state: UnsafeMutablePointer<RTRenderState>) {
        state.pointee.scratchL.deallocate()
        state.pointee.scratchR.deallocate()
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

        // Fast path 2: matching stereo buffer layout without soft clipping (gain <= 1.0) writes directly
        // from input to output via vDSP / memcpy, bypassing scratch round-trips and 2ch deinterleaving.
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

        // Extract stereo (L, R) from input AudioBufferList.
        let inFramesAvailable = extractStereoInput(
            inBuffers: inBuffers,
            layout: inputLayout,
            maxFrames: frames,
            destL: state.pointee.scratchL,
            destR: state.pointee.scratchR
        )

        guard inFramesAvailable > 0 else {
            zeroOutput(outBuffers: outBuffers)
            params.recordInputActivity(rms: 0)
            state.pointee.currentGain = targetGain
            return
        }

        // Measure input RMS before gain for silence / permission probe detection.
        var rmsL: Float = 0
        var rmsR: Float = 0
        vDSP_rmsqv(state.pointee.scratchL, 1, &rmsL, vDSP_Length(inFramesAvailable))
        vDSP_rmsqv(state.pointee.scratchR, 1, &rmsR, vDSP_Length(inFramesAvailable))
        let rms = max(rmsL, rmsR)
        params.recordInputActivity(rms: rms)

        // Apply smoothed linear gain ramp + soft limiting if needed.
        processStereoInPlace(
            left: state.pointee.scratchL,
            right: state.pointee.scratchR,
            frameCount: inFramesAvailable,
            startGain: startGain,
            targetGain: targetGain
        )
        state.pointee.currentGain = targetGain

        // If outFrames exceeded inFramesAvailable (unlikely, defensive), zero tail.
        if inFramesAvailable < outFrames {
            zeroOutput(outBuffers: outBuffers)
        }

        writeStereoToOutput(
            srcL: state.pointee.scratchL,
            srcR: state.pointee.scratchR,
            frameCount: inFramesAvailable,
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
        guard frameCount > 0 else { return }

        if startGain == 0 && targetGain == 0 {
            vDSP_vclr(left, 1, vDSP_Length(frameCount))
            vDSP_vclr(right, 1, vDSP_Length(frameCount))
            return
        }

        if startGain == targetGain {
            if targetGain != 1.0 {
                var g = targetGain
                vDSP_vsmul(left, 1, &g, left, 1, vDSP_Length(frameCount))
                vDSP_vsmul(right, 1, &g, right, 1, vDSP_Length(frameCount))
            }
        } else {
            var step = (targetGain - startGain) / Float(frameCount)
            var gL = startGain
            var gR = startGain
            vDSP_vrampmul(left, 1, &gL, &step, left, 1, vDSP_Length(frameCount))
            vDSP_vrampmul(right, 1, &gR, &step, right, 1, vDSP_Length(frameCount))
        }

        if startGain > 1.0 || targetGain > 1.0 {
            softClipInPlace(left, count: frameCount)
            softClipInPlace(right, count: frameCount)
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
        var levelL: Float = 0
        var levelR: Float = 0

        if layout.isNonInterleaved || inBuffers.count > 1 {
            guard let ptr0 = inBuffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return (0, 0)
            }
            let frames = min(maxFrames, Int(inBuffers[0].mDataByteSize) / MemoryLayout<Float>.size)
            guard frames > 0 else { return (0, 0) }
            vDSP_rmsqv(ptr0, 1, &levelL, vDSP_Length(frames))
            if inBuffers.count > 1, let ptr1 = inBuffers[1].mData?.assumingMemoryBound(to: Float.self) {
                let rFrames = min(frames, Int(inBuffers[1].mDataByteSize) / MemoryLayout<Float>.size)
                if rFrames > 0 {
                    vDSP_rmsqv(ptr1, 1, &levelR, vDSP_Length(rFrames))
                }
            } else {
                levelR = levelL
            }
            return (frames, max(levelL, levelR))
        } else {
            let buf = inBuffers[0]
            guard let raw = buf.mData?.assumingMemoryBound(to: Float.self) else { return (0, 0) }
            let channels = max(1, Int(buf.mNumberChannels))
            let frames = min(maxFrames, Int(buf.mDataByteSize) / (channels * MemoryLayout<Float>.size))
            guard frames > 0 else { return (0, 0) }
            if channels <= 2 {
                // Single contiguous vector peak scan across L/R is >4x faster than two strided vDSP_rmsqv passes.
                var peak: Float = 0
                vDSP_maxmgv(raw, 1, &peak, vDSP_Length(frames * channels))
                return (frames, peak)
            } else {
                vDSP_maxmgv(raw, vDSP_Stride(channels), &levelL, vDSP_Length(frames))
                vDSP_maxmgv(raw + 1, vDSP_Stride(channels), &levelR, vDSP_Length(frames))
                return (frames, max(levelL, levelR))
            }
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

        if inNonInterleaved && outNonInterleaved && outBuffers.count >= 2 {
            guard let inL = inBuffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let dstL = outBuffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let dstR = outBuffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                zeroOutput(outBuffers: outBuffers)
                return (0, 0)
            }
            let inR = inBuffers.count > 1 ? inBuffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            var frames = min(
                maxFrames,
                Int(inBuffers[0].mDataByteSize) / MemoryLayout<Float>.size,
                Int(outBuffers[0].mDataByteSize) / MemoryLayout<Float>.size,
                Int(outBuffers[1].mDataByteSize) / MemoryLayout<Float>.size
            )
            if inR != nil {
                frames = min(frames, Int(inBuffers[1].mDataByteSize) / MemoryLayout<Float>.size)
            }
            guard frames > 0 else {
                zeroOutput(outBuffers: outBuffers)
                return (0, 0)
            }

            var rmsL: Float = 0
            var rmsR: Float = 0
            vDSP_rmsqv(inL, 1, &rmsL, vDSP_Length(frames))
            if let inR {
                vDSP_rmsqv(inR, 1, &rmsR, vDSP_Length(frames))
            } else {
                rmsR = rmsL
            }

            if frames < outFrames {
                zeroOutput(outBuffers: outBuffers)
            }

            let srcR = inR ?? inL
            let count = vDSP_Length(frames)
            if startGain == 1.0 && targetGain == 1.0 {
                let byteCount = frames * MemoryLayout<Float>.size
                memcpy(dstL, inL, byteCount)
                memcpy(dstR, srcR, byteCount)
            } else if startGain == targetGain {
                var gain = targetGain
                vDSP_vsmul(inL, 1, &gain, dstL, 1, count)
                vDSP_vsmul(srcR, 1, &gain, dstR, 1, count)
            } else {
                var step = (targetGain - startGain) / Float(frames)
                var gL = startGain
                var gR = startGain
                vDSP_vrampmul(inL, 1, &gL, &step, dstL, 1, count)
                vDSP_vrampmul(srcR, 1, &gR, &step, dstR, 1, count)
            }

            if outBuffers.count > 2 {
                for c in 2..<outBuffers.count {
                    if let dstExtra = outBuffers[c].mData {
                        memset(dstExtra, 0, Int(outBuffers[c].mDataByteSize))
                    }
                }
            }
            return (frames, max(rmsL, rmsR))
        }

        if !inNonInterleaved && !outNonInterleaved && inBuffers.count == 1 && outBuffers.count == 1,
           let raw = inBuffers[0].mData?.assumingMemoryBound(to: Float.self),
           let dst = outBuffers[0].mData?.assumingMemoryBound(to: Float.self),
           inBuffers[0].mNumberChannels == 2,
           outBuffers[0].mNumberChannels == 2 {
            let frames = min(
                maxFrames,
                Int(inBuffers[0].mDataByteSize) / (2 * MemoryLayout<Float>.size),
                Int(outBuffers[0].mDataByteSize) / (2 * MemoryLayout<Float>.size)
            )
            guard frames > 0 else {
                zeroOutput(outBuffers: outBuffers)
                return (0, 0)
            }
            let totalSamples = vDSP_Length(frames * 2)
            var peak: Float = 0
            vDSP_maxmgv(raw, 1, &peak, totalSamples)

            if frames < outFrames {
                zeroOutput(outBuffers: outBuffers)
            }
            if startGain == 1.0 && targetGain == 1.0 {
                memcpy(dst, raw, frames * 2 * MemoryLayout<Float>.size)
            } else if startGain == targetGain {
                var gain = targetGain
                vDSP_vsmul(raw, 1, &gain, dst, 1, totalSamples)
            } else {
                var step = (targetGain - startGain) / Float(frames)
                var gL = startGain
                var gR = startGain
                vDSP_vrampmul(raw, 2, &gL, &step, dst, 2, vDSP_Length(frames))
                vDSP_vrampmul(raw + 1, 2, &gR, &step, dst + 1, 2, vDSP_Length(frames))
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
    private static func extractStereoInput(
        inBuffers: UnsafeMutableAudioBufferListPointer,
        layout: RTStreamLayout,
        maxFrames: Int,
        destL: UnsafeMutablePointer<Float>,
        destR: UnsafeMutablePointer<Float>
    ) -> Int {
        guard !inBuffers.isEmpty else { return 0 }

        if layout.isNonInterleaved || inBuffers.count > 1 {
            guard let ptr0 = inBuffers[0].mData?.assumingMemoryBound(to: Float.self) else {
                return 0
            }
            let frames = min(maxFrames, Int(inBuffers[0].mDataByteSize) / MemoryLayout<Float>.size)
            guard frames > 0 else { return 0 }
            memcpy(destL, ptr0, frames * MemoryLayout<Float>.size)
            if inBuffers.count > 1, let ptr1 = inBuffers[1].mData?.assumingMemoryBound(to: Float.self) {
                memcpy(destR, ptr1, frames * MemoryLayout<Float>.size)
            } else {
                memcpy(destR, ptr0, frames * MemoryLayout<Float>.size)
            }
            return frames
        } else {
            let buf = inBuffers[0]
            guard let raw = buf.mData?.assumingMemoryBound(to: Float.self) else { return 0 }
            let channels = max(1, Int(buf.mNumberChannels))
            let frames = min(maxFrames, Int(buf.mDataByteSize) / (channels * MemoryLayout<Float>.size))
            guard frames > 0 else { return 0 }

            if channels == 1 {
                memcpy(destL, raw, frames * MemoryLayout<Float>.size)
                memcpy(destR, raw, frames * MemoryLayout<Float>.size)
            } else if channels == 2 {
                var split = DSPSplitComplex(realp: destL, imagp: destR)
                raw.withMemoryRebound(to: DSPComplex.self, capacity: frames) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(frames))
                }
            } else {
                // Deinterleave channels 0 & 1 (stride = channels)
                for f in 0..<frames {
                    let base = f * channels
                    destL[f] = raw[base]
                    destR[f] = raw[base + 1]
                }
            }
            return frames
        }
    }

    @inline(__always)
    static func writeStereoToOutput(
        srcL: UnsafePointer<Float>,
        srcR: UnsafePointer<Float>,
        frameCount: Int,
        outBuffers: UnsafeMutableAudioBufferListPointer,
        outputLayout: RTStreamLayout
    ) {
        guard !outBuffers.isEmpty, frameCount > 0 else { return }

        if outputLayout.isNonInterleaved || outBuffers.count > 1 {
            let bufCount = outBuffers.count
            if bufCount == 1, let dst = outBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
                // Mono non-interleaved: (L + R) * 0.5
                var half: Float = 0.5
                vDSP_vasm(srcL, 1, srcR, 1, &half, dst, 1, vDSP_Length(frameCount))
            } else {
                if let dstL = outBuffers[0].mData?.assumingMemoryBound(to: Float.self) {
                    memcpy(dstL, srcL, frameCount * MemoryLayout<Float>.size)
                }
                if bufCount > 1, let dstR = outBuffers[1].mData?.assumingMemoryBound(to: Float.self) {
                    memcpy(dstR, srcR, frameCount * MemoryLayout<Float>.size)
                }
                if bufCount > 2 {
                    for c in 2..<bufCount {
                        if let dstExtra = outBuffers[c].mData {
                            memset(dstExtra, 0, Int(outBuffers[c].mDataByteSize))
                        }
                    }
                }
            }
        } else {
            let buf = outBuffers[0]
            guard let dst = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
            let channels = max(1, Int(buf.mNumberChannels))
            if channels == 1 {
                var half: Float = 0.5
                vDSP_vasm(srcL, 1, srcR, 1, &half, dst, 1, vDSP_Length(frameCount))
            } else if channels == 2 {
                var split = DSPSplitComplex(
                    realp: UnsafeMutablePointer(mutating: srcL),
                    imagp: UnsafeMutablePointer(mutating: srcR)
                )
                dst.withMemoryRebound(to: DSPComplex.self, capacity: frameCount) { complexPtr in
                    vDSP_ztoc(&split, 1, complexPtr, 2, vDSP_Length(frameCount))
                }
            } else {
                memset(dst, 0, Int(buf.mDataByteSize))
                for f in 0..<frameCount {
                    let base = f * channels
                    dst[base] = srcL[f]
                    dst[base + 1] = srcR[f]
                }
            }
        }
    }
}
