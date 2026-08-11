import AppKit
import SwiftUI

/// The "Flow Bar": a non-activating floating pill at the bottom-center of the
/// screen. Never steals focus from the app being dictated into (PLAN.md §4.9).
@MainActor
final class HUDPanelController {
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init(controller: AppController) {
        let size = NSSize(width: 200, height: 44)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let host = NSHostingView(rootView: FlowBarView(controller: controller))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        position()
    }

    private func position() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 24
        )
        panel.setFrameOrigin(origin)
    }

    func show() {
        hideTask?.cancel()
        hideTask = nil
        position()
        panel.orderFrontRegardless()
    }

    func hideSoon(after seconds: Double = 0.6) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }
}

struct FlowBarView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        ZStack {
            Capsule()
                .fill(.black.opacity(0.82))
            content
                .padding(.horizontal, 16)
        }
        .frame(width: 200, height: 40)
        .padding(2)
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            Text("whispr")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        case .recording:
            LevelBarsView(level: controller.micLevel)
        case .processing:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Transcribing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        case .error(let message):
            Text(message)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }
}

/// Wispr-style animated white bars driven by mic level.
struct LevelBarsView: View {
    var level: Float
    private let barCount = 24

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: height(for: i))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        // Center-weighted bars with per-bar variation so the pill looks alive.
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        let envelope = 1.0 - 0.7 * distance
        let jitter = 0.6 + 0.4 * sin(Double(index) * 1.7 + Double(level) * 12)
        let h = 4 + CGFloat(Double(level) * 22 * envelope * jitter)
        return max(4, min(26, h))
    }
}
