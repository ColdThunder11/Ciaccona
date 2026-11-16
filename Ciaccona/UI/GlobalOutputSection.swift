import AppKit
import CoreAudio
import SwiftUI

struct GlobalOutputSection: View {
    @Bindable var appState: AppState

    var body: some View {
        let lang = appState.preferences.language
        let device = appState.defaultOutputDevice
        let selectedPresetID = device.flatMap { appState.deviceEQs[$0.uid] }

        VStack(alignment: .leading, spacing: 8) {
            GlobalOutputHeader(appState: appState)
            GlobalVolumeControlRow(appState: appState)
            GlobalVolumeHint(appState: appState)
        }
        .contentShape(Rectangle())
        .contextMenu {
            if device != nil {
                EQSelectionMenuItems(
                    language: lang,
                    presets: appState.eqPresets,
                    selectedPresetID: selectedPresetID,
                    onSelectPreset: { appState.selectDefaultDeviceEQPreset($0) }
                )
            }
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
            if let eq = appState.currentDefaultDeviceEQ, eq.isActive {
                EQStatusBadge(presetName: eq.name)
            }
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
        let device = appState.defaultOutputDevice
        let selectedPresetID = device.flatMap { appState.deviceEQs[$0.uid] }
        let activeEQ = appState.currentDefaultDeviceEQ
        let hasActiveEQ = activeEQ?.isActive == true

        HStack(spacing: 6) {
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
                .frame(width: 40, alignment: .trailing)

            GlobalEQMenuButton(
                language: lang,
                presets: appState.eqPresets,
                selectedPresetID: selectedPresetID,
                isActive: hasActiveEQ,
                onSelectPreset: { appState.selectDefaultDeviceEQPreset($0) }
            )
            .disabled(device == nil)
            .help(
                activeEQ.map {
                    L10n.trFormat("global.eq.active_help", defaultValue: "EQ: %@", language: lang, $0.name)
                } ?? L10n.tr("global.eq.select_help", defaultValue: "Select Global EQ", language: lang)
            )

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

private struct GlobalEQMenuButton: View {
    let language: AppLanguage
    let presets: [EQProfile]
    let selectedPresetID: UUID?
    let isActive: Bool
    let onSelectPreset: (UUID?) -> Void

    @State private var coordinator = EQPopupCoordinator()

    var body: some View {
        // Render as a standard borderless Button instead of SwiftUI Menu so its
        // AppKit host matches the 20x20 icon button geometry in AppRowView.
        Button {
            coordinator.showMenu(
                language: language,
                presets: presets,
                selectedPresetID: selectedPresetID,
                onSelectPreset: onSelectPreset
            )
        } label: {
            Image(systemName: "slider.horizontal.3")
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .background(EQPopupAnchorView(coordinator: coordinator))
    }
}

@MainActor
private final class EQPopupCoordinator: NSObject {
    weak var anchorView: NSView?
    private var handlers: [() -> Void] = []

    func showMenu(
        language: AppLanguage,
        presets: [EQProfile],
        selectedPresetID: UUID?,
        onSelectPreset: @escaping (UUID?) -> Void
    ) {
        guard let anchorView else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        handlers.removeAll()

        if presets.isEmpty {
            let emptyItem = NSMenuItem(
                title: L10n.tr(
                    "eq.menu.empty",
                    defaultValue: "No EQ imported (manage in Settings)",
                    language: language
                ),
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            menu.addItem(.sectionHeader(title: L10n.tr("eq.menu.section", defaultValue: "EQ", language: language)))
            addItem(
                to: menu,
                title: L10n.tr("eq.menu.off", defaultValue: "Off", language: language),
                isSelected: selectedPresetID == nil
            ) {
                onSelectPreset(nil)
            }
            for preset in presets {
                let isSelected = selectedPresetID == preset.id
                addItem(to: menu, title: preset.name, isSelected: isSelected) {
                    onSelectPreset(isSelected ? nil : preset.id)
                }
            }
        }

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchorView.bounds.height + 4), in: anchorView)
    }

    private func addItem(
        to menu: NSMenu,
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        let index = handlers.count
        handlers.append(action)
        let item = NSMenuItem(title: title, action: #selector(handleSelection(_:)), keyEquivalent: "")
        item.target = self
        item.tag = index
        item.state = isSelected ? .on : .off
        menu.addItem(item)
    }

    @objc private func handleSelection(_ sender: NSMenuItem) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }
}

private struct EQPopupAnchorView: NSViewRepresentable {
    let coordinator: EQPopupCoordinator

    func makeNSView(context: Context) -> FlippedAnchorView {
        let view = FlippedAnchorView()
        coordinator.anchorView = view
        return view
    }

    func updateNSView(_ nsView: FlippedAnchorView, context: Context) {
        coordinator.anchorView = nsView
    }
}

private final class FlippedAnchorView: NSView {
    override var isFlipped: Bool { true }
}
