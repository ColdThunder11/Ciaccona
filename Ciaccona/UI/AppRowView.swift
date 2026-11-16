import AppKit
import SwiftUI

struct AppRowView: View {
    let app: AudioApp
    let rule: AppRule
    let icon: NSImage?
    var fallbackSymbolName: String = "app.fill"
    var language: AppLanguage? = nil
    let devices: [AudioDevice]
    let defaultDeviceName: String?
    let isTargetOffline: Bool
    let errorMessage: String?

    let eqPresets: [EQProfile]
    let activeEQ: EQProfile?

    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void
    let onOutputChange: (OutputTarget) -> Void
    let onSelectEQPreset: (UUID?) -> Void
    let onReset: () -> Void
    let onRetry: () -> Void

    @State private var isBoostMode: Bool

    init(
        app: AudioApp,
        rule: AppRule,
        icon: NSImage?,
        fallbackSymbolName: String = "app.fill",
        language: AppLanguage? = nil,
        devices: [AudioDevice],
        defaultDeviceName: String?,
        isTargetOffline: Bool,
        errorMessage: String?,
        eqPresets: [EQProfile],
        activeEQ: EQProfile?,
        onVolumeChange: @escaping (Float) -> Void,
        onToggleMute: @escaping () -> Void,
        onOutputChange: @escaping (OutputTarget) -> Void,
        onSelectEQPreset: @escaping (UUID?) -> Void,
        onReset: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.app = app
        self.rule = rule
        self.icon = icon
        self.fallbackSymbolName = fallbackSymbolName
        self.language = language
        self.devices = devices
        self.defaultDeviceName = defaultDeviceName
        self.isTargetOffline = isTargetOffline
        self.errorMessage = errorMessage
        self.eqPresets = eqPresets
        self.activeEQ = activeEQ
        self.onVolumeChange = onVolumeChange
        self.onToggleMute = onToggleMute
        self.onOutputChange = onOutputChange
        self.onSelectEQPreset = onSelectEQPreset
        self.onReset = onReset
        self.onRetry = onRetry
        self._isBoostMode = State(initialValue: rule.volume > 1.001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                appIconView
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(app.displayName)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        if app.isPlaying {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                        if let activeEQ, activeEQ.isActive {
                            EQStatusBadge(presetName: activeEQ.name)
                        }
                        if isTargetOffline {
                            Text(L10n.tr("row.status.offline", defaultValue: "Offline", language: language))
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if let errorMessage {
                            Button {
                                onRetry()
                            } label: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help(L10n.trFormat(
                                "row.error.help",
                                defaultValue: "Session failed: %@\nClick to retry",
                                language: language,
                                errorMessage
                            ))
                        }
                    }
                }
                Spacer(minLength: 4)
                AppOutputPicker(
                    language: language,
                    devices: devices,
                    defaultDeviceName: defaultDeviceName,
                    currentTarget: rule.output,
                    onSelect: onOutputChange
                )
            }

            HStack(spacing: 6) {
                Slider(
                    value: Binding(
                        get: {
                            let maxLimit: Float = isBoostMode ? 2.0 : 1.0
                            return Double(max(0.0, min(maxLimit, rule.volume)))
                        },
                        set: { onVolumeChange(VolumeLevel.quantize(Float($0), max: 2.0)) }
                    ),
                    in: 0.0...(isBoostMode ? 2.0 : 1.0)
                )
                .tint(rule.volume > 1.001 ? .orange : .accentColor)

                Text("\(VolumeLevel.percent(rule.volume, max: 2.0))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(rule.volume > 1.001 ? .orange : .secondary)
                    .frame(width: 40, alignment: .trailing)

                Button {
                    toggleBoostMode()
                } label: {
                    Image(systemName: isBoostMode ? "arrow.up.circle.fill" : "arrow.up.circle")
                        .foregroundStyle(isBoostMode ? Color.orange : Color.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help(
                    isBoostMode
                        ? L10n.tr("row.boost.disable", defaultValue: "Disable volume boost (0%–100%)", language: language)
                        : L10n.tr("row.boost.enable", defaultValue: "Enable volume boost (0%–200%)", language: language)
                )

                Button(action: onToggleMute) {
                    Image(systemName: rule.muted ? "speaker.slash.fill" : "speaker.wave.2")
                        .foregroundStyle(rule.muted ? Color.red : Color.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help(
                    rule.muted
                        ? L10n.tr("row.unmute", defaultValue: "Unmute", language: language)
                        : L10n.tr("row.mute", defaultValue: "Mute", language: language)
                )
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onChange(of: rule.volume) { oldValue, newValue in
            if newValue > 1.001 {
                isBoostMode = true
            } else if oldValue > 1.001 && rule.isDefault {
                isBoostMode = false
            }
        }
        .contextMenu {
            EQSelectionMenuItems(
                language: language,
                presets: eqPresets,
                selectedPresetID: rule.eqPresetID,
                onSelectPreset: onSelectEQPreset
            )
            Divider()
            Button(L10n.tr("row.action.reset", defaultValue: "Reset to Default", language: language)) {
                isBoostMode = false
                onReset()
            }
            .disabled(rule.isDefault && !isBoostMode)
        }
    }

    private func toggleBoostMode() {
        if isBoostMode {
            isBoostMode = false
            if rule.volume > 1.001 {
                onVolumeChange(1.0)
            }
        } else {
            isBoostMode = true
        }
    }

    @ViewBuilder
    private var appIconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: fallbackSymbolName)
                .font(.system(size: 14))
                .frame(width: 20, height: 20)
                .foregroundStyle(.secondary)
        }
    }
}

struct EQSelectionMenuItems: View {
    let language: AppLanguage?
    let presets: [EQProfile]
    let selectedPresetID: UUID?
    let onSelectPreset: (UUID?) -> Void

    var body: some View {
        if presets.isEmpty {
            Button(L10n.tr(
                "eq.menu.empty",
                defaultValue: "No EQ imported (manage in Settings)",
                language: language
            )) {}
            .disabled(true)
        } else {
            Section(L10n.tr("eq.menu.section", defaultValue: "EQ", language: language)) {
                Button {
                    onSelectPreset(nil)
                } label: {
                    if selectedPresetID == nil {
                        Label(
                            L10n.tr("eq.menu.off", defaultValue: "Off", language: language),
                            systemImage: "checkmark"
                        )
                    } else {
                        Text(L10n.tr("eq.menu.off", defaultValue: "Off", language: language))
                    }
                }
                ForEach(presets) { preset in
                    Button {
                        onSelectPreset(selectedPresetID == preset.id ? nil : preset.id)
                    } label: {
                        if selectedPresetID == preset.id {
                            Label(preset.name, systemImage: "checkmark")
                        } else {
                            Text(preset.name)
                        }
                    }
                }
            }
        }
    }
}

struct EQStatusBadge: View {
    let presetName: String

    var body: some View {
        Text("EQ")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.accentColor.opacity(0.14), in: Capsule())
            .help(presetName)
    }
}
