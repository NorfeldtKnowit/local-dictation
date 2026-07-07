import AppKit

/// A panel that must NEVER take key or main status: keyboard routing (and the
/// caret) stays with the app the user is dictating into. Selection is mouse-
/// only — `.nonactivatingPanel` delivers clicks without activating this app.
/// Do not "fix" anything here with `NSApp.activate`; that would deactivate the
/// target app, move first responder, and break the paste (same spirit as the
/// frozen AudioRecorder: the no-activation property is the whole feature).
private final class ReviewOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// An NSButton that responds to the first click even though its window is
/// never key (every click on this panel is a "first mouse").
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One clickable candidate row: a small badge (RAW / TERSE) plus up to three
/// lines of transcript. Highlights on hover, fires `onClick` on mouse-up.
private final class CandidateRow: NSView {
    private let onClick: () -> Void

    init(badge: String, text: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        let badgeLabel = NSTextField(labelWithString: badge)
        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .secondaryLabelColor

        let textLabel = NSTextField(wrappingLabelWithString: text)
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .labelColor
        textLabel.maximumNumberOfLines = 3
        // NOT lineBreakMode = .byTruncatingTail: any truncating mode flips the
        // cell to single-line layout and maximumNumberOfLines goes inert
        // (verified empirically — the rows rendered exactly one line). This
        // keeps word-wrap and only ellipsizes the third line on overflow.
        textLabel.cell?.truncatesLastVisibleLine = true
        textLabel.preferredMaxLayoutWidth = 360
        textLabel.isSelectable = false

        let stack = NSStackView(views: [badgeLabel, textLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        // Semantic color so the highlight tracks dark/light automatically.
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor
            .withAlphaComponent(0.35).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick()
        }
    }
}

/// Tracks pointer presence over the whole panel content so the coordinator can
/// pause the auto-insert deadman while the user is reading.
private final class HoverTrackingView: NSVisualEffectView {
    var onHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}

/// The AppKit half of "Review Before Paste": a small floating HUD near the top
/// of the screen the user is working on, offering the raw transcript and the
/// terse rewrite as clickable rows plus a countdown to the raw auto-insert.
/// Pure presentation — every decision (including timeouts) lives in
/// `ReviewQueueLogic`, driven by `ReviewCoordinator`.
final class ReviewOverlayController {
    /// Fired on the main thread when the user clicks a row / the dismiss mark,
    /// carrying the ID of the request the click was VISUALLY aimed at.
    var onChoice: ((UInt64, ReviewQueueLogic.Choice) -> Void)?

    /// Ground truth for the deadman's pause-while-reading check: geometry, not
    /// tracking-area bookkeeping (which misses a pointer already inside the
    /// panel when it (re)appears — no crossing, no mouseEntered).
    var pointerIsOverPanel: Bool {
        guard let panel, panel.isVisible else { return false }
        return NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)
    }

    /// Display-only hover mirror (drives the countdown label wording).
    private var isHovering = false

    private var panel: ReviewOverlayPanel?
    private var countdownLabel: NSTextField?
    private var countdownTimer: Timer?
    /// Display-only deadline mirror; the AUTHORITATIVE timeout is the
    /// coordinator's scheduled deadman event, which no UI state can cancel.
    private var displayDeadline = Date.distantFuture
    /// The request currently rendered, and when it appeared. Clicks within
    /// `clickShield` of a (re)show are dropped: a click already in flight when
    /// the queue auto-advanced must not decide the next request sight-unseen.
    private var shownID: UInt64?
    private var shownAt = Date.distantPast

    private static let panelWidth: CGFloat = 420
    private static let clickShield: TimeInterval = 0.4

    func show(_ request: ReviewRequest, timeout: TimeInterval) {
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        shownID = request.id
        shownAt = Date()
        panel.contentView = buildContent(request)

        let size = panel.contentView!.fittingSize
        let screen = Self.targetScreen()
        // visibleFrame (not frame): stays clear of the menu bar and the notch
        // housing on notched MacBooks, and adapts when the menu bar auto-hides.
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - size.height - 12)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        // orderFrontRegardless, never any activation: see ReviewOverlayPanel.
        panel.orderFrontRegardless()

