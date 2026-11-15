import CoreAudio
import SwiftUI

struct GlobalDevicePicker: View {
    var label: String = L10n.tr("global.output_device", defaultValue: "Output Device")
    var language: AppLanguage? = nil
    let devices: [AudioDevice]
    let selectedID: AudioObjectID
    let onSelect: (AudioObjectID) -> Void

    var body: some View {
        Picker(label, selection: Binding(
            get: { selectedID },
            set: { onSelect($0) }
        )) {
            if devices.isEmpty {
                Text(L10n.tr("picker.no_output_devices", defaultValue: "No output devices available", language: language))
                    .tag(AudioObjectID(kAudioObjectUnknown))
            } else {
                ForEach(devices) { device in
                    Label(device.name, systemImage: device.systemIconName)
                        .tag(device.id)
                }
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
    }
}

struct AppOutputPicker: View {
    var language: AppLanguage? = nil
    let devices: [AudioDevice]
    let defaultDeviceName: String?
    let currentTarget: OutputTarget
    let onSelect: (OutputTarget) -> Void

    private enum SelectionKey: Hashable {
        case followDefault
        case device(uid: String)
    }

    private var currentKey: SelectionKey {
        switch currentTarget {
        case .followSystemDefault:
            return .followDefault
        case let .device(uid, _):
            return .device(uid: uid)
        }
    }

    private var offlineTarget: (uid: String, name: String)? {
        guard case let .device(uid, name) = currentTarget else { return nil }
        guard !devices.contains(where: { $0.uid == uid }) else { return nil }
        return (uid, name)
    }

    var body: some View {
        Picker("", selection: Binding(
            get: { currentKey },
            set: { key in
                switch key {
                case .followDefault:
                    onSelect(.followSystemDefault)
                case let .device(uid):
                    let name = devices.first(where: { $0.uid == uid })?.name
                        ?? offlineTarget?.name
                        ?? uid
                    onSelect(.device(uid: uid, lastKnownName: name))
                }
            }
        )) {
            if let defaultDeviceName {
                Text(L10n.trFormat(
                    "picker.follow_system_default_with_name",
                    defaultValue: "Follow System Default (%@)",
                    language: language,
                    defaultDeviceName
                ))
                .tag(SelectionKey.followDefault)
            } else {
                Text(L10n.tr(
                    "picker.follow_system_default",
                    defaultValue: "Follow System Default",
                    language: language
                ))
                .tag(SelectionKey.followDefault)
            }

            Divider()

            ForEach(devices) { device in
                Text(device.name)
                    .tag(SelectionKey.device(uid: device.uid))
            }

            if let offline = offlineTarget {
                Divider()
                Text(L10n.trFormat(
                    "picker.device_offline_suffix",
                    defaultValue: "%@ (Offline)",
                    language: language,
                    offline.name
                ))
                    .foregroundStyle(.secondary)
                    .tag(SelectionKey.device(uid: offline.uid))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: 120)
    }
}
