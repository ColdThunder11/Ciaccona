import CoreAudio
import Foundation

enum TapBuilder {
    static func createProcessTap(
        name: String,
        processes: [AudioObjectID],
        tapDeviceUID: String? = nil,
        uuid: UUID = UUID(),
        muteBehavior: CATapMuteBehavior = .mutedWhenTapped
    ) throws -> AudioObjectID {
        let description = makeDescription(
            name: name,
            processes: processes,
            tapDeviceUID: tapDeviceUID,
            uuid: uuid,
            muteBehavior: muteBehavior
        )
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        try caCheck(status, "AudioHardwareCreateProcessTap(\(name))")
        return tapID
    }

    static func createGlobalTap(
        name: String,
        excludingProcesses: [AudioObjectID] = [],
        deviceUID: String? = nil,
        preserveMultichannel: Bool = false,
        uuid: UUID = UUID(),
        muteBehavior: CATapMuteBehavior = .unmuted
    ) throws -> AudioObjectID {
        let desc = makeGlobalDescription(
            name: name,
            excludingProcesses: excludingProcesses,
            deviceUID: deviceUID,
            preserveMultichannel: preserveMultichannel,
            uuid: uuid,
            muteBehavior: muteBehavior
        )
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        try caCheck(status, "AudioHardwareCreateProcessTap(global:\(name))")
        return tapID
    }

    static func updateProcesses(
        tapID: AudioObjectID,
        name: String,
        processes: [AudioObjectID],
        tapDeviceUID: String? = nil,
        uuid: UUID,
        muteBehavior: CATapMuteBehavior = .mutedWhenTapped
    ) throws {
        let description = makeDescription(
            name: name,
            processes: processes,
            tapDeviceUID: tapDeviceUID,
            uuid: uuid,
            muteBehavior: muteBehavior
        )
        try AudioObject(id: tapID).setObject(kAudioTapPropertyDescription, object: description)
    }

    static func updateGlobalTap(
        tapID: AudioObjectID,
        name: String,
        excludingProcesses: [AudioObjectID],
        deviceUID: String? = nil,
        preserveMultichannel: Bool = false,
        uuid: UUID,
        muteBehavior: CATapMuteBehavior = .mutedWhenTapped
    ) throws {
        let description = makeGlobalDescription(
            name: name,
            excludingProcesses: excludingProcesses,
            deviceUID: deviceUID,
            preserveMultichannel: preserveMultichannel,
            uuid: uuid,
            muteBehavior: muteBehavior
        )
        try AudioObject(id: tapID).setObject(kAudioTapPropertyDescription, object: description)
    }

    static func readFormat(tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try AudioObject(id: tapID).get(kAudioTapPropertyFormat)
    }

    static func destroyTap(_ tapID: AudioObjectID) {
        guard tapID != AudioObjectID(kAudioObjectUnknown) else { return }
        _ = AudioHardwareDestroyProcessTap(tapID)
    }

    private static func makeGlobalDescription(
        name: String,
        excludingProcesses: [AudioObjectID],
        deviceUID: String?,
        preserveMultichannel: Bool,
        uuid: UUID,
        muteBehavior: CATapMuteBehavior
    ) -> CATapDescription {
        let desc: CATapDescription
        if preserveMultichannel, let deviceUID, !deviceUID.isEmpty {
            desc = CATapDescription(excludingProcesses: excludingProcesses, deviceUID: deviceUID, stream: 0)
        } else {
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excludingProcesses)
            desc.deviceUID = deviceUID
        }
        desc.name = name
        desc.uuid = uuid
        desc.isPrivate = true
        desc.muteBehavior = muteBehavior
        return desc
    }

    private static func makeDescription(
        name: String,
        processes: [AudioObjectID],
        tapDeviceUID: String?,
        uuid: UUID,
        muteBehavior: CATapMuteBehavior
    ) -> CATapDescription {
        let desc: CATapDescription
        if let tapDeviceUID, !tapDeviceUID.isEmpty {
            desc = CATapDescription(processes: processes, deviceUID: tapDeviceUID, stream: 0)
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        desc.name = name
        desc.uuid = uuid
        desc.isPrivate = true
        desc.muteBehavior = muteBehavior
        return desc
    }
}
