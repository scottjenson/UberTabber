import AppKit
import ApplicationServices
import Carbon

/// Intercepts Option-Tab system-wide with a CGEvent tap (needs Accessibility).
/// While the switcher is open every key is swallowed and forwarded as a Key;
/// releasing Option commits.
final class HotKey {
    enum Key {
        case tab(reverse: Bool), left, right, up, down, escape, delete, enter
        case character(String)
    }

    var onShow: ((_ reverse: Bool) -> Void)?
    var onKey: ((Key) -> Void)?
    var onCommit: (() -> Void)?

    /// Once you start typing, releasing Option no longer switches; the
    /// switcher stays open (keys still captured) until Return, a click or Esc.
    var sticky = false

    private var active = false
    private var tap: CFMachPort?

    /// Close without committing on release (Esc, a click, Return).
    func dismiss() {
        active = false
        sticky = false
    }

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
        let shift = flags.contains(.maskShift)
        let code = event.getIntegerValueField(.keyboardEventKeycode)

        switch type {
        case .flagsChanged:
            if active && !option && !sticky {
                active = false
                onCommit?()
            }
            return pass
        case .keyDown:
            if !active {
                guard code == kVK_Tab, option, !flags.contains(.maskCommand), !flags.contains(.maskControl) else { return pass }
                active = true
                onShow?(shift)
                return nil
            }
            if let key = key(for: code, shift: shift) { onKey?(key) }
            return nil
        case .keyUp:
            return active || (code == kVK_Tab && option) ? nil : pass
        default:
            return pass
        }
    }

    private func key(for code: Int64, shift: Bool) -> Key? {
        switch Int(code) {
        case kVK_Tab: return .tab(reverse: shift)
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_Escape: return .escape
        case kVK_Delete: return .delete
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        default:
            guard let text = Self.characters(for: CGKeyCode(code), shift: shift),
                  !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
            return .character(text)
        }
    }

    /// The character a key types without Option (the event itself carries the
    /// Option-modified one, e.g. "å" for A).
    private static func characters(for code: CGKeyCode, shift: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!, code,
                           UInt16(kUCKeyActionDown), shift ? UInt32(shiftKey >> 8) : 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        return status == noErr ? String(utf16CodeUnits: chars, count: length) : nil
    }
}
