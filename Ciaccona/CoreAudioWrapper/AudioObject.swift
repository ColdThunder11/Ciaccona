import CoreAudio
import Foundation

/// Restricts Core Audio property getters/setters to non-optional POD types so `try? ... ?? fallback`
/// cannot accidentally infer `Optional<T>` and pass the wrong byte size to HAL.
protocol AudioPropertyValue {}

extension UInt32: AudioPropertyValue {}
extension Int32: AudioPropertyValue {}
extension Float: AudioPropertyValue {}
extension Double: AudioPropertyValue {}
extension AudioStreamBasicDescription: AudioPropertyValue {}
extension AudioValueRange: AudioPropertyValue {}

struct AudioObject: Sendable, Hashable {
    let id: AudioObjectID

    static let system = AudioObject(id: AudioObjectID(kAudioObjectSystemObject))

    var isValid: Bool {
        id != AudioObjectID(kAudioObjectUnknown)
    }

    func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    func has(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var addr = address(selector, scope: scope, element: element)
        return AudioObjectHasProperty(id, &addr)
    }

    func isSettable(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> Bool {
        var addr = address(selector, scope: scope, element: element)
        guard AudioObjectHasProperty(id, &addr) else { return false }
        var settable: DarwinBoolean = false
        let status = AudioObjectIsPropertySettable(id, &addr, &settable)
        return status == noErr && settable.boolValue
    }

    func get<T: AudioPropertyValue>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> T {
        var addr = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        return try withUnsafeTemporaryAllocation(byteCount: Int(size), alignment: MemoryLayout<T>.alignment) { raw in
            let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw.baseAddress!)
            try caCheck(status, "AudioObjectGetPropertyData(\(id), selector=\(selector))")
            return raw.load(as: T.self)
        }
    }

    func get<Q: AudioPropertyValue, T: AudioPropertyValue>(
        _ selector: AudioObjectPropertySelector,
        qualifier: Q,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> T {
        var addr = address(selector, scope: scope, element: element)
        var q = qualifier
        let qSize = UInt32(MemoryLayout<Q>.size)
        var size = UInt32(MemoryLayout<T>.size)
        return try withUnsafeTemporaryAllocation(byteCount: Int(size), alignment: MemoryLayout<T>.alignment) { raw in
            let status = withUnsafePointer(to: &q) { qPtr in
                AudioObjectGetPropertyData(id, &addr, qSize, qPtr, &size, raw.baseAddress!)
            }
            try caCheck(status, "AudioObjectGetPropertyDataWithQualifier(\(id), selector=\(selector))")
            return raw.load(as: T.self)
        }
    }

    func getArray<T: AudioPropertyValue>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> [T] {
        var addr = address(selector, scope: scope, element: element)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        try caCheck(sizeStatus, "AudioObjectGetPropertyDataSize(\(id), selector=\(selector))")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }

        return try Array<T>(unsafeUninitializedCapacity: count) { buffer, initializedCount in
            var actualSize = size
            let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &actualSize, buffer.baseAddress!)
            try caCheck(status, "AudioObjectGetPropertyData(\(id), selector=\(selector))")
            initializedCount = Int(actualSize) / MemoryLayout<T>.stride
        }
    }

    func getString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        var addr = address(selector, scope: scope, element: element)
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        try caCheck(status, "AudioObjectGetString(\(id), selector=\(selector))")
        guard let retained = cfStr?.takeRetainedValue() else {
            return ""
        }
        return retained as String
    }

    func getOptionalString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> String? {
        guard has(selector, scope: scope, element: element) else { return nil }
        guard let str = try? getString(selector, scope: scope, element: element), !str.isEmpty else {
            return nil
        }
        return str
    }

    func set<T: AudioPropertyValue>(
        _ selector: AudioObjectPropertySelector,
        value: T,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws {
        var addr = address(selector, scope: scope, element: element)
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &v) { ptr in
            AudioObjectSetPropertyData(id, &addr, 0, nil, size, ptr)
        }
        try caCheck(status, "AudioObjectSetPropertyData(\(id), selector=\(selector))")
    }

    func setObject<Obj: AnyObject>(
        _ selector: AudioObjectPropertySelector,
        object: Obj,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws {
        var addr = address(selector, scope: scope, element: element)
        var ref = Unmanaged.passUnretained(object)
        let size = UInt32(MemoryLayout<Unmanaged<Obj>>.size)
        let status = withUnsafePointer(to: &ref) { ptr in
            AudioObjectSetPropertyData(id, &addr, 0, nil, size, ptr)
        }
        try caCheck(status, "AudioObjectSetObject(\(id), selector=\(selector))")
    }

    func channelCount(scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        var actualSize = size
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &actualSize, raw) == noErr else {
            return 0
        }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
