import AppKit
import SwiftUI

struct PermissionWaitView: View {
    var appState: AppState
    let onOpenSettings: () -> Void
    let onQuit: () -> Void

    private var remainingSeconds: Int {
        if case let .awaitingUser(seconds) = appState.permissionGateState {
            return seconds
        }
        return PermissionGate.maxWaitSeconds
    }

    var body: some View {
        let lang = appState.preferences.language

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr(
                        "permission.wait.headline",
                        defaultValue: "Please allow \"System Audio Recording\" in the system prompt",
                        language: lang
                    ))
                        .font(.headline)
                    Text(L10n.trFormat(
                        "permission.wait.detail",
                        defaultValue: "Ciaccona needs this permission to adjust volume and output devices per app. Time remaining: %d s",
                        language: lang,
                        remainingSeconds
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ProgressView(value: Double(remainingSeconds), total: Double(PermissionGate.maxWaitSeconds))

            HStack {
                Button(
                    L10n.tr("permission.open_system_settings", defaultValue: "Open System Settings", language: lang),
                    action: onOpenSettings
                )
                Spacer()
                Button(
                    L10n.tr("permission.quit", defaultValue: "Quit", language: lang),
                    role: .cancel,
                    action: onQuit
                )
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

@MainActor
final class PermissionWaitWindowController: NSWindowController {
    init(
        appState: AppState,
        onOpenSettings: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        let hosting = NSHostingController(
            rootView: PermissionWaitView(
                appState: appState,
                onOpenSettings: onOpenSettings,
                onQuit: onQuit
            )
        )
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.tr("permission.window.title", defaultValue: "Ciaccona Permission Request")
        window.styleMask = [.titled]
        window.level = .floating
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
