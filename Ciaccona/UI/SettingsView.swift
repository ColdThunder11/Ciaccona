import SwiftUI

struct SettingsView: View {
    @Bindable var appState: AppState
    @State private var showResetConfirmation = false

    var body: some View {
        let lang = appState.preferences.language

        Form {
            Section(L10n.tr("settings.section.general", defaultValue: "General", language: lang)) {
                Toggle(
                    L10n.tr("settings.launch_at_login", defaultValue: "Launch at Login", language: lang),
                    isOn: Binding(
                        get: { appState.preferences.launchAtLogin },
                        set: { appState.setLaunchAtLogin($0) }
                    )
                )

                Picker(
                    L10n.tr("settings.language", defaultValue: "Language", language: lang),
                    selection: Binding(
                        get: { appState.preferences.language },
                        set: { appState.setLanguage($0) }
                    )
                ) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(option.displayName(language: lang)).tag(option)
                    }
                }
            }

            Section(L10n.tr("settings.section.audio_routing", defaultValue: "Audio Routing", language: lang)) {
                Toggle(
                    L10n.tr(
                        "settings.show_all_processes",
                        defaultValue: "Show all processes (including system services and menu bar apps)",
                        language: lang
                    ),
                    isOn: Binding(
                        get: { appState.preferences.showAllProcesses },
                        set: { appState.setShowAllProcesses($0) }
                    )
                )

                Toggle(
                    L10n.tr(
                        "settings.pause_idle_sessions",
                        defaultValue: "Pause idle app audio sessions (lower overhead, may cause brief bleed)",
                        language: lang
                    ),
                    isOn: Binding(
                        get: { appState.preferences.pauseIdleSessions },
                        set: { appState.setPauseIdleSessions($0) }
                    )
                )

                Picker(
                    L10n.tr("settings.buffer_size", defaultValue: "Audio Buffer Size", language: lang),
                    selection: Binding(
                        get: { appState.preferences.bufferFrameSize },
                        set: { appState.setBufferFrameSize($0) }
                    )
                ) {
                    ForEach(AudioBufferPreset.allCases) { preset in
                        Text(preset.displayName(language: lang)).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L10n.tr("settings.section.about", defaultValue: "About", language: lang)) {
                LabeledContent(
                    L10n.tr("settings.version", defaultValue: "Version", language: lang),
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                )
                LabeledContent(
                    L10n.tr("settings.developer", defaultValue: "Developer", language: lang),
                    value: "ColdThunder11 and AIs"
                )
            }

            Section {
                HStack {
                    Spacer()
                    Button(
                        L10n.tr("settings.reset_routing", defaultValue: "Restore Default Audio Routing", language: lang),
                        role: .destructive
                    ) {
                        showResetConfirmation = true
                    }
                    .disabled(appState.rules.isEmpty)
                    Spacer()
                }
            } footer: {
                Text("In the sky we're forever wild and free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 390)
        .alert(
            L10n.tr(
                "settings.reset_routing.alert.title",
                defaultValue: "Restore Default Audio Routing?",
                language: lang
            ),
            isPresented: $showResetConfirmation
        ) {
            Button(
                L10n.tr(
                    "settings.reset_routing.alert.confirm",
                    defaultValue: "Restore Defaults",
                    language: lang
                ),
                role: .destructive
            ) {
                appState.resetAllRoutingRules()
            }
            Button(
                L10n.tr("settings.reset_routing.alert.cancel", defaultValue: "Cancel", language: lang),
                role: .cancel
            ) {}
        } message: {
            Text(L10n.tr(
                "settings.reset_routing.alert.message",
                defaultValue: "Volume, mute, and output device rules for all apps and System Alert Sound will be cleared and reset to follow default. App preferences will not be changed.",
                language: lang
            ))
        }
    }
}
