import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private let singleInstanceGuard = SingleInstanceGuard()
    private let permissionGate = PermissionGate()
    private var waitWindowController: PermissionWaitWindowController?
    private var routingEngine: RoutingEngine?
    private var isHandlingRevocation = false
    private var isPrimaryInstance = false
    private var isPresentingAlreadyRunningAlert = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Avoid triggering TCC prompts or terminating when launched as an XCTest host.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }

        L10n.syncFromDiskIfNeeded()

        guard singleInstanceGuard.acquire() else {
            presentAlreadyRunningAlert()
            NSApp.terminate(nil)
            return
        }
        isPrimaryInstance = true

        permissionGate.onStateChanged = { [weak self] state in
            self?.handleGateStateChange(state)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let authorized = await self.permissionGate.ensureAuthorizedAtLaunch()
            self.waitWindowController?.close()
            self.waitWindowController = nil

            guard authorized else {
                let reason: String?
                if case let .denied(r) = self.appState.permissionGateState {
                    reason = r
                } else {
                    reason = nil
                }
                self.permissionGate.presentDenialAlertAndTerminate(reason: reason)
                return
            }

            await self.startAudioServices()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              isPrimaryInstance,
              !isPresentingAlreadyRunningAlert
        else {
            return false
        }

        presentAlreadyRunningAlert()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        singleInstanceGuard.release()
        let engine = routingEngine
        routingEngine = nil
        if let engine {
            Task { @AudioControlActor in
                engine.stopAll()
            }
        }
    }

    private func presentAlreadyRunningAlert() {
        isPresentingAlreadyRunningAlert = true
        defer { isPresentingAlreadyRunningAlert = false }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.tr(
            "instance.already_running.title",
            defaultValue: "Ciaccona Is Already Running"
        )
        alert.informativeText = L10n.tr(
            "instance.already_running.body",
            defaultValue: "Ciaccona is already running. If the menu bar icon is not visible, check whether it is crowded out by other app icons."
        )
        alert.addButton(
            withTitle: L10n.tr("instance.already_running.ok", defaultValue: "OK")
        )
        alert.runModal()
    }

    private func handleGateStateChange(_ state: PermissionGateState) {
        appState.permissionGateState = state
        switch state {
        case .awaitingUser:
            if waitWindowController == nil {
                waitWindowController = PermissionWaitWindowController(
                    appState: appState,
                    onOpenSettings: { [weak self] in
                        self?.permissionGate.openSystemAudioCaptureSettings()
                    },
                    onQuit: {
                        NSApp.terminate(nil)
                    }
                )
                waitWindowController?.showWindow(nil)
            }
        case .authorized, .denied, .probing:
            break
        }
    }

    private func startAudioServices() async {
        let state = appState
        let engine = await Task { @AudioControlActor () -> RoutingEngine in
            let dm = DeviceManager()
            let gvc = GlobalVolumeController()
            let pm = ProcessMonitor()
            let rs = RuleStore()
            let engine = RoutingEngine(
                deviceManager: dm,
                volumeController: gvc,
                processMonitor: pm,
                ruleStore: rs
            )

            engine.onDevicesChanged = { devices, defaultID in
                Task { @MainActor in
                    state.updateDevices(devices, defaultID: defaultID)
                }
            }
            gvc.onVolumeChanged = { snapshot in
                Task { @MainActor in
                    state.updateGlobalVolumeSnapshot(snapshot)
                }
            }
            engine.onSnapshotUpdated = { snapshot in
                Task { @MainActor in
                    state.applyRoutingSnapshot(snapshot)
                }
            }
            engine.onPermissionRevocationSuspected = { [weak self] in
                Task { @MainActor in
                    await self?.verifyPermissionAtRuntime()
                }
            }

            engine.start()
            return engine
        }.value

        self.routingEngine = engine
        appState.attachEngine(engine)
        appState.isAuthorized = true
    }

    private func verifyPermissionAtRuntime() async {
        guard !isHandlingRevocation else { return }
        isHandlingRevocation = true
        defer { isHandlingRevocation = false }

        let ok = await permissionGate.recheckPermission()
        guard !ok else { return }

        appState.isAuthorized = false
        let engine = routingEngine
        routingEngine = nil
        if let engine {
            await Task { @AudioControlActor in
                engine.stopAll()
            }.value
        }
        permissionGate.presentDenialAlertAndTerminate(reason: L10n.tr(
            "permission.revoked",
            defaultValue: "System Audio Recording permission was revoked"
        ))
    }
}

@main
struct CiacconaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra(
            "Ciaccona",
            systemImage: delegate.appState.menuBarSymbolName,
            isInserted: Binding(
                get: { delegate.appState.isAuthorized },
                set: { delegate.appState.isAuthorized = $0 }
            )
        ) {
            MenuPanelView(appState: delegate.appState)
                .environment(\.locale, L10n.locale(for: delegate.appState.preferences.language))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: delegate.appState)
                .environment(\.locale, L10n.locale(for: delegate.appState.preferences.language))
        }
    }
}
