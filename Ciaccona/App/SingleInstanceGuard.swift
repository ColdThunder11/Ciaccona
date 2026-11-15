import AppKit
import Darwin
import Foundation

/// Prevents multiple Ciaccona instances from running concurrently by combining
/// a bundle-identifier running-app check with an advisory `flock` lock file.
final class SingleInstanceGuard {
    private let lockFileURL: URL
    private var lockFileDescriptor: Int32 = -1

    init(lockFileURL: URL? = nil) {
        if let lockFileURL {
            self.lockFileURL = lockFileURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.lockFileURL = appSupport
                .appendingPathComponent("Ciaccona", isDirectory: true)
                .appendingPathComponent(".instance.lock", isDirectory: false)
        }
    }

    deinit {
        release()
    }

    /// Attempts to claim single-instance ownership.
    /// Returns `false` if another live instance is already active or holds the lock.
    func acquire(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        currentPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> Bool {
        if lockFileDescriptor >= 0 {
            return true
        }

        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            let otherRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .contains { app in
                    app.processIdentifier != currentPID && !app.isTerminated
                }
            if otherRunning {
                return false
            }
        }

        let directory = lockFileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // Fall back cleanly if the directory cannot be created; do not crash launch.
            return false
        }

        let fd = open(lockFileURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return false
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }

        ftruncate(fd, 0)
        var pidString = "\(currentPID)\n"
        _ = pidString.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return 0 }
            return write(fd, base, buffer.count)
        }

        lockFileDescriptor = fd
        return true
    }

    /// Releases the held advisory file lock, if any.
    func release() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }
}
