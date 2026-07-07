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

/// One clickable candidate row: a small badge (RAW / TERSE) plus wrapped
/// transcript text. Highlights on hover, fires `onClick` on mouse-up. The
/// text is mutable (`setText`) so the TERSE row can stream in.
private final class CandidateRow: NSView {
    private let onClick: () -> Void
    private let textLabel: NSTextField

    init(badge: String, text: String, onClick: @escaping () -> Void) {
        self.onClick = onClick

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        // Generous cap so the whole transcript is reviewable (the point of
        // the overlay); at ~70 chars/line this covers north of 800 chars per
        // candidate. Extreme dictations ellipsize on the last line — the raw
        // text is still recoverable via clipboard/log.
        label.maximumNumberOfLines = 12
        // NOT lineBreakMode = .byTruncatingTail: any truncating mode flips
        // the cell to single-line layout and maximumNumberOfLines goes inert
        // (verified empirically — the rows rendered exactly one line). This
        // keeps word-wrap and only ellipsizes the last line on overflow.
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = 456
        label.isSelectable = false
        self.textLabel = label

        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        let badgeLabel = NSTextField(labelWithString: badge)
        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [badgeLabel, label])
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

    func setText(_ text: String) {
        textLabel.stringValue = text
    }

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

/// Tracks pointer presence over the whole panel content so the countdown
/// label can reflect the hover pause (the AUTHORITATIVE hover check for the
/// deadman is geometry — see `pointerIsOverPanel`).
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

/// The AppKit half of "Review Before Paste": a floating HUD near the top of
/// the screen the user is working on. Shows the RAW transcript immediately;
/// the TERSE rewrite STREAMS into the second row as it generates; a status
/// line below shows rewrite progress / the auto-insert countdown / the
/// click prompt. Pure presentation — every decision (including timeouts)
/// lives in `ReviewQueueLogic`, driven by `ReviewCoordinator`.
final class ReviewOverlayController {
    /// What the status line should say (hover overrides `.countdown`).
    private enum Status {
        case polishing
        case countdown(deadline: Date)
        case awaitClick
    }

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

    /// Display-only hover mirror (drives the status label wording).
    private var isHovering = false

    private var panel: ReviewOverlayPanel?
    private var statusLabel: NSTextField?
    private var polishedRow: CandidateRow?
    private var statusTimer: Timer?
    private var status = Status.polishing
    /// The request currently rendered, and when it appeared. Clicks within
    /// `clickShield` of a (re)show are dropped: a click already in flight when
    /// the queue auto-advanced must not decide the next request sight-unseen.
    private var shownID: UInt64?
    private var shownAt = Date.distantPast
    /// Streaming updates resize at most every `resizeInterval` (plus always on
    /// the final text) — per-token re-layout of the panel is visual noise.
    private var lastResizeAt = Date.distantPast
    private static let resizeInterval: TimeInterval = 0.3

    private static let panelWidth: CGFloat = 520
    private static let clickShield: TimeInterval = 0.4

    func show(_ request: ReviewRequest) {
        let panel = self.panel ?? Self.makePanel()
        self.panel = panel
        shownID = request.id
        shownAt = Date()
        status = .polishing
        panel.contentView = buildContent(request)
        if case .rewrite = request.polish {
            // Re-shown from the queue with the rewrite already settled; the
            // coordinator's armDeadman command (right behind the show) sets
            // the real status. Render non-streaming text meanwhile.
            status = .awaitClick
        }

        positionAndReveal(panel)

        // Seed the display hover state from geometry: a pointer already parked
        // inside the fresh panel produces no mouseEntered crossing.
        isHovering = pointerIsOverPanel
        startStatusTimer()
        refreshStatus()
    }

    func hide() {
        statusTimer?.invalidate()
        statusTimer = nil
        isHovering = false
        shownID = nil
        polishedRow = nil
        statusLabel = nil
        panel?.orderOut(nil)
    }

    /// Stream the rewrite into the TERSE row. Partials (`final: false`) are
    /// display-only; the final text replaces them verbatim. Stale IDs are
    /// dropped (the queue may have advanced past the streaming request).
    func setPolished(id: UInt64, text: String, final: Bool) {
        guard shownID == id, let row = polishedRow else { return }
        row.setText(text)
        let now = Date()
        if final || now.timeIntervalSince(lastResizeAt) >= Self.resizeInterval {
            lastResizeAt = now
            if let panel { positionAndReveal(panel) }
        }
    }

    /// The deadman was (re)armed for `delay` seconds — run the countdown.
    func resetCountdown(_ delay: TimeInterval) {
        status = .countdown(deadline: Date().addingTimeInterval(delay))
        refreshStatus()
    }

    /// `.never` policy: no deadman — prompt for a click instead.
    func showAwaitClick() {
        status = .awaitClick
        refreshStatus()
    }

    // MARK: - Panel construction

    private static func makePanel() -> ReviewOverlayPanel {
        let panel = ReviewOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Do not set isFloatingPanel: its setter assigns the window level as
        // a side effect and would silently demote this deliberate .statusBar
        // back to .floating (verified empirically).
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
        panel.becomesKeyOnlyIfNeeded = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .utilityWindow
        return panel
    }

    /// Size to fit and pin the TOP edge to a fixed offset below the visible
    /// frame's top, so streaming growth extends downward instead of jumping.
    private func positionAndReveal(_ panel: ReviewOverlayPanel) {
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        let screen = Self.targetScreen()
        // visibleFrame (not frame): stays clear of the menu bar and the notch
        // housing on notched MacBooks, and adapts when the menu bar auto-hides.
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - size.height - 12)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        // orderFrontRegardless, never any activation: see ReviewOverlayPanel.
        panel.orderFrontRegardless()
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
            self?.refreshStatus()
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
        let polishedText: String
        switch request.polish {
        case .pending:              polishedText = "…"
        case .none:                 polishedText = "…"   // logic never shows .none
        case .rewrite(let rewrite): polishedText = rewrite
        }
        let terseRow = CandidateRow(badge: "TERSE", text: polishedText) { [weak self] in
            self?.fireChoice(id: id, .polished)
        }
        polishedRow = terseRow

        let statusText = NSTextField(labelWithString: "")
        statusText.font = .systemFont(ofSize: 10)
        statusText.textColor = .tertiaryLabelColor
        statusLabel = statusText

        let stack = NSStackView(views: [header, rawRow, terseRow, statusText])
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
            terseRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
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

    // MARK: - Status line

    private func startStatusTimer() {
        statusTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        // .common so it keeps ticking while the status-item menu is open
        // (NSEventTrackingRunLoopMode stalls .default-mode timers).
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    private func refreshStatus() {
        guard let label = statusLabel else { return }
        switch status {
        case .polishing:
            label.stringValue = "Rewriting… — click RAW to use it now, ✕ for nothing"
        case .awaitClick:
            label.stringValue = "Click a version to use it — ✕ for nothing"
        case .countdown(let deadline):
            if isHovering {
                label.stringValue = "Paused — click a version, or ✕ for nothing"
            } else {
                let remaining = max(0, deadline.timeIntervalSinceNow)
                label.stringValue = "TERSE auto-inserts in \(Int(remaining.rounded()))s · RAW goes to the clipboard"
            }
        }
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
