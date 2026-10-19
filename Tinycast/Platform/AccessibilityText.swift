import AppKit
// `@preconcurrency` downgrades AX diagnostics: the attribute keys are constant C globals.
@preconcurrency import ApplicationServices

/// Always against a named process: the system-wide focus answers with ours.
enum AccessibilityText {
    /// Generous for a responsive app, short enough that a wedged one can't stall the main actor.
    private static let timeout: Float = 1

    /// The two have different fixes; collapsing them tells a reader to select what they selected.
    enum Selection: Equatable {
        case text(String)
        case noFocusedElement
        case empty
    }

    static func focusedElement(in app: NSRunningApplication) -> AXUIElement? {
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Per element and never inherited, so the focused element needs its own against a hang.
        AXUIElementSetMessagingTimeout(application, timeout)
        activateManualAccessibility(of: application)
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        {
            let element = focusedValue as! AXUIElement
            AXUIElementSetMessagingTimeout(element, timeout)
            return element
        }

        // When the app is in the background (displaced by Tinycast), query focused / main window
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var windowValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, attr as CFString, &windowValue) == .success,
               let windowValue,
               CFGetTypeID(windowValue) == AXUIElementGetTypeID()
            {
                let window = windowValue as! AXUIElement
                AXUIElementSetMessagingTimeout(window, timeout)
                var windowFocused: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    window,
                    kAXFocusedUIElementAttribute as CFString,
                    &windowFocused) == .success,
                   let windowFocused,
                   CFGetTypeID(windowFocused) == AXUIElementGetTypeID()
                {
                    let element = windowFocused as! AXUIElement
                    AXUIElementSetMessagingTimeout(element, timeout)
                    return element
                }
                return window
            }
        }

        // Fallback to the first window in the windows list
        var windowsValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windowsValue) == .success,
           let windows = windowsValue as? [AnyObject]
        {
            for winObj in windows where CFGetTypeID(winObj) == AXUIElementGetTypeID() {
                let window = winObj as! AXUIElement
                AXUIElementSetMessagingTimeout(window, timeout)
                var windowFocused: CFTypeRef?
                if AXUIElementCopyAttributeValue(
                    window,
                    kAXFocusedUIElementAttribute as CFString,
                    &windowFocused) == .success,
                   let windowFocused,
                   CFGetTypeID(windowFocused) == AXUIElementGetTypeID()
                {
                    let element = windowFocused as! AXUIElement
                    AXUIElementSetMessagingTimeout(element, timeout)
                    return element
                }
                return window
            }
        }

        return nil
    }

    static func read(in app: NSRunningApplication) -> Selection {
        // 1. Check focused element if available
        if let element = focusedElement(in: app) {
            if let text = readDirectSelection(from: element), !text.isEmpty {
                return .text(text)
            }
        }

        // 2. Search candidate windows and their descendants
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, timeout)
        activateManualAccessibility(of: application)

        var candidateWindows: [AXUIElement] = []
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, attr as CFString, &winRef) == .success,
               let win = winRef, CFGetTypeID(win) == AXUIElementGetTypeID() {
                candidateWindows.append(win as! AXUIElement)
            }
        }

        var winListRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &winListRef) == .success,
           let winList = winListRef as? [AnyObject] {
            for winObj in winList where CFGetTypeID(winObj) == AXUIElementGetTypeID() {
                let win = winObj as! AXUIElement
                if !candidateWindows.contains(where: { CFEqual($0, win) }) {
                    candidateWindows.append(win)
                }
            }
        }

        for window in candidateWindows {
            AXUIElementSetMessagingTimeout(window, timeout)
            var visited = 0
            if let text = findSelectionInDescendants(element: window, depth: 0, visitedCount: &visited), !text.isEmpty {
                return .text(text)
            }
        }

        return focusedElement(in: app) == nil ? .noFocusedElement : .empty
    }

    /// A narrower question, for callers that can act on the text but not on why there is none.
    static func selection(in app: NSRunningApplication) -> String? {
        guard case .text(let text) = read(in: app) else { return nil }
        return text
    }

    private static func readDirectSelection(from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &value)
        if status == .success, let text = value as? String, !text.isEmpty { return text }
        if let web = webSelection(in: element), !web.isEmpty { return web }
        return nil
    }

    private static func findSelectionInDescendants(
        element: AXUIElement, depth: Int, visitedCount: inout Int
    ) -> String? {
        if depth > 6 || visitedCount > 50 { return nil }
        visitedCount += 1

        if let text = readDirectSelection(from: element), !text.isEmpty {
            return text
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AnyObject]
        else { return nil }

        for child in children where CFGetTypeID(child) == AXUIElementGetTypeID() {
            let childElem = child as! AXUIElement
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(childElem, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? ""
            if nonTextRoles.contains(role) { continue }
            if let found = findSelectionInDescendants(element: childElem, depth: depth + 1, visitedCount: &visitedCount) {
                return found
            }
        }
        return nil
    }

    private static let nonTextRoles: Set<String> = [
        "AXButton", "AXImage", "AXScrollBar", "AXCheckBox", "AXMenuButton",
        "AXPopUpButton", "AXColorWell", "AXSlider", "AXProgressIndicator",
        "AXToolbar"
    ]

    /// Chromium builds its tree only once asked, so Chrome and Electron answer nothing until this.
    private static func activateManualAccessibility(of application: AXUIElement) {
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Browsers have no `AXSelectedText`: web selection exists only as an opaque marker range.
    private static func webSelection(in element: AXUIElement) -> String? {
        var range: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element,
                kAXSelectedTextMarkerRangeAttribute as CFString,
                &range) == .success,
            let range,
            CFGetTypeID(range) == AXTextMarkerRangeGetTypeID()
        else { return nil }

        var value: CFTypeRef?
        guard
            AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
                range,
                &value) == .success
        else { return nil }
        return value as? String
    }
}
