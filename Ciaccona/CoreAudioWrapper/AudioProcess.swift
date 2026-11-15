import CoreAudio
import Foundation

struct AudioProcess: Identifiable, Hashable, Sendable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    var isRunningOutput: Bool

    static func load(id: AudioObjectID) -> AudioProcess? {
        let obj = AudioObject(id: id)
        guard obj.isValid else { return nil }
        guard let pid: pid_t = try? obj.get(kAudioProcessPropertyPID), pid > 0 else {
            return nil
        }
        let bundleID = obj.getOptionalString(kAudioProcessPropertyBundleID)
        let runningRaw: UInt32 = (try? obj.get(kAudioProcessPropertyIsRunningOutput)) ?? 0
        return AudioProcess(
            id: id,
            pid: pid,
            bundleID: bundleID,
            isRunningOutput: runningRaw != 0
        )
    }
}
