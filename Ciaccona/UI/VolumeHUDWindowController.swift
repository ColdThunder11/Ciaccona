import AppKit
import SwiftUI

@Observable
@MainActor
private final class VolumeHUDModel {
    var volume: Float = 1.0
    var isMuted: Bool = false
    var deviceName: String = ""

    var symbolName: String {
        if isMuted || volume <= 0.001 {
            return "speaker.slash.fill"
        } else if volume < 0.34 {
            return "speaker.wave.1.fill"
        } else if volume < 0.67 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}

private struct VolumeHUDView: View {
    var model: VolumeHUDModel
    private let segments = 16

    var body: some View {
        let activeLevel = model.isMuted ? Float(0) : model.volume
        let filledSegments = Int((activeLevel * Float(segments)).rounded())

        VStack(spacing: 12) {
            Image(systemName: model.symbolName)
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(model.isMuted ? Color.secondary : Color.primary)
                .frame(height: 54)

            if !model.deviceName.isEmpty {
                Text(model.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 3) {
                ForEach(0..<segments, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(index < filledSegments ? Color.primary : Color.primary.opacity(0.18))
                        .frame(height: 6)
                }
            }
            .padding(.horizontal, 4)

            Text("\(VolumeLevel.percent(activeLevel, max: 1.0))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(width: 196)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}

/// Lightweight, click-through floating volume HUD shown when media keys control software volume.
@MainActor
final class VolumeHUDWindowController {
    private let model = VolumeHUDModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var hideGeneration: UInt64 = 0

    func show(volume: Float, isMuted: Bool, deviceName: String) {
        model.volume = volume
        model.isMuted = isMuted
        model.deviceName = deviceName

        let panel = ensurePanel()
        position(panel)
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()

        hideGeneration &+= 1
        let expectedGeneration = hideGeneration
        hideTask?.cancel()
        hideTask = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled, let self, let panel, self.hideGeneration == expectedGeneration else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().alphaValue = 0.0
            } completionHandler: {
                MainActor.assumeIsolated {
                    guard self.hideGeneration == expectedGeneration else { return }
                    panel.orderOut(nil)
                    self.hideTask = nil
                }
            }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel {
            return panel
        }

        let hostingView = NSHostingView(rootView: VolumeHUDView(model: model))
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: fittingSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = hostingView
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        if let hostingView = panel.contentView {
            let size = hostingView.fittingSize
            if size != panel.frame.size {
                panel.setContentSize(size)
            }
        }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + max(88, frame.height * 0.14)
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }
}
