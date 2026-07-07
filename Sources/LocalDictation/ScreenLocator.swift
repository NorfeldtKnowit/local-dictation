import AppKit

/// Which screen is the user actually working on? Shared by the floating HUDs
/// (review overlay, level meter). NSScreen.main is useless for this accessory
/// app (no key window → it falls back to screens[0]); the focused window of
/// the frontmost app is the truth, with the mouse's screen and screens[0] as
/// graceful fallbacks.
enum ScreenLocator {
    static func activeScreen() -> NSScreen? {
        if let frame = axFocusedWindowFrame(),
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(frame) }) {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        return NSScreen.screens.first
    }

    /// Frontmost app's AX focused-window frame in AppKit (bottom-left origin)
    /// global coordinates, or nil when AX can't say (no window, AX denied).
    private static func axFocusedWindowFrame() -> NSRect? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // AX attribute reads are synchronous IPC into the target app; a hung
        // target would otherwise block our main thread for the ~6 s default
        // timeout (freezing the hotkey tap). Fail fast into the fallbacks.
        AXUIElementSetMessagingTimeout(element, 0.25)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString,
                                            &windowRef) == .success,
              let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let axWindow = unsafeDowncast(window, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(axWindow, 0.25)

        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString,
                                            &positionRef) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString,
                                            &sizeRef) == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size) else { return nil }

        // AX reports top-left-origin global coordinates; AppKit's global space
        // is bottom-left-origin relative to the primary screen (screens[0]).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: position.x,
                      y: primaryHeight - position.y - size.height,
                      width: size.width,
                      height: size.height)
    }
}
