import CoreAudio
import Foundation
import Testing
@testable import Ciaccona

@Suite("RTRenderer Tests")
struct RTRendererTests {
    @Test("Linear gain ramp interpolates smoothly without zipper jumps")
    func linearGainRamp() {
        let frames = 4
        var left: [Float] = [1.0, 1.0, 1.0, 1.0]
        var right: [Float] = [0.5, 0.5, 0.5, 0.5]

        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                RTRenderer.processStereoInPlace(
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!,
                    frameCount: frames,
                    startGain: 0.0,
                    targetGain: 1.0
                )
            }
        }

        #expect(abs(left[0] - 0.0) < 1e-5)
        #expect(abs(left[1] - 0.25) < 1e-5)
        #expect(abs(left[2] - 0.5) < 1e-5)
        #expect(abs(left[3] - 0.75) < 1e-5)

        #expect(abs(right[0] - 0.0) < 1e-5)
        #expect(abs(right[2] - 0.25) < 1e-5)
    }

    @Test("Soft limiter keeps boosted signal within [-1.0, 1.0]")
    func softLimiterBounds() {
        var left: [Float] = [0.95, -0.95, 0.2]
        var right: [Float] = [1.0, -1.0, -0.2]

        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                RTRenderer.processStereoInPlace(
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!,
                    frameCount: 3,
                    startGain: 1.5,
                    targetGain: 1.5
                )
            }
        }

        for sample in left + right {
            #expect(sample <= 1.0 && sample >= -1.0)
        }
        // Small signals still scale linearly by 1.5.
        #expect(abs(left[2] - 0.3) < 1e-5)
        #expect(abs(right[2] - (-0.3)) < 1e-5)
    }

    @Test("renderIO maps interleaved stereo input to 4-channel non-interleaved output and tracks RMS")
    func renderIOMultichannelAndRMS() {
        let frames = 8
        var inInterleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            inInterleaved[i * 2] = 0.4
            inInterleaved[i * 2 + 1] = -0.4
        }

        var outCh0 = [Float](repeating: 99, count: frames)
        var outCh1 = [Float](repeating: 99, count: frames)
        var outCh2 = [Float](repeating: 99, count: frames)
        var outCh3 = [Float](repeating: 99, count: frames)

        let params = RTParams(gain: 0.5, muted: false)
        let state = RTRenderState.allocate(initialGain: 0.5, maxFrames: 64)
        defer { RTRenderState.deallocate(state) }

        let inLayout = RTStreamLayout(channels: 2, isNonInterleaved: false, sampleRate: 48_000)
        let outLayout = RTStreamLayout(channels: 4, isNonInterleaved: true, sampleRate: 48_000)

        inInterleaved.withUnsafeMutableBytes { inBytes in
            outCh0.withUnsafeMutableBytes { c0 in
                outCh1.withUnsafeMutableBytes { c1 in
                    outCh2.withUnsafeMutableBytes { c2 in
                        outCh3.withUnsafeMutableBytes { c3 in
                            let inABL = AudioBufferList.allocate(maximumBuffers: 1)
                            inABL[0] = AudioBuffer(
                                mNumberChannels: 2,
                                mDataByteSize: UInt32(inBytes.count),
                                mData: inBytes.baseAddress
                            )
                            let outABL = AudioBufferList.allocate(maximumBuffers: 4)
                            outABL[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(c0.count), mData: c0.baseAddress)
                            outABL[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(c1.count), mData: c1.baseAddress)
                            outABL[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(c2.count), mData: c2.baseAddress)
                            outABL[3] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(c3.count), mData: c3.baseAddress)
                            defer {
                                free(inABL.unsafeMutablePointer)
                                free(outABL.unsafeMutablePointer)
                            }

                            RTRenderer.renderIO(
                                inInputData: inABL.unsafePointer,
                                outOutputData: outABL.unsafeMutablePointer,
                                inputLayout: inLayout,
                                outputLayout: outLayout,
                                params: params,
                                state: state
                            )
                        }
                    }
                }
            }
        }

        #expect(abs(outCh0[0] - 0.2) < 1e-5)
        #expect(abs(outCh1[0] - (-0.2)) < 1e-5)
        #expect(outCh2.allSatisfy { $0 == 0 })
        #expect(outCh3.allSatisfy { $0 == 0 })
        #expect(abs(params.loadMaxObservedRMS() - 0.4) < 1e-5)
        #expect(params.loadConsecutiveSilentBuffers() == 0)
    }

    @Test("renderIO unity non-interleaved fast path copies L/R, zeros extra channels, and tracks RMS")
    func renderIOUnityNonInterleavedFastPath() {
        let frames = 16
        var inCh0 = [Float](repeating: 0.35, count: frames)
        var inCh1 = [Float](repeating: -0.25, count: frames)
        var outCh0 = [Float](repeating: 99, count: frames)
        var outCh1 = [Float](repeating: 99, count: frames)
        var outCh2 = [Float](repeating: 99, count: frames)
        var outCh3 = [Float](repeating: 99, count: frames)

        let params = RTParams(gain: 1.0, muted: false)
        let state = RTRenderState.allocate(initialGain: 1.0, maxFrames: 64)
        defer { RTRenderState.deallocate(state) }

        let inLayout = RTStreamLayout(channels: 2, isNonInterleaved: true, sampleRate: 48_000)
        let outLayout = RTStreamLayout(channels: 4, isNonInterleaved: true, sampleRate: 48_000)

        inCh0.withUnsafeMutableBytes { i0 in
            inCh1.withUnsafeMutableBytes { i1 in
                outCh0.withUnsafeMutableBytes { o0 in
                    outCh1.withUnsafeMutableBytes { o1 in
                        outCh2.withUnsafeMutableBytes { o2 in
                            outCh3.withUnsafeMutableBytes { o3 in
                                let inABL = AudioBufferList.allocate(maximumBuffers: 2)
                                inABL[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(i0.count), mData: i0.baseAddress)
                                inABL[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(i1.count), mData: i1.baseAddress)

                                let outABL = AudioBufferList.allocate(maximumBuffers: 4)
                                outABL[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(o0.count), mData: o0.baseAddress)
                                outABL[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(o1.count), mData: o1.baseAddress)
                                outABL[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(o2.count), mData: o2.baseAddress)
                                outABL[3] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(o3.count), mData: o3.baseAddress)
                                defer {
                                    free(inABL.unsafeMutablePointer)
                                    free(outABL.unsafeMutablePointer)
                                }

                                RTRenderer.renderIO(
                                    inInputData: inABL.unsafePointer,
                                    outOutputData: outABL.unsafeMutablePointer,
                                    inputLayout: inLayout,
                                    outputLayout: outLayout,
                                    params: params,
                                    state: state
                                )
                            }
                        }
                    }
                }
            }
        }

        #expect(outCh0.allSatisfy { abs($0 - 0.35) < 1e-6 })
        #expect(outCh1.allSatisfy { abs($0 - (-0.25)) < 1e-6 })
        #expect(outCh2.allSatisfy { $0 == 0 })
        #expect(outCh3.allSatisfy { $0 == 0 })
        #expect(abs(params.loadMaxObservedRMS() - 0.35) < 1e-5)
        #expect(params.loadConsecutiveSilentBuffers() == 0)
    }

    @Test("renderIO unity interleaved stereo fast path copies exact L/R samples and tracks RMS")
    func renderIOUnityInterleavedFastPath() {
        let frames = 16
        var inInterleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            inInterleaved[i * 2] = 0.4
            inInterleaved[i * 2 + 1] = -0.25
        }
        var outInterleaved = [Float](repeating: 99, count: frames * 2)

        let params = RTParams(gain: 1.0, muted: false)
        let state = RTRenderState.allocate(initialGain: 1.0, maxFrames: 64)
        defer { RTRenderState.deallocate(state) }

        let layout = RTStreamLayout(channels: 2, isNonInterleaved: false, sampleRate: 48_000)

        inInterleaved.withUnsafeMutableBytes { inBytes in
            outInterleaved.withUnsafeMutableBytes { outBytes in
                let inABL = AudioBufferList.allocate(maximumBuffers: 1)
                inABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress)
                let outABL = AudioBufferList.allocate(maximumBuffers: 1)
                outABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress)
                defer {
                    free(inABL.unsafeMutablePointer)
                    free(outABL.unsafeMutablePointer)
                }

                RTRenderer.renderIO(
                    inInputData: inABL.unsafePointer,
                    outOutputData: outABL.unsafeMutablePointer,
                    inputLayout: layout,
                    outputLayout: layout,
                    params: params,
                    state: state
                )
            }
        }

        for i in 0..<frames {
            #expect(abs(outInterleaved[i * 2] - 0.4) < 1e-6)
            #expect(abs(outInterleaved[i * 2 + 1] - (-0.25)) < 1e-6)
        }
        #expect(abs(params.loadMaxObservedRMS() - 0.4) < 1e-5)
        #expect(params.loadConsecutiveSilentBuffers() == 0)
    }

    @Test("renderIO steady-state mute zeros output while still tracking non-silent input RMS")
    func renderIOSteadyStateMuteFastPath() {
        let frames = 16
        var inInterleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            inInterleaved[i * 2] = 0.4
            inInterleaved[i * 2 + 1] = -0.25
        }
        var outInterleaved = [Float](repeating: 99, count: frames * 2)

        let params = RTParams(gain: 0.0, muted: true)
        let state = RTRenderState.allocate(initialGain: 0.0, maxFrames: 64)
        defer { RTRenderState.deallocate(state) }

        let layout = RTStreamLayout(channels: 2, isNonInterleaved: false, sampleRate: 48_000)

        inInterleaved.withUnsafeMutableBytes { inBytes in
            outInterleaved.withUnsafeMutableBytes { outBytes in
                let inABL = AudioBufferList.allocate(maximumBuffers: 1)
                inABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress)
                let outABL = AudioBufferList.allocate(maximumBuffers: 1)
                outABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress)
                defer {
                    free(inABL.unsafeMutablePointer)
                    free(outABL.unsafeMutablePointer)
                }

                RTRenderer.renderIO(
                    inInputData: inABL.unsafePointer,
                    outOutputData: outABL.unsafeMutablePointer,
                    inputLayout: layout,
                    outputLayout: layout,
                    params: params,
                    state: state
                )
            }
        }

        #expect(outInterleaved.allSatisfy { $0 == 0 })
        #expect(params.loadMaxObservedRMS() > 0.39)
        #expect(params.loadConsecutiveSilentBuffers() == 0)
    }

    @Test("renderIO direct scaled 2-channel interleaved stereo scales exact L/R samples")
    func renderIOGainedInterleavedStereo() {
        let frames = 17
        var inInterleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            inInterleaved[i * 2] = 0.4
            inInterleaved[i * 2 + 1] = -0.25
        }
        var outInterleaved = [Float](repeating: 99, count: frames * 2)

        let params = RTParams(gain: 0.5, muted: false)
        let state = RTRenderState.allocate(initialGain: 0.5, maxFrames: 64)
        defer { RTRenderState.deallocate(state) }

        let layout = RTStreamLayout(channels: 2, isNonInterleaved: false, sampleRate: 48_000)

        inInterleaved.withUnsafeMutableBytes { inBytes in
            outInterleaved.withUnsafeMutableBytes { outBytes in
                let inABL = AudioBufferList.allocate(maximumBuffers: 1)
                inABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress)
                let outABL = AudioBufferList.allocate(maximumBuffers: 1)
                outABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress)
                defer {
                    free(inABL.unsafeMutablePointer)
                    free(outABL.unsafeMutablePointer)
                }

                RTRenderer.renderIO(
                    inInputData: inABL.unsafePointer,
                    outOutputData: outABL.unsafeMutablePointer,
                    inputLayout: layout,
                    outputLayout: layout,
                    params: params,
                    state: state
                )
            }
        }

        for i in 0..<frames {
            #expect(abs(outInterleaved[i * 2] - 0.2) < 1e-5)
            #expect(abs(outInterleaved[i * 2 + 1] - (-0.125)) < 1e-5)
        }
    }

    @Test("processStereoInPlace bypasses soft clip when post-gain magnitude does not exceed 0.9")
    func processStereoLinearBelowKnee() {
        let frames = 16
        var left = [Float](repeating: 0.5, count: frames)
        var right = [Float](repeating: -0.5, count: frames)

        left.withUnsafeMutableBufferPointer { lBuf in
            right.withUnsafeMutableBufferPointer { rBuf in
                RTRenderer.processStereoInPlace(
                    left: lBuf.baseAddress!,
                    right: rBuf.baseAddress!,
                    frameCount: frames,
                    startGain: 1.4,
                    targetGain: 1.4
                )
            }
        }

        #expect(left.allSatisfy { abs($0 - 0.7) < 1e-5 })
        #expect(right.allSatisfy { abs($0 - (-0.7)) < 1e-5 })
    }

    @Test("renderIO direct scaled non-interleaved fast path scales steady and ramped L/R without scratch")
    func renderIODirectScaledNonInterleaved() {
        let frames = 16
        var inCh0 = [Float](repeating: 0.4, count: frames)
        var inCh1 = [Float](repeating: -0.25, count: frames)
        var outCh0 = [Float](repeating: 99, count: frames)
        var outCh1 = [Float](repeating: 99, count: frames)
        var outCh2 = [Float](repeating: 99, count: frames)

        let params = RTParams(gain: 0.5, muted: false)
        let state = RTRenderState.allocate(initialGain: 0.5, maxFrames: 4) // Smaller than frames to prove direct path bypasses scratch
        defer { RTRenderState.deallocate(state) }

        let inLayout = RTStreamLayout(channels: 2, isNonInterleaved: true, sampleRate: 48_000)
        let outLayout = RTStreamLayout(channels: 3, isNonInterleaved: true, sampleRate: 48_000)

        let runRender = {
            inCh0.withUnsafeMutableBytes { i0 in
                inCh1.withUnsafeMutableBytes { i1 in
                    outCh0.withUnsafeMutableBytes { o0 in
                        outCh1.withUnsafeMutableBytes { o1 in
                            outCh2.withUnsafeMutableBytes { o2 in
                                let inABL = AudioBufferList.allocate(maximumBuffers: 2)
                                inABL[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(i0.count), mData: i0.baseAddress)
                                inABL[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(i1.count), mData: i1.baseAddress)
                                let outABL = AudioBufferList.allocate(maximumBuffers: 3)
                                outABL[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(o0.count), mData: o0.baseAddress)
                                outABL[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(o1.count), mData: o1.baseAddress)
                                outABL[2] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(o2.count), mData: o2.baseAddress)
                                defer {
                                    free(inABL.unsafeMutablePointer)
                                    free(outABL.unsafeMutablePointer)
                                }

                                RTRenderer.renderIO(
                                    inInputData: inABL.unsafePointer,
                                    outOutputData: outABL.unsafeMutablePointer,
                                    inputLayout: inLayout,
                                    outputLayout: outLayout,
                                    params: params,
                                    state: state
                                )
                            }
                        }
                    }
                }
            }
        }

        // Steady 0.5 gain
        runRender()
        #expect(outCh0.allSatisfy { abs($0 - 0.2) < 1e-5 })
        #expect(outCh1.allSatisfy { abs($0 - (-0.125)) < 1e-5 })
        #expect(outCh2.allSatisfy { $0 == 0 })

        // Ramp 0.5 -> 0.9
        params.setGain(0.9)
        runRender()
        #expect(abs(outCh0[0] - 0.2) < 1e-5)
        #expect(abs(outCh1[0] - (-0.125)) < 1e-5)
        #expect(outCh0.last! > outCh0.first!)
        #expect(outCh1.last! < outCh1.first!)
        #expect(outCh2.allSatisfy { $0 == 0 })
    }

    @Test("renderIO direct scaled interleaved ramp and boosted fallback preserve L/R channel accuracy")
    func renderIOInterleavedRampAndBoostedFallback() {
        let frames = 17
        var inInterleaved = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            inInterleaved[i * 2] = 0.4
            inInterleaved[i * 2 + 1] = -0.25
        }
        var outInterleaved = [Float](repeating: 99, count: frames * 2)

        let params = RTParams(gain: 0.8, muted: false)
        let state = RTRenderState.allocate(initialGain: 0.2, maxFrames: 64)
        defer { RTRenderState.deallocate(state) }

        let layout = RTStreamLayout(channels: 2, isNonInterleaved: false, sampleRate: 48_000)

        let runRender = {
            inInterleaved.withUnsafeMutableBytes { inBytes in
                outInterleaved.withUnsafeMutableBytes { outBytes in
                    let inABL = AudioBufferList.allocate(maximumBuffers: 1)
                    inABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress)
                    let outABL = AudioBufferList.allocate(maximumBuffers: 1)
                    outABL[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress)
                    defer {
                        free(inABL.unsafeMutablePointer)
                        free(outABL.unsafeMutablePointer)
                    }

                    RTRenderer.renderIO(
                        inInputData: inABL.unsafePointer,
                        outOutputData: outABL.unsafeMutablePointer,
                        inputLayout: layout,
                        outputLayout: layout,
                        params: params,
                        state: state
                    )
                }
            }
        }

        // Direct interleaved ramp 0.2 -> 0.8
        runRender()
        #expect(abs(outInterleaved[0] - 0.08) < 1e-5)
        #expect(abs(outInterleaved[1] - (-0.05)) < 1e-5)
        #expect(outInterleaved[(frames - 1) * 2] > outInterleaved[0])
        #expect(outInterleaved[(frames - 1) * 2 + 1] < outInterleaved[1])

        // Boosted (> 1.0) steady 1.2 exercises vDSP_ctoz / vDSP_ztoc path
        params.setGain(1.2)
        state.pointee.currentGain = 1.2
        runRender()
        for i in 0..<frames {
            #expect(abs(outInterleaved[i * 2] - 0.48) < 1e-5)
            #expect(abs(outInterleaved[i * 2 + 1] - (-0.3)) < 1e-5)
        }
    }

    @Test("RTRenderState default scratch allocation uses 4096 frames per channel")
    func renderStateDefaultCapacity() {
        let state = RTRenderState.allocate(initialGain: 1.0)
        defer { RTRenderState.deallocate(state) }
        #expect(state.pointee.maxFrames == 4_096)
    }
}
