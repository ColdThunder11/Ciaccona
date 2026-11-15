import AudioToolbox
import CoreAudio
import Foundation

struct GlobalVolumeSnapshot: Sendable, Equatable {
    let volume: Float
    let isMuted: Bool
    let canSetVolume: Bool
    let canMute: Bool
    let isSoftwareVolume: Bool
    let isSoftwareMute: Bool

    init(
        volume: Float,
        isMuted: Bool,
        canSetVolume: Bool,
        canMute: Bool,
        isSoftwareVolume: Bool = false,
        isSoftwareMute: Bool = false
    ) {
        self.volume = volume
        self.isMuted = isMuted
        self.canSetVolume = canSetVolume
        self.canMute = canMute
        self.isSoftwareVolume = isSoftwareVolume
        self.isSoftwareMute = isSoftwareMute
    }
}

@AudioControlActor
final class GlobalVolumeController {
    private var observedDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var observedDevice: AudioDevice?
    private var tokens: [ListenerToken] = []

    var onVolumeChanged: (@Sendable (GlobalVolumeSnapshot) -> Void)?
    var softwareRuleProvider: ((String) -> DeviceVolumeRule)?

    func snapshot(of device: AudioDevice?) -> GlobalVolumeSnapshot {
        guard let device else {
            return GlobalVolumeSnapshot(volume: 0, isMuted: false, canSetVolume: false, canMute: false)
        }
        let softwareRule = (!device.canSetVolume || !device.canMute) ? softwareRuleProvider?(device.uid) : nil
        let isSoftwareVol = !device.canSetVolume
        let isSoftwareMute = !device.canMute
        let vol = isSoftwareVol ? (softwareRule?.volume ?? 1.0) : ((try? volume(of: device)) ?? 1.0)
        let muted = isSoftwareMute ? (softwareRule?.muted ?? false) : ((try? isMuted(device)) ?? false)
        return GlobalVolumeSnapshot(
            volume: vol,
            isMuted: muted,
            canSetVolume: true,
            canMute: true,
            isSoftwareVolume: isSoftwareVol,
            isSoftwareMute: isSoftwareMute
        )
    }

    func refreshSnapshot(for device: AudioDevice?) {
        if let device, device.id == observedDeviceID {
            observedDevice = device
        }
        onVolumeChanged?(snapshot(of: device))
    }

    func volume(of device: AudioDevice) throws -> Float {
        let obj = AudioObject(id: device.id)
        guard obj.has(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput) else {
            return 1.0
        }
        return try obj.get(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput
        )
    }

    func setVolume(_ value: Float, of device: AudioDevice) throws {
        let clamped = max(0.0, min(1.0, value))
        let obj = AudioObject(id: device.id)
        guard obj.isSettable(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput) else {
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, context: "Volume not settable on \(device.name)")
        }
        try obj.set(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            value: clamped,
            scope: kAudioDevicePropertyScopeOutput
        )
    }

    func isMuted(_ device: AudioDevice) throws -> Bool {
        let obj = AudioObject(id: device.id)
        guard obj.has(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) else {
            return false
        }
        let val: UInt32 = try obj.get(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        return val != 0
    }

    func setMuted(_ muted: Bool, of device: AudioDevice) throws {
        let obj = AudioObject(id: device.id)
        guard obj.isSettable(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput) else {
            throw CoreAudioError(status: kAudioHardwareUnsupportedOperationError, context: "Mute not settable on \(device.name)")
        }
        let val: UInt32 = muted ? 1 : 0
        try obj.set(kAudioDevicePropertyMute, value: val, scope: kAudioDevicePropertyScopeOutput)
    }

    func bind(to device: AudioDevice?) {
        let targetID = device?.id ?? AudioObjectID(kAudioObjectUnknown)
        if targetID == observedDeviceID, !tokens.isEmpty {
            observedDevice = device
            if let device {
                onVolumeChanged?(snapshot(of: device))
            }
            return
        }

        unbind()
        observedDeviceID = targetID
        observedDevice = device
        guard let device else {
            onVolumeChanged?(snapshot(of: nil))
            return
        }

        let q = AudioControlActor.queue
        let obj = AudioObject(id: device.id)

        if let volToken = obj.observe(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput,
            queue: q,
            handler: { [weak self] in
                AudioControlActor.assumeIsolatedOnQueue {
                    self?.emitCurrent(deviceID: device.id)
                }
            }
        ) {
            tokens.append(volToken)
        }

        if let muteToken = obj.observe(
            kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput,
            queue: q,
            handler: { [weak self] in
                AudioControlActor.assumeIsolatedOnQueue {
                    self?.emitCurrent(deviceID: device.id)
                }
            }
        ) {
            tokens.append(muteToken)
        }

        onVolumeChanged?(snapshot(of: device))
    }

    func unbind() {
        tokens.forEach { $0.invalidate() }
        tokens.removeAll()
        observedDeviceID = AudioObjectID(kAudioObjectUnknown)
        observedDevice = nil
    }

    private func emitCurrent(deviceID: AudioObjectID) {
        guard deviceID == observedDeviceID else { return }
        guard let dev = observedDevice ?? AudioDevice.load(id: deviceID) else { return }
        observedDevice = dev
        onVolumeChanged?(snapshot(of: dev))
    }
}
