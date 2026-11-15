import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    let status: OSStatus
    let context: String

    var fourCC: String? {
        let bytes: [UInt8] = [
            UInt8((UInt32(bitPattern: status) >> 24) & 0xFF),
            UInt8((UInt32(bitPattern: status) >> 16) & 0xFF),
            UInt8((UInt32(bitPattern: status) >> 8) & 0xFF),
            UInt8(UInt32(bitPattern: status) & 0xFF)
        ]
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    var description: String {
        if let code = fourCC {
            return "\(context): OSStatus \(status) ('\(code)')"
        }
        return "\(context): OSStatus \(status)"
    }
}

@inline(__always)
func caCheck(_ status: OSStatus, _ context: @autoclosure () -> String) throws {
    guard status == noErr else {
        throw CoreAudioError(status: status, context: context())
    }
}
