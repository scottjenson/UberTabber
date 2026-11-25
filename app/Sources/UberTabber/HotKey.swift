import AppKit
import ApplicationServices

/// Intercepts Option-Tab system-wide with a CGEvent tap (needs Accessibility).
/// While the switcher is open it swallows keys: Tab / Shift-Tab and the arrow
/// keys move, Esc cancels, releasing Option commits.
final class HotKey {
    var onShow: ((_ reverse: Bool) -> Void)?
    var onMove: ((_ delta: Int) -> Void)?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    private var active = false
    private var tap: CFMachPort?

    private enum Key { static let tab: Int64 = 48, escape: Int64 = 53, left: Int64 = 123, right: Int64 = 124 }

    func start() {
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(prompt) {
            installTap()
        } else {
            print("Waiting for Accessibility permission…")
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.installTap()
            }
        }
    }

    private func installTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            Unmanaged<HotKey>.fromOpaque(refcon!).takeUnretainedValue().handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            print("Could not create event tap")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("Option-Tab is active")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        let flags = event.flags
        let option = flags.contains(.maskAlternate)
        let key = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            if active && !option {
                active = false
                onCommit?()
            }
            return pass
        case .keyDown:
            if key == Key.tab && option && !flags.contains(.maskCommand) && !flags.contains(.maskControl) {
                let reverse = flags.contains(.maskShift)
                if active {
                    onMove?(reverse ? -1 : 1)
                } else {
                    active = true
                    onShow?(reverse)
                }
                return nil
            }
            guard active else { return pass }
            switch key {
            case Key.escape:
                active = false
                onCancel?()
            case Key.left: onMove?(-1)
            case Key.right: onMove?(1)
            default: break
            }
            return nil
        case .keyUp:
            return active || (key == Key.tab && option) ? nil : pass
        default:
            return pass
        }
    }
}
