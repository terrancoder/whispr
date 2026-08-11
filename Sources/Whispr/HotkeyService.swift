import AppKit
import CoreGraphics

/// Global fn-key push-to-talk via a CGEventTap on a dedicated thread.
///
/// Design notes (see PLAN.md §4.1): we listen on flagsChanged for keycode 63
/// (kVK_Function), fire only on state *transitions*, never block the callback,
/// consume nothing except Esc while recording, re-enable on timeout, and tear
/// the tap down cleanly (macOS 26 orphaned-tap regression).
final class HotkeyService {
    var onFnDown: (() -> Void)?
    var onFnUp: (() -> Void)?
    /// Return true to consume the Esc key event.
    var onEscape: (() -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: Thread?
    private var tapRunLoop: CFRunLoop?
    private var fnIsDown = false
    private var watchdog: Timer?

    private static let fnKeyCode: Int64 = 63
    private static let escKeyCode: Int64 = 53

    func startMonitoring() {
        guard tap == nil else { return }
        let thread = Thread { [weak self] in self?.threadMain() }
        thread.name = "whispr.hotkeys"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        // Watchdog: taps get silently disabled (timeout, TCC churn); re-arm.
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
    }

    func stopMonitoring() {
        watchdog?.invalidate()
        watchdog = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let rl = tapRunLoop {
            CFRunLoopRemoveSource(rl, source, .commonModes)
            CFRunLoopStop(rl)
        }
        runLoopSource = nil
        tap = nil
        tapRunLoop = nil
        thread = nil
    }

    private func threadMain() {
        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let service = Unmanaged<HotkeyService>.fromOpaque(refcon!).takeUnretainedValue()
                return service.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            // No Accessibility permission yet. The permissions flow prompts the
            // user; the watchdog-independent retry happens on next launch.
            NSLog("whispr: event tap creation failed (Accessibility not granted?)")
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        self.tapRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.fnKeyCode {
                let isDown = event.flags.contains(.maskSecondaryFn)
                if isDown != fnIsDown {
                    fnIsDown = isDown
                    let cb = isDown ? onFnDown : onFnUp
                    DispatchQueue.main.async { cb?() }
                }
            }
            return Unmanaged.passUnretained(event)

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.escKeyCode, let onEscape {
                var consumed = false
                DispatchQueue.main.sync { consumed = onEscape() }
                if consumed { return nil }
            }
            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}
