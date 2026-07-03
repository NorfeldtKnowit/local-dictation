import AppKit
import CoreGraphics

/// Listens for the Right Option key (kVK_RightOption = 61) and reports
/// press / release transitions. Push-to-talk semantics: caller starts
/// recording on press and stops on release.
///
/// Implementation note: macOS reports modifier changes via flagsChanged
/// events. We read the keyboardEventKeycode field to distinguish left vs.
/// right Option (left = 58, right = 61), and the alternate bit in the
/// event flags to learn whether the change was a press or a release.
final class HotkeyMonitor {
    /// Press/release transitions come from the pure `HotkeyStateMachine`; the
    /// typealias keeps `HotkeyMonitor.Transition` as the callers' spelling.
    typealias Transition = HotkeyStateMachine.Transition

    private let onTransition: (Transition) -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// The "is this a press or a release, and did the tap die mid-hold?"
    /// bookkeeping lives in the pure, unit-tested state machine; this class
    /// keeps only the CGEventTap plumbing around it.
    private var keyState = HotkeyStateMachine()
    private var recreateScheduled = false

    private static let kVKRightOption: Int64 = 61
    private static let verbose: Bool = ProcessInfo.processInfo.environment["LOCAL_DICTATION_VERBOSE"] == "1"

    init(onTransition: @escaping (Transition) -> Void) {
        self.onTransition = onTransition
    }

    /// Installs the event tap. Returns false if Accessibility / Input
    /// Monitoring permission has not been granted yet — the caller
    /// should prompt the user and call `start()` again afterwards.
    @discardableResult
    func start() -> Bool {
        if eventTap != nil { return true }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            Log.error("CGEvent.tapCreate returned nil — likely missing Accessibility/Input Monitoring permission", "hotkey")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        keyState = HotkeyStateMachine()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.warn("event tap disabled (\(type.rawValue)) — re-enabling", "hotkey")
            // Fail-safe: if we believed the key was held, the matching release
            // event was almost certainly swallowed while the tap was dead. Emit
            // a synthetic release so recording can't get stuck on, and reset to
            // a known-idle state so the next real press is detected.
            if let transition = keyState.handleTapDisabledWhileHeld() {
                Log.info("tap disabled while key held — synthesizing release", "hotkey")
                dispatch(transition)
            }
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            scheduleRecreateIfNeeded()
            return
        }
        guard type == .flagsChanged else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if Self.verbose {
            Log.debug("flagsChanged keyCode=\(keyCode) flags=\(String(event.flags.rawValue, radix: 16))", "hotkey")
        }
        guard keyCode == Self.kVKRightOption else { return }

        let flags = event.flags
        let optionHeld = flags.contains(.maskAlternate)

        // The press/release edge decision is delegated to the pure state machine;
        // a duplicate reading (no edge) returns nil and is dropped here exactly
        // as the old inline `isDown` checks did.
        guard let transition = keyState.handleFlagsChanged(optionHeld: optionHeld) else { return }
        switch transition {
        case .pressed:  Log.info("right-option pressed", "hotkey")
        case .released: Log.info("right-option released", "hotkey")
        }
        dispatch(transition)
    }

    /// A `.listenOnly` head-insert tap on recent macOS gets disabled repeatedly
    /// under long uptime; merely re-enabling sometimes leaves it deaf. Rebuild
    /// the tap from scratch shortly after a disable. Debounced so a burst of
    /// disable events coalesces into a single recreate.
    private func scheduleRecreateIfNeeded() {
        guard !recreateScheduled else { return }
        recreateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.recreateScheduled = false
            self.stop()
            let ok = self.start()
            Log.info("event tap recreated after disable (ok=\(ok))", "hotkey")
        }
    }

    private func dispatch(_ t: Transition) {
        if Thread.isMainThread {
            onTransition(t)
        } else {
            DispatchQueue.main.async { [onTransition] in onTransition(t) }
        }
    }
}
