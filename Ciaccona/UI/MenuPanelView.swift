import AppKit
import SwiftUI

struct MenuPanelView: View {
    @Bindable var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var scrollContentHeight: CGFloat = 120

    var body: some View {
        let lang = appState.preferences.language

        VStack(alignment: .leading, spacing: 10) {
            GlobalOutputSection(appState: appState)
                .padding(.horizontal, 14)

            Divider()
                .padding(.horizontal, 14)

            appRow(for: localizedSystemAlertApp(language: lang), fallbackSymbolName: "bell.fill")
                .padding(.horizontal, 14)

            Divider()
                .padding(.horizontal, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !appState.playingApps.isEmpty {
                        sectionHeader(L10n.tr("panel.section.playing", defaultValue: "Playing", language: lang))
                        ForEach(appState.playingApps) { app in
                            appRow(for: app)
                        }
                    }

                    if !appState.activeIdleApps.isEmpty {
                        sectionHeader(L10n.tr("panel.section.connected", defaultValue: "Connected Audio", language: lang))
                        ForEach(appState.activeIdleApps) { app in
                            appRow(for: app)
                        }
                    }

                    if appState.playingApps.isEmpty && appState.activeIdleApps.isEmpty {
                        HStack {
                            Spacer()
                            Text(L10n.tr("panel.empty_apps", defaultValue: "No apps are currently playing audio", language: lang))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 14)
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 14)
                .padding(.trailing, 16)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { newHeight in
                    if newHeight > 0 {
                        scrollContentHeight = newHeight
                    }
                }
            }
            .frame(height: min(max(scrollContentHeight, 48), 340))

            Divider()
                .padding(.horizontal, 14)

            HStack {
                FooterActionButton(
                    title: L10n.tr("panel.action.settings", defaultValue: "Settings", language: lang),
                    systemImage: "gearshape",
                    hoverTint: .accentColor,
                    rotateIconOnHover: true,
                    helpText: L10n.tr("panel.action.settings.help", defaultValue: "Open Settings", language: lang)
                ) {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }

                Spacer()

                FooterActionButton(
                    title: L10n.tr("panel.action.quit", defaultValue: "Quit", language: lang),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    hoverTint: .red,
                    rotateIconOnHover: false,
                    helpText: L10n.tr("panel.action.quit.help", defaultValue: "Quit Ciaccona", language: lang)
                ) {
                    NSApp.terminate(nil)
                }
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 14)
        .frame(width: 370)
    }

    private func localizedSystemAlertApp(language: AppLanguage) -> AudioApp {
        let base = appState.systemAlertApp
        return AudioApp(
            id: base.id,
            displayName: SystemAlertSound.displayName(language: language),
            bundleID: base.bundleID,
            processes: base.processes,
            isPlaying: base.isPlaying,
            mainPID: base.mainPID,
            isRegularApp: base.isRegularApp
        )
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func appRow(
        for app: AudioApp,
        fallbackSymbolName: String = "app.fill"
    ) -> some View {
        AppRowContainer(
            appState: appState,
            app: app,
            fallbackSymbolName: fallbackSymbolName
        )
    }
}

private struct AppRowContainer: View {
    @Bindable var appState: AppState
    let app: AudioApp
    var fallbackSymbolName: String = "app.fill"

    var body: some View {
        let rule = appState.ruleModel(for: app.id).rule
        let resolvedIcon = fallbackSymbolName == "app.fill" ? appState.icon(for: app) : nil
        AppRowView(
            app: app,
            rule: rule,
            icon: resolvedIcon,
            fallbackSymbolName: fallbackSymbolName,
            language: appState.preferences.language,
            devices: appState.outputDevices,
            defaultDeviceName: appState.defaultOutputDevice?.name,
            isTargetOffline: appState.offlineAppIDs.contains(app.id),
            errorMessage: appState.sessionErrors[app.id],
            eqPresets: appState.eqPresets,
            activeEQ: appState.eqPreset(for: rule),
            onVolumeChange: { appState.setAppVolume($0, for: app.id) },
            onToggleMute: { appState.toggleAppMute(for: app.id) },
            onOutputChange: { appState.setAppOutput($0, for: app.id) },
            onSelectEQPreset: { appState.selectAppEQPreset($0, for: app.id) },
            onReset: { appState.resetAppRule(for: app.id) },
            onRetry: { appState.retrySession(for: app.id) }
        )
    }
}

private struct FooterActionButton: View {
    let title: String
    let systemImage: String
    var hoverTint: Color = .accentColor
    var rotateIconOnHover: Bool = false
    var helpText: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .rotationEffect(.degrees(rotateIconOnHover && isHovered ? 45 : 0))
                    .offset(x: !rotateIconOnHover && isHovered ? 1.5 : 0)
                Text(title)
            }
            .foregroundStyle(isHovered ? hoverTint : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? hoverTint.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isHovered ? hoverTint.opacity(0.25) : Color.clear, lineWidth: 1)
            )
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: isHovered)
        }
        .buttonStyle(FooterPressStyle())
        .help(helpText)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct FooterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
