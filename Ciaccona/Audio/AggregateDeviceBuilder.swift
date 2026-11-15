import CoreAudio
import Foundation

enum AggregateDeviceBuilder {
    static func createPrivateAggregateDevice(
        name: String,
        outputDeviceUID: String,
        tapUUID: UUID,
        tapAutoStart: Bool = true
    ) throws -> AudioObjectID {
        let aggUID = AudioDevice.privateAggregateUIDPrefix + UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ],
            kAudioAggregateDeviceTapAutoStartKey: tapAutoStart
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        try caCheck(status, "AudioHardwareCreateAggregateDevice(\(name) -> \(outputDeviceUID))")
        return aggregateID
    }

    static func destroyAggregateDevice(_ aggregateID: AudioObjectID) {
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else { return }
        _ = AudioHardwareDestroyAggregateDevice(aggregateID)
    }
}
