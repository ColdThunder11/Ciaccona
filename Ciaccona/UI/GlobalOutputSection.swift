import CoreAudio
import SwiftUI

struct GlobalOutputSection: View {
    @Bindable var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlobalOutputHeader(appState: appState)
            GlobalVolumeControlRow(appState: appState)
            GlobalVolumeHint(appState: appState)
        }
    }
}

private struct GlobalOutputHeader: View {
    @Bindable var appState: AppState

    var body: some View {
        let lang = appState.preferences.language
        HStack(spacing: 8) {
            Image(systemName: appState.menuBarSymbolName)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(L10n.tr("global.output_device", defaultValue: "Output Device", language: lang))
                .font(.headline)
            Spacer(minLength: 4)
            GlobalDevicePicker(
                label: L10n.tr("global.output_device", defaultValue: "Output Device", language: lang),
                language: lang,
                devices: appState.outputDevices,
                selectedID: appState.defaultOutputDeviceID,
                onSelect: { appState.selectDefaultOutputDevice($0) }
            )
            .frame(maxWidth: 210)
        }
    }
}

private struct GlobalVolumeControlRow: View {
    @Bindable var appState: AppState

    var body: some View {
        let lang = appState.preferences.language
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { Double(appState.globalVolume) },
                    set: { appState.setGlobalVolume(Float($0)) }
                ),
                in: 0.0...1.0
            )
            .disabled(!appState.canSetGlobalVolume)

            Text("\(VolumeLevel.percent(appState.globalVolume, max: 1.0))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(appState.canSetGlobalVolume ? .primary : .secondary)
                .frame(width: 38, alignment: .trailing)

            Button {
                appState.toggleGlobalMute()
            } label: {
                Image(systemName: appState.isGlobalMuted ? "speaker.slash.fill" : "speaker.wave.2")
                    .foregroundStyle(appState.isGlobalMuted ? Color.red : Color.secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .disabled(!appState.canMuteGlobal)
            .help(
                appState.isGlobalMuted
                    ? L10n.tr("row.unmute", defaultValue: "Unmute", language: lang)
                    : L10n.tr("row.mute", defaultValue: "Mute", language: lang)
            )
        }
    }
}

private struct GlobalVolumeHint: View {
    @Bindable var appState: AppState

    var body: some View {
        let lang = appState.preferences.language
        if appState.isUsingSoftwareGlobalVolume && appState.defaultOutputDevice != nil {
            Text(L10n.tr(
                "global.software_volume_hint",
                defaultValue: "Software volume enabled (device lacks hardware control)",
                language: lang
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if !appState.canSetGlobalVolume && appState.defaultOutputDevice != nil {
            Text(L10n.tr(
                "global.external_volume_hint",
                defaultValue: "Volume is controlled externally for this device",
                language: lang
            ))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
