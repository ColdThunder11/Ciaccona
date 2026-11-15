import CoreAudio
import AudioToolbox
import Foundation

struct AudioDevice: Identifiable, Hashable, Sendable {
    static let privateAggregateUIDPrefix = "com.coldthunder11.ciaccona.agg."

    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let hasOutput: Bool
    let outputChannelCount: Int
    let canSetVolume: Bool
    let canMute: Bool
    let sampleRate: Double
    let isHidden: Bool

    init(
        id: AudioObjectID,
        uid: String,
        name: String,
        transport: UInt32,
        hasOutput: Bool,
        outputChannelCount: Int,
        canSetVolume: Bool,
        canMute: Bool,
        sampleRate: Double,
        isHidden: Bool = false
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
        self.hasOutput = hasOutput
        self.outputChannelCount = outputChannelCount
        self.canSetVolume = canSetVolume
        self.canMute = canMute
        self.sampleRate = sampleRate
        self.isHidden = isHidden
    }

    var isPrivateAggregate: Bool {
        uid.hasPrefix(Self.privateAggregateUIDPrefix)
    }

    /// Transient per-process aggregate devices spawned by Core Audio (e.g. `CADefaultDeviceAggregate-<pid>-<idx>`).
    var isSystemTransientAggregate: Bool {
        let prefixes = ["CADefaultDeviceAggregate", "CADDefaultDevice"]
        return prefixes.contains { uid.hasPrefix($0) || name.hasPrefix($0) }
    }

    var isSelectableOutput: Bool {
        hasOutput && !isHidden && !isPrivateAggregate && !isSystemTransientAggregate
    }

    var systemIconName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "airpodspro"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeAggregate:
            return "rectangle.stack"
        default:
            return "hifispeaker"
        }
    }

    static func load(id: AudioObjectID) -> AudioDevice? {
        let obj = AudioObject(id: id)
        guard obj.isValid else { return nil }
        guard let uid = obj.getOptionalString(kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        let name = obj.getOptionalString(kAudioObjectPropertyName) ?? uid
        let transport: UInt32 = (try? obj.get(kAudioDevicePropertyTransportType)) ?? kAudioDeviceTransportTypeUnknown
        let outChannels = obj.channelCount(scope: kAudioDevicePropertyScopeOutput)
        let hasOutput = outChannels > 0

        let canSetVolume = obj.isSettable(
            kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            scope: kAudioDevicePropertyScopeOutput
        )
        let canMute = obj.isSettable(
            kAudioDevicePropertyMute,
            scope: kAudioDevicePropertyScopeOutput
        )
        let sampleRate: Float64 = (try? obj.get(kAudioDevicePropertyNominalSampleRate)) ?? 48_000
        let hiddenRaw: UInt32 = (try? obj.get(kAudioDevicePropertyIsHidden)) ?? 0

        return AudioDevice(
            id: id,
            uid: uid,
            name: name,
            transport: transport,
            hasOutput: hasOutput,
            outputChannelCount: outChannels,
            canSetVolume: canSetVolume,
            canMute: canMute,
            sampleRate: sampleRate,
            isHidden: hiddenRaw != 0
        )
    }
}
