import CoreAudio
import Dispatch
import Foundation
import Synchronization

final class ListenerToken: @unchecked Sendable {
    private let active = Mutex(true)
    private let objectID: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.block = block
    }

    func invalidate() {
        let shouldRemove = active.withLock { isActive -> Bool in
            guard isActive else { return false }
            isActive = false
            return true
        }
        guard shouldRemove else { return }
        var addr = address
        AudioObjectRemovePropertyListenerBlock(objectID, &addr, queue, block)
    }

    deinit {
        invalidate()
    }
}

extension AudioObject {
    func observe(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) -> ListenerToken? {
        var addr = address(selector, scope: scope, element: element)
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            handler()
        }
        let status = AudioObjectAddPropertyListenerBlock(id, &addr, queue, block)
        guard status == noErr else { return nil }
        return ListenerToken(objectID: id, address: addr, queue: queue, block: block)
    }
}
