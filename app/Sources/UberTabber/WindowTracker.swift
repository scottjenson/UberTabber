import AppKit
import ApplicationServices

// Private but long-stable API (used by AltTab and others) mapping an
// Accessibility window element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let element: AXUIElement
    var title: String
}

/// Tracks the standard windows of every observed app through Accessibility
/// notifications: which exist, their titles, and which one gets focus.
final class WindowTracker {
    private(set) var windows: [CGWindowID: WindowInfo] = [:]
    private var observers: [pid_t: AXObserver] = [:]

    var onFocus: ((WindowInfo) -> Void)?
    var onDestroy: ((CGWindowID) -> Void)?
    var onChange: (() -> Void)?

    private static let callback: AXObserverCallback = { _, element, notification, refcon in
        guard let refcon else { return }
        Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue().handle(element, notification as String)
    }

    private var refcon: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, Self.callback, &created) == .success, let observer = created else { return }
        let appElement = AXUIElementCreateApplication(pid)
        for name in [kAXFocusedWindowChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(observer, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        for window in attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            add(window, pid: pid)
        }
    }

    func forget(_ pid: pid_t) {
        observers[pid] = nil
        windows = windows.filter { $0.value.pid != pid }
    }

    func focusedWindow(of pid: pid_t) -> WindowInfo? {
        guard let value = attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return add(value as! AXUIElement, pid: pid)
    }

    func count(of pid: pid_t) -> Int {
        windows.values.filter { $0.pid == pid }.count
    }

    func raise(_ id: CGWindowID) {
        guard let window = windows[id] else { return }
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
    }

    private func handle(_ element: AXUIElement, _ notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        switch notification {
        case kAXWindowCreatedNotification:
            if add(element, pid: pid) != nil { onChange?() }
        case kAXFocusedWindowChangedNotification:
            if let info = add(element, pid: pid) { onFocus?(info) }
        case kAXTitleChangedNotification:
            if let id = windowID(element), windows[id] != nil {
                windows[id]?.title = title(element)
                onChange?()
            }
        case kAXUIElementDestroyedNotification:
            // A destroyed element can no longer report its ID; match it instead.
            if let id = windows.first(where: { CFEqual($0.value.element, element) })?.key {
                windows[id] = nil
                onDestroy?(id)
            }
        default:
            break
        }
    }

    /// Registers a window if it's a standard one (not a panel, sheet or
    /// palette) and returns it with a fresh title.
    @discardableResult
    private func add(_ element: AXUIElement, pid: pid_t) -> WindowInfo? {
        guard let id = windowID(element),
              attribute(element, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole else { return nil }
        if windows[id] == nil, let observer = observers[pid] {
            for name in [kAXUIElementDestroyedNotification, kAXTitleChangedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, refcon)
            }
        }
        let info = WindowInfo(id: id, pid: pid, element: element, title: title(element))
        windows[id] = info
        return info
    }

    private func windowID(_ element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    private func title(_ element: AXUIElement) -> String {
        attribute(element, kAXTitleAttribute) as? String ?? ""
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
