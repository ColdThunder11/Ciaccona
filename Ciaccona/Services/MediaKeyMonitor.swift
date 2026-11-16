import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

enum MediaKeyAction: Equatable, Sendable {
    case volumeUp
    case volumeDown
    case muteToggle
}

struct MediaKeyEvent: Equatable, Sendable {
    let action: MediaKeyAction
    let isKeyDown: Bool
    let isFineStep: Bool
}

enum MediaKeyParser {
    // NX_SUBTYPE_AUX_CONTROL_BUTTONS (IOKit/hidsystem/ev_keymap.h)
    private static let auxControlSubtype: Int16 = 8
    private static let soundUpKeyCode = 0
    private static let soundDownKeyCode = 1
    private static let muteKeyCode = 7
    private static let keyDownState = 0x0A
    private static let keyUpState = 0x0B

    static func parse(
        subtype: Int16,
        data1: Int,
        modifierFlags: NSEvent.ModifierFlags
    ) -> MediaKeyEvent? {
        guard subtype == auxControlSubtype else { return nil }

        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let action: MediaKeyAction
        switch keyCode {
        case soundUpKeyCode:
            action = .volumeUp
        case soundDownKeyCode:
            action = .volumeDown
        case muteKeyCode:
            action = .muteToggle
        default:
            return nil
        }

        let keyFlags = data1 & 0x0000_FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown: Bool
        switch keyState {
        case keyDownState:
            isKeyDown = true
        case keyUpState:
            isKeyDown = false
        default:
            return nil
        }

        let isFineStep = modifierFlags.contains([.option, .shift])
        return MediaKeyEvent(action: action, isKeyDown: isKeyDown, isFineStep: isFineStep)
    }

    static func parse(_ event: NSEvent) -> MediaKeyEvent? {
        guard event.type == .systemDefined else { return nil }
        return parse(
            subtype: event.subtype.rawValue,
            data1: event.data1,
            modifierFlags: event.modifierFlags
        )
    }
}

/// Captures macOS volume media keys via CGEventTap only when explicitly enabled,
/// intercepting events exclusively for devices lacking hardware volume/mute control.
@MainActor
final class MediaKeyMonitor {
    private static let logger = Logger(subsystem: "com.coldthunder11.ciaccona", category: "MediaKeyMonitor")
    private static let systemDefinedEventTypeRaw: UInt32 = 14 // NX_SYSDEFINED

    var shouldIntercept: ((MediaKeyAction) -> Bool)?
    var onMediaKey: ((MediaKeyAction, Bool) -> Void)?
    var onPermissionStateChanged: ((Bool) -> Void)?

    private var isEnabled = false
    nonisolated(unsafe) private var tapPort: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    nonisolated(unsafe) private var becomeActiveObserver: NSObjectProtocol?

    private(set) var needsAccessibilityPermission = false {
        didSet {
            if oldValue != needsAccessibilityPermission {
                onPermissionStateChanged?(needsAccessibilityPermission)
            }
        }
    }

    init() {}

    deinit {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tapPort {
            CFMachPortInvalidate(tapPort)
        }
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
        }
    }

    func setEnabled(_ enabled: Bool, promptIfNeeded: Bool = false) {
        isEnabled = enabled
        if enabled {
            startTapIfNeeded(promptIfNeeded: promptIfNeeded)
        } else {
            stopTap()
            needsAccessibilityPermission = false
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startTapIfNeeded(promptIfNeeded: Bool) {
        guard tapPort == nil else {
            needsAccessibilityPermission = false
            return
        }

        if promptIfNeeded && !AXIsProcessTrusted() {
            // Request Accessibility prompt explicitly when the user toggles this feature on.
            let promptKey = "AXTrustedCheckOptionPrompt" as CFString
            let options = [promptKey: kCFBooleanTrue] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        let mask = CGEventMask(1) << Self.systemDefinedEventTypeRaw
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, refcon in
                guard let refcon else {
                    return Unmanaged.passUnretained(cgEvent)
                }
                let refconAddress = UInt(bitPattern: refcon)

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated {
                        guard let ptr = UnsafeRawPointer(bitPattern: refconAddress) else { return }
                        let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(ptr).takeUnretainedValue()
                        monitor.reenableTap()
                    }
                    return Unmanaged.passUnretained(cgEvent)
                }

                guard type.rawValue == MediaKeyMonitor.systemDefinedEventTypeRaw,
                      let nsEvent = NSEvent(cgEvent: cgEvent),
                      let parsed = MediaKeyParser.parse(nsEvent) else {
                    return Unmanaged.passUnretained(cgEvent)
                }

                let intercepted = MainActor.assumeIsolated {
                    guard let ptr = UnsafeRawPointer(bitPattern: refconAddress) else { return false }
                    let monitor = Unmanaged<MediaKeyMonitor>.fromOpaque(ptr).takeUnretainedValue()
                    return monitor.handleParsedMediaKey(parsed)
                }
                return intercepted ? nil : Unmanaged.passUnretained(cgEvent)
            },
            userInfo: userInfo
        ) else {
            Self.logger.info("Unable to create CGEventTap for volume media keys; awaiting Accessibility permission")
            needsAccessibilityPermission = true
            observeActivationForRetry()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        tapPort = port
        runLoopSource = source
        needsAccessibilityPermission = false
        removeActivationObserver()
    }

    private func stopTap() {
        removeActivationObserver()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let port = tapPort {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
            tapPort = nil
        }
    }

    private func observeActivationForRetry() {
        guard becomeActiveObserver == nil else { return }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled, self.tapPort == nil else { return }
                self.startTapIfNeeded(promptIfNeeded: false)
            }
        }
    }

    private func removeActivationObserver() {
        if let observer = becomeActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            becomeActiveObserver = nil
        }
    }

    private func reenableTap() {
        if let tapPort {
            CGEvent.tapEnable(tap: tapPort, enable: true)
        }
    }

    private func handleParsedMediaKey(_ parsed: MediaKeyEvent) -> Bool {
        guard shouldIntercept?(parsed.action) == true else {
            return false
        }
        if parsed.isKeyDown {
            onMediaKey?(parsed.action, parsed.isFineStep)
        }
        return true
    }
}
