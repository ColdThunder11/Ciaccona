import Dispatch

@globalActor
actor AudioControlActor: GlobalActor {
    static let shared = AudioControlActor()
    static let queue = DispatchSerialQueue(label: "com.coldthunder11.ciaccona.AudioControlQueue")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.queue.asUnownedSerialExecutor()
    }

    /// Executes `operation` synchronously when the caller is already running on `AudioControlActor.queue`,
    /// avoiding an extra async `Task` hop from Core Audio property listeners.
    nonisolated static func assumeIsolatedOnQueue(_ operation: @AudioControlActor @Sendable () -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        shared.assumeIsolated { _ in
            withoutActuallyEscaping(operation) { escapingOperation in
                // Runtime executor check above guarantees we are executing on AudioControlActor's serial queue.
                let unisolatedOperation = unsafeBitCast(escapingOperation, to: (@Sendable () -> Void).self)
                unisolatedOperation()
            }
        }
    }
}