        // Seed the display hover state from geometry: a pointer already parked
        // inside the fresh panel produces no mouseEntered crossing.
        isHovering = pointerIsOverPanel
        resetCountdown(timeout)
        startCountdownTimer()
    }

    func hide() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        isHovering = false
        shownID = nil
        panel?.orderOut(nil)
    }

    /// The coordinator re-armed the deadman (hover pause); mirror it visually.
    func resetCountdown(_ delay: TimeInterval) {
        displayDeadline = Date().addingTimeInterval(delay)
        refreshCountdown()
    }

    // MARK: - Panel construction

    private static func makePanel() -> ReviewOverlayPanel {
        let panel = ReviewOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        // .fullScreenAuxiliary is load-bearing: without it the panel silently
        // stays on the desktop space while the user dictates into a full-screen
        // app, and the timeout auto-inserts text they never saw.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        // NSPanel defaults hidesOnDeactivate to TRUE; this app is an accessory
        // that is never active, so the default would hide the panel instantly.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Do NOT set isFloatingPanel: its setter assigns the window level as a
        // side effect and silently demotes the deliberate .statusBar above
        // back to .floating (verified empirically).
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .utilityWindow
        return panel
    }

    private func buildContent(_ request: ReviewRequest) -> NSView {
        let effect = HoverTrackingView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        // Mandatory: this window is never key, and the default
        // .followsWindowActiveState would draw the flat inactive fallback.
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        effect.onHoverChanged = { [weak self] hovering in
            self?.isHovering = hovering
            self?.refreshCountdown()
        }

        // Delivery-neutral wording: with Copy Instead of Paste on, the chosen
        // text is staged on the clipboard rather than inserted.
        let title = NSTextField(labelWithString: "Which version?")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let dismiss = FirstMouseButton()
        dismiss.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                accessibilityDescription: "Dismiss (insert nothing)")
        dismiss.isBordered = false
        dismiss.contentTintColor = .tertiaryLabelColor
        dismiss.target = self
        dismiss.action = #selector(dismissClicked)

        let header = NSStackView(views: [title, NSView(), dismiss])
        header.orientation = .horizontal

        let id = request.id
        let rawRow = CandidateRow(badge: "RAW", text: request.raw) { [weak self] in
            self?.fireChoice(id: id, .raw)
        }
        let polishedRow = CandidateRow(badge: "TERSE", text: request.polished) { [weak self] in
            self?.fireChoice(id: id, .polished)
        }

        let countdown = NSTextField(labelWithString: "")
        countdown.font = .systemFont(ofSize: 10)
        countdown.textColor = .tertiaryLabelColor
        countdownLabel = countdown

        let stack = NSStackView(views: [header, rawRow, polishedRow, countdown])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            effect.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            rawRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            polishedRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        return effect
    }

    @objc private func dismissClicked() {
        guard let id = shownID else { return }
        fireChoice(id: id, .dismiss)
    }

    /// Click funnel: drops choices landing within `clickShield` of a (re)show —
    /// a human can't read a fresh overlay in under 400 ms, so such a click was
    /// aimed at whatever was on screen BEFORE the queue advanced.
    private func fireChoice(id: UInt64, _ choice: ReviewQueueLogic.Choice) {
        guard Date().timeIntervalSince(shownAt) >= Self.clickShield else { return }
        onChoice?(id, choice)
    }

    // MARK: - Countdown display

    private func startCountdownTimer() {
        countdownTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshCountdown()
        }
        // .common so it keeps ticking while the status-item menu is open
        // (NSEventTrackingRunLoopMode stalls .default-mode timers).
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func refreshCountdown() {
        guard let label = countdownLabel else { return }
        if isHovering {
            label.stringValue = "Paused — click a version, or ✕ for nothing"
            return
        }
        let remaining = max(0, displayDeadline.timeIntervalSinceNow)
        label.stringValue = "Auto-selects RAW in \(Int(remaining.rounded()))s — click to choose"
    }

    // MARK: - Screen targeting

    /// The screen the user is actually working on. NSScreen.main is useless
    /// here (this accessory app has no key window, so it falls back to
    /// screens[0]); the focused window of the frontmost app is the truth,
    /// with the mouse's screen and screens[0] as graceful fallbacks.
    private static func targetScreen() -> NSScreen? {
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
