import AppKit
import SwiftUI

/// The "Flow Bar": a non-activating floating pill, always visible, bottom-center
/// by default. Click = hands-free toggle; drag to move (position persists).
/// Never steals focus from the app being dictated into (PLAN.md §4.9).
@MainActor
final class HUDPanelController {
    private let panel: NSPanel
    private static let frameKey = "whispr.hudFrame"

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
        panel.isMovableByWindowBackground = true

        let host = NSHostingView(rootView: FlowBarView(controller: controller))
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host

        restorePosition()

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.savePosition() }
        }
    }

    private func restorePosition() {
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            // Only restore if still on a visible screen.
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                panel.setFrameOrigin(frame.origin)
                return
            }
        }
        defaultPosition()
    }

    private func defaultPosition() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    var isVisible: Bool { panel.isVisible }
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
        .contentShape(Capsule())
        .onTapGesture { controller.hudTapped() }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            Text("whispr")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        case .recording:
            LevelBarsView(level: controller.micLevel, tint: .white)
        case .command:
            HStack(spacing: 8) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.purple)
                LevelBarsView(level: controller.micLevel, tint: .purple)
            }
        case .handsFree:
            HStack(spacing: 8) {
                Image(systemName: "infinity")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.cyan)
                LevelBarsView(level: controller.micLevel, tint: .cyan)
            }
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

/// Wispr-style animated bars driven by mic level.
struct LevelBarsView: View {
    var level: Float
    var tint: Color = .white
    private let barCount = 24

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule()
                    .fill(tint)
                    .frame(width: 3, height: height(for: i))
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func height(for index: Int) -> CGFloat {
        let center = Double(barCount - 1) / 2
        let distance = abs(Double(index) - center) / center
        let envelope = 1.0 - 0.7 * distance
        let jitter = 0.6 + 0.4 * sin(Double(index) * 1.7 + Double(level) * 12)
        let h = 4 + CGFloat(Double(level) * 22 * envelope * jitter)
        return max(4, min(26, h))
    }
}
