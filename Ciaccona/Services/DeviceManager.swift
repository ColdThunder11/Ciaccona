import CoreAudio
import Foundation
import OSLog

@AudioControlActor
final class DeviceManager {
    private static let logger = Logger(subsystem: "com.coldthunder11.ciaccona", category: "DeviceManager")

    private(set) var outputDevices: [AudioDevice] = []
    private(set) var defaultOutputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private(set) var defaultSystemOutputDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    var onDevicesChanged: (@AudioControlActor @Sendable ([AudioDevice], AudioObjectID) -> Void)?
    var onSystemAlertDeviceChanged: (@AudioControlActor @Sendable (AudioObjectID) -> Void)?
    var onSampleRateChanged: (@AudioControlActor @Sendable (AudioObjectID, String) -> Void)?
    var onServiceRestarted: (@AudioControlActor @Sendable () -> Void)?

    private var systemTokens: [ListenerToken] = []
    private var deviceRateTokens: [AudioObjectID: ListenerToken] = [:]
    private var deviceStreamConfigTokens: [AudioObjectID: ListenerToken] = [:]

    var defaultOutputDevice: AudioDevice? {
        outputDevices.first { $0.id == defaultOutputDeviceID }
    }

    func device(forUID uid: String) -> AudioDevice? {
        outputDevices.first { $0.uid == uid }
    }

    func device(forID id: AudioObjectID) -> AudioDevice? {
        outputDevices.first { $0.id == id }
    }

    func start() {
        stop()
        refreshAll()

        let q = AudioControlActor.queue
        if let t = AudioObject.system.observe(kAudioHardwarePropertyDevices, queue: q, handler: { [weak self] in
            AudioControlActor.assumeIsolatedOnQueue {
                self?.refreshAll()
            }
        }) {
            systemTokens.append(t)
        }

        if let t = AudioObject.system.observe(kAudioHardwarePropertyDefaultOutputDevice, queue: q, handler: { [weak self] in
            AudioControlActor.assumeIsolatedOnQueue {
                self?.refreshDefaultDevice()
            }
        }) {
            systemTokens.append(t)
        }

        if let t = AudioObject.system.observe(kAudioHardwarePropertyDefaultSystemOutputDevice, queue: q, handler: { [weak self] in
            AudioControlActor.assumeIsolatedOnQueue {
                self?.refreshSystemAlertDevice()
            }
        }) {
            systemTokens.append(t)
        }

        if let t = AudioObject.system.observe(kAudioHardwarePropertyServiceRestarted, queue: q, handler: { [weak self] in
            AudioControlActor.assumeIsolatedOnQueue {
                Self.logger.warning("coreaudiod service restarted")
                self?.refreshAll()
                self?.onServiceRestarted?()
            }
        }) {
            systemTokens.append(t)
        }
    }

    func stop() {
        systemTokens.forEach { $0.invalidate() }
        systemTokens.removeAll()
        deviceRateTokens.values.forEach { $0.invalidate() }
        deviceRateTokens.removeAll()
        deviceStreamConfigTokens.values.forEach { $0.invalidate() }
        deviceStreamConfigTokens.removeAll()
    }

    func setDefaultOutputDevice(_ deviceID: AudioObjectID) throws {
        try AudioObject.system.set(kAudioHardwarePropertyDefaultOutputDevice, value: deviceID)
        defaultOutputDeviceID = deviceID
        onDevicesChanged?(outputDevices, defaultOutputDeviceID)
    }

    func setDefaultSystemOutputDevice(_ deviceID: AudioObjectID) throws {
        try AudioObject.system.set(kAudioHardwarePropertyDefaultSystemOutputDevice, value: deviceID)
        defaultSystemOutputDeviceID = deviceID
        onSystemAlertDeviceChanged?(defaultSystemOutputDeviceID)
    }

    func refreshAll() {
        let allIDs: [AudioObjectID] = (try? AudioObject.system.getArray(kAudioHardwarePropertyDevices)) ?? []
        let loaded = allIDs
            .compactMap { AudioDevice.load(id: $0) }
            .filter(\.isSelectableOutput)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        outputDevices = loaded
        defaultOutputDeviceID = (try? AudioObject.system.get(kAudioHardwarePropertyDefaultOutputDevice))
            ?? AudioObjectID(kAudioObjectUnknown)
        defaultSystemOutputDeviceID = (try? AudioObject.system.get(kAudioHardwarePropertyDefaultSystemOutputDevice))
            ?? AudioObjectID(kAudioObjectUnknown)

        syncSampleRateObservers()
        onDevicesChanged?(outputDevices, defaultOutputDeviceID)
        onSystemAlertDeviceChanged?(defaultSystemOutputDeviceID)
    }

    private func refreshDefaultDevice() {
        let newID: AudioObjectID = (try? AudioObject.system.get(kAudioHardwarePropertyDefaultOutputDevice))
            ?? AudioObjectID(kAudioObjectUnknown)
        guard newID != defaultOutputDeviceID else { return }
        defaultOutputDeviceID = newID
        onDevicesChanged?(outputDevices, defaultOutputDeviceID)
    }

    private func refreshSystemAlertDevice() {
        let newID: AudioObjectID = (try? AudioObject.system.get(kAudioHardwarePropertyDefaultSystemOutputDevice))
            ?? AudioObjectID(kAudioObjectUnknown)
        guard newID != defaultSystemOutputDeviceID else { return }
        defaultSystemOutputDeviceID = newID
        onSystemAlertDeviceChanged?(newID)
    }

    private func syncSampleRateObservers() {
        let currentIDs = Set(outputDevices.map(\.id))
        for (id, token) in deviceRateTokens where !currentIDs.contains(id) {
            token.invalidate()
            deviceRateTokens.removeValue(forKey: id)
        }
        for (id, token) in deviceStreamConfigTokens where !currentIDs.contains(id) {
            token.invalidate()
            deviceStreamConfigTokens.removeValue(forKey: id)
        }

        let q = AudioControlActor.queue
        for device in outputDevices {
            let devID = device.id
            let devUID = device.uid
            if deviceRateTokens[devID] == nil,
               let token = AudioObject(id: devID).observe(
                   kAudioDevicePropertyNominalSampleRate,
                   queue: q,
                   handler: { [weak self] in
                       AudioControlActor.assumeIsolatedOnQueue {
                           self?.onSampleRateChanged?(devID, devUID)
                       }
                   }
               ) {
                deviceRateTokens[devID] = token
            }
            if deviceStreamConfigTokens[devID] == nil,
               let configToken = AudioObject(id: devID).observe(
                   kAudioDevicePropertyStreamConfiguration,
                   scope: kAudioDevicePropertyScopeOutput,
                   queue: q,
                   handler: { [weak self] in
                       AudioControlActor.assumeIsolatedOnQueue {
                           guard let self else { return }
                           let currentChannels = AudioObject(id: devID).channelCount(scope: kAudioDevicePropertyScopeOutput)
                           let knownChannels = self.outputDevices.first(where: { $0.id == devID })?.outputChannelCount
                           if knownChannels != currentChannels {
                               self.refreshAll()
                           }
                       }
                   }
               ) {
                deviceStreamConfigTokens[devID] = configToken
            }
        }
    }
}
