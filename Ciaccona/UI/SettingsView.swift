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

            Section(L10n.tr("settings.section.accessibility", defaultValue: "Accessibility", language: lang)) {
                Toggle(
                    L10n.tr(
                        "settings.take_over_media_keys",
                        defaultValue: "Control software volume with keyboard volume keys (for devices without hardware control)",
                        language: lang
                    ),
                    isOn: Binding(
                        get: { appState.preferences.takeOverVolumeMediaKeys },
                        set: { appState.setTakeOverVolumeMediaKeys($0) }
                    )
                )

                if appState.preferences.takeOverVolumeMediaKeys && appState.needsMediaKeyAccessibilityPermission {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(L10n.tr(
                            "settings.take_over_media_keys.permission_hint",
                            defaultValue: "Accessibility permission is required to intercept keyboard volume keys.",
                            language: lang
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Button(L10n.tr(
                            "settings.take_over_media_keys.open_settings",
                            defaultValue: "Open Settings",
                            language: lang
                        )) {
                            appState.openMediaKeyAccessibilitySettings()
                        }
                        .controlSize(.small)
                    }
                }
            }

            Section(L10n.tr("settings.section.eq", defaultValue: "EQ", language: lang)) {
                if appState.eqPresets.isEmpty {
                    Text(L10n.tr(
                        "settings.eq.empty",
                        defaultValue: "No EQ files imported yet",
                        language: lang
                    ))
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.eqPresets) { preset in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.name)
                                    .lineLimit(1)
                                Text(eqSummaryText(for: preset, language: lang))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                appState.deleteEQPreset(id: preset.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.tr("settings.eq.delete", defaultValue: "Delete EQ", language: lang))
                        }
                    }
                }

                HStack {
                    Text(L10n.tr(
                        "settings.eq.hint",
                        defaultValue: "Supports AutoEQ / EqualizerAPO .txt files",
                        language: lang
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("settings.eq.import", defaultValue: "Import EQ...", language: lang)) {
                        appState.importEQPresetsFromPanel()
                    }
                }
            }

            Section {
                LabeledContent(
                    L10n.tr("settings.version", defaultValue: "Version", language: lang),
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                )
                LabeledContent(
                    L10n.tr("settings.developer", defaultValue: "Developer", language: lang),
                    value: "ColdThunder11 and AIs"
                )
            } header: {
                Text(L10n.tr("settings.section.about", defaultValue: "About", language: lang))
            } footer: {
                VStack(spacing: 12) {
                    HStack {
                        Spacer()
                        Button(
                            L10n.tr("settings.reset_routing", defaultValue: "Restore Default Audio Routing", language: lang),
                            role: .destructive
                        ) {
                            showResetConfirmation = true
                        }
                        .font(.body)
                        .disabled(appState.rules.isEmpty)
                    }

                    Text("In the sky we're forever wild and free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 550)
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

    private func eqSummaryText(for preset: EQProfile, language: AppLanguage) -> String {
        let preampStr = String(format: "%+.1f dB", preset.preampDB)
        return L10n.trFormat(
            "settings.eq.summary",
            defaultValue: "%lld bands · Preamp %@",
            language: language,
            preset.activeBandCount,
            preampStr
        )
    }
}
