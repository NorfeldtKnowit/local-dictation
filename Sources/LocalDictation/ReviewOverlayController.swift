import AppKit

/// The REVIEW panel: it must NEVER take key or main status. Keyboard routing
/// (and the caret) stays with the app the user is dictating into; selection is
/// mouse-only — `.nonactivatingPanel` delivers clicks without activating this
/// app. Do not "fix" anything here with `NSApp.activate`; that would deactivate
/// the target app, move first responder, and break the paste (same spirit as
/// the frozen AudioRecorder: the no-activation property is the whole feature).
///
/// Editing does NOT happen in this panel — it opens a separate `EditPanel`
/// (below). That split is deliberate and load-bearing: a `.nonactivatingPanel`
/// sets the WindowServer `kCGSPreventsActivationTagBit` at init, so this app is
/// never the *activated* foreground app for this window even under
/// `NSApp.activate` or a `.regular` policy — and that tag can't be cleared by
/// toggling the style mask later. In-process key events still route here (why
/// bare typing appears to work), but the system Character Viewer (⌃⌘Space emoji)
/// is an out-of-process agent that inserts into the *activated* app's text-input
/// client, so it can never target a nonactivating panel — hence the separate
/// activating editor window.
private final class ReviewOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The EDIT panel: a genuinely-activating borderless window (NOT a
/// `.nonactivatingPanel`) used only while the user hand-edits a candidate. It
/// becomes key/main so its `NSTextView` receives normal typing and is the
/// first responder the Character Viewer inserts into. The app stays a
/// never-in-Dock `.accessory` throughout — no activation-policy flip. The
/// emoji shortcut itself is wired directly (`EditTextView` intercepts ⌃⌘Space
/// and calls `orderFrontCharacterPalette`) because a menu-less accessory app
/// has no Edit-menu "Emoji & Symbols" item for the system shortcut to fire.
/// `leaveEditMode` hands focus back to the target before anything is inserted;
/// safe because edit mode never pastes.
private final class EditPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// An NSButton that responds to the first click even though its window is
/// never key (every click on this panel is a "first mouse").
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The inline editor's text view. Owns the action keys directly: ⌘+Return/Enter
/// copies the edit to the clipboard, ⌘S saves it back into the review HUD, Esc
/// cancels, and everything else (incl. a plain Return → newline) falls through
/// to `super` so multi-line editing works. `keyDown` — not `doCommandBy:` — is
/// the interception point because only it exposes the Command modifier needed to
/// tell ⌘⏎/⌘S from a bare newline; the footer buttons therefore carry NO key
/// equivalents (that would double-fire with these).
private final class EditTextView: NSTextView {
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        // ⌃⌘Space → Character Viewer (emoji). The system shortcut normally fires
        // the "Emoji & Symbols" item AppKit auto-adds to an app's Edit menu, but
        // a menu-less LaunchAgent accessory app has no such item, so the event
        // falls through to here with nothing to trigger it. Invoke the palette
        // ourselves; it inserts into this text view (the key window's first
        // responder). See ReviewOverlayController / CLAUDE.md.
        if event.keyCode == 0x31,                                       // Space
           flags.contains(.command), flags.contains(.control) {
            NSApplication.shared.orderFrontCharacterPalette(nil)
            return
        }
        let isReturn = event.keyCode == 0x24 || event.keyCode == 0x4C   // Return / keypad Enter
        if flags.contains(.command) {
            if isReturn { onCopy?(); return }
            if event.keyCode == 0x01 { onSave?(); return }              // ⌘S
        }
        if event.keyCode == 0x35 { onCancel?(); return }                // Esc
        super.keyDown(with: event)
    }
}

/// One clickable candidate row: a small badge (RAW / TERSE) plus wrapped
/// transcript text. Highlights on hover, fires `onClick` on mouse-up. The
/// text is mutable (`setText`) so the TERSE row can stream in.
private final class CandidateRow: NSView {
    /// How diffed words are marked: new/changed words in the TERSE row get a
    /// tinted background; words the rewrite dropped get struck + dimmed in
    /// the RAW row (shape + color, so it survives color-blind viewing).
    enum Highlight {
        case insertion
        case deletion
    }

    private static let textFont = NSFont.systemFont(ofSize: 13)

    /// Fixed edit-button hit target — comfortably clickable and big enough to
    /// read as an icon, not a speck.
    private static let editButtonSize: CGFloat = 26

    private let onClick: () -> Void
    private let onEdit: (() -> Void)?
    private let textLabel: NSTextField
    /// The trailing edit affordance, retained so row hover can emphasize it.
    private weak var editButton: NSButton?

    init(badge: String, text: String,
         onClick: @escaping () -> Void,
         onEdit: (() -> Void)? = nil) {
        self.onClick = onClick
        self.onEdit = onEdit

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Self.textFont
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
        // Reserve the trailing pencil column so wrapped text never slides under
        // the icon: row is panelWidth-24 (=496) wide, minus 10+10 insets, minus
        // the pencil column (button + gap ≈ 42).
        label.preferredMaxLayoutWidth = onEdit == nil ? 456 : 438
        label.isSelectable = false
        self.textLabel = label

        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        let badgeLabel = NSTextField(labelWithString: badge)
        badgeLabel.font = .systemFont(ofSize: 10, weight: .bold)
        badgeLabel.textColor = .secondaryLabelColor

        let textStack = NSStackView(views: [badgeLabel, label])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        // No edit affordance: text fills the whole padded row.
        guard onEdit != nil else {
            NSLayoutConstraint.activate([
                textStack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
                textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            ])
            return
        }

        // Clicking the text still inserts; the pencil opens the editor prefilled
        // with this row's version. The button intercepts its own click, so the
        // row's `mouseUp`/`onClick` never fires for a pencil tap. The pencil is
        // vertically CENTERED on the row (balanced for the short 1-2 line
        // utterances that dominate) and sized/hit-targeted to be obvious.
        let pencil = FirstMouseButton()
        pencil.image = NSImage(
            systemSymbolName: "square.and.pencil",
            accessibilityDescription: "Edit this version before inserting"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        pencil.imagePosition = .imageOnly
        pencil.isBordered = false
        pencil.bezelStyle = .regularSquare
        pencil.contentTintColor = .tertiaryLabelColor
        pencil.toolTip = "Edit this version before inserting (⌘⏎ to insert)"
        pencil.target = self
        pencil.action = #selector(editClicked)
        pencil.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pencil)
        editButton = pencil

        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            textStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: pencil.leadingAnchor, constant: -8),
            pencil.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            pencil.centerYAnchor.constraint(equalTo: centerYAnchor),
            pencil.widthAnchor.constraint(equalToConstant: Self.editButtonSize),
            pencil.heightAnchor.constraint(equalToConstant: Self.editButtonSize),
        ])
    }

    @objc private func editClicked() { onEdit?() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setText(_ text: String) {
        textLabel.stringValue = text
    }

    func setText(_ text: String, marking ranges: [Range<String.Index>],
                 as highlight: Highlight) {
        guard !ranges.isEmpty else {
            setText(text)
            return
        }
        textLabel.attributedStringValue = Self.highlighted(text, ranges, highlight)
    }

    private static func highlighted(_ text: String,
                                    _ ranges: [Range<String.Index>],
                                    _ highlight: Highlight) -> NSAttributedString {
        // attributedStringValue replaces the field's own font/wrap setup, so
        // the base attributes must restate them; .byWordWrapping keeps the
        // multi-line cell layout (see the truncation note in init).
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: textFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        for range in ranges {
            let nsRange = NSRange(range, in: text)
            switch highlight {
            case .insertion:
                // Semantic system color: tracks dark/light like the hover tint.
                attributed.addAttribute(
                    .backgroundColor,
                    value: NSColor.systemGreen.withAlphaComponent(0.28),
                    range: nsRange)
            case .deletion:
                attributed.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: NSColor.secondaryLabelColor,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ], range: nsRange)
            }
        }
        return attributed
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
        // Promote the pencil from a faint hint to clearly-actionable while the
        // row is under the pointer.
        editButton?.contentTintColor = .labelColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        editButton?.contentTintColor = .tertiaryLabelColor
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

    /// Fired when the user opens the inline editor (suspends the countdown) and
    /// when they back out of it (resumes the countdown), respectively.
    var onBeginEdit: ((UInt64) -> Void)?
    var onCancelEdit: ((UInt64) -> Void)?

    /// Fired when the user hits "Copy" in the editor: stage `text` on the
    /// clipboard and settle the utterance without pasting.
    var onCopyEdit: ((UInt64, String) -> Void)?
    /// Fired when the user hits "Save" in the editor, carrying (id, edited text,
    /// wasEditingRaw). A raw edit re-polishes; a styled edit re-diffs.
    var onSaveEdit: ((UInt64, String, Bool) -> Void)?

    /// Fired when the user picks a different polish style from the in-HUD menu,
    /// carrying (id, template id, display name). The coordinator re-polishes.
    var onSelectStyle: ((UInt64, String, String) -> Void)?
    /// Supplies the style list (id + display name) for the in-HUD picker.
    var stylesProvider: (() -> [(id: String, name: String)])?

    /// A style choice carried on the picker's menu items.
    private struct StyleChoice { let id: String; let name: String }

    /// Which candidate the pencil opened the editor on.
    private enum EditSource { case raw, polished }

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
    /// The separate activating editor window, created lazily on first edit and
    /// reused. Ordered out (never destroyed) between edits.
    private var editPanel: EditPanel?
    private var statusLabel: NSTextField?
    private var polishedRow: CandidateRow?
    private var rawRow: CandidateRow?
    /// The shown request's raw text, kept for diffing the settled rewrite.
    private var shownRaw: String?
    /// The whole shown request, kept so Cancel can rebuild the two-candidate
    /// view and so the terse pencil can resolve the settled rewrite text.
    /// `polish` is updated in place when the rewrite finalizes.
    private var shownRequest: ReviewRequest?
    /// True while the inline editor is up. The countdown is suspended (logic
    /// side) and the panel is temporarily key + active (see `ReviewOverlayPanel`).
    private var isEditing = false
    /// Which candidate the editor is open on, so Save knows whether to re-polish
    /// (raw) or re-diff (styled). nil when not editing.
    private var editingSource: EditSource?
    /// The editor's text view while editing, else nil.
    private var editTextView: EditTextView?
    /// The app that was frontmost when editing began — re-fronted on
    /// Copy/Save/Cancel so the caret returns to it.
    private var savedFrontApp: NSRunningApplication?
    /// The shown request's rewrite-row badge (uppercased template name), reused
    /// by the countdown label so it names the version that will auto-insert.
    private var shownBadge = "TERSE"
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
        shownRequest = request
        shownAt = Date()
        shownBadge = request.badge
        status = .polishing
        // A fresh request always starts in review mode, never editing.
        isEditing = false
        editingSource = nil
        editTextView = nil
        savedFrontApp = nil
        editPanel?.orderOut(nil)
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
        shownRequest = nil
        polishedRow = nil
        rawRow = nil
        shownRaw = nil
        statusLabel = nil
        // Leave no path that keeps an editor open after teardown.
        isEditing = false
        editingSource = nil
        editTextView = nil
        savedFrontApp = nil
        editPanel?.orderOut(nil)
        panel?.orderOut(nil)
    }

    /// Stream the rewrite into the TERSE row. Partials (`final: false`) are
    /// display-only; the final text replaces them verbatim and gets the
    /// raw↔terse diff highlight (partials stay plain: diffing a half-streamed
    /// rewrite against the full raw would mark the whole un-streamed tail as
    /// deleted and flicker on every token). Stale IDs are dropped (the queue
    /// may have advanced past the streaming request).
    func setPolished(id: UInt64, text: String, final: Bool) {
        guard shownID == id, let row = polishedRow else { return }
        if final, let raw = shownRaw {
            applyDiff(raw: raw, terse: text)
            // Record the settled rewrite so the terse pencil can prefill it and
            // a Cancel rebuild re-renders the diff.
            shownRequest?.polish = .rewrite(text)
        } else {
            row.setText(text)
        }
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

    /// A borderless activating window for the inline editor. NOT a
    /// `.nonactivatingPanel` — see the `EditPanel` note for why that distinction
    /// is what makes the Character Viewer work. Otherwise mirrors the review
    /// panel's floating/all-spaces behavior so the editor sits in the same spot.
    private static func makeEditPanel() -> EditPanel {
        let panel = EditPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 160),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .utilityWindow
        return panel
    }

    /// Size to fit and pin the TOP edge to a fixed offset below the visible
    /// frame's top, so streaming growth extends downward instead of jumping.
    private func positionAndReveal(_ panel: NSWindow, activate: Bool = false) {
        guard let content = panel.contentView else { return }
        let size = content.fittingSize
        let screen = ScreenLocator.activeScreen()
        // visibleFrame (not frame): stays clear of the menu bar and the notch
        // housing on notched MacBooks, and adapts when the menu bar auto-hides.
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - size.height - 12)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        // The review panel must never activate (see ReviewOverlayPanel); the
        // editor must (see EditPanel), so its caller passes activate: true.
        if activate {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
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

        // In-HUD style picker: pops a menu of templates and re-polishes the raw
        // text with the chosen one. Only meaningful once a rewrite has settled;
        // otherwise the click is a no-op (see showStyleMenu).
        let styleButton = FirstMouseButton()
        styleButton.bezelStyle = .roundRect
        styleButton.controlSize = .small
        styleButton.font = .systemFont(ofSize: 10, weight: .medium)
        styleButton.title = "Style: \(request.badge)"
        // A real SF Symbol chevron (AppKit baseline-aligns it next to the title),
        // not a tacked-on glyph that renders tiny and off-baseline.
        styleButton.image = NSImage(systemSymbolName: "chevron.down",
                                    accessibilityDescription: "Change style")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        styleButton.imagePosition = .imageTrailing
        styleButton.imageHugsTitle = true
        styleButton.target = self
        styleButton.action = #selector(styleButtonClicked(_:))

        let dismiss = FirstMouseButton()
        dismiss.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                accessibilityDescription: "Dismiss (insert nothing)")
        dismiss.isBordered = false
        dismiss.contentTintColor = .tertiaryLabelColor
        dismiss.target = self
        dismiss.action = #selector(dismissClicked)

        let header = NSStackView(views: [title, styleButton, NSView(), dismiss])
        header.orientation = .horizontal

        let id = request.id
        let rawRow = CandidateRow(badge: "RAW", text: request.raw, onClick: { [weak self] in
            self?.fireChoice(id: id, .raw)
        }, onEdit: { [weak self] in
            self?.fireEdit(id: id, .raw)
        })
        self.rawRow = rawRow
        shownRaw = request.raw

        // The rewrite row exists only while polishing (`…`) or once a rewrite
        // has settled. A declined/echoed polish (`.none`) is a RAW-ONLY review —
        // no second row — but the overlay still shows so the user reviews /
        // edits / dismisses before anything pastes.
        let terseRow: CandidateRow?
        switch request.polish {
        case .none:
            terseRow = nil
            polishedRow = nil
        case .pending:
            let row = CandidateRow(badge: request.badge, text: "…", onClick: { [weak self] in
                self?.fireChoice(id: id, .polished)
            }, onEdit: { [weak self] in
                self?.fireEdit(id: id, .polished)
            })
            terseRow = row
            polishedRow = row
        case .rewrite(let rewrite):
            let row = CandidateRow(badge: request.badge, text: rewrite, onClick: { [weak self] in
                self?.fireChoice(id: id, .polished)
            }, onEdit: { [weak self] in
                self?.fireEdit(id: id, .polished)
            })
            terseRow = row
            polishedRow = row
            // Re-shown from the queue with the rewrite already settled — the
            // streaming path's final update never comes, so diff here.
            applyDiff(raw: request.raw, terse: rewrite)
        }

        let statusText = NSTextField(labelWithString: "")
        statusText.font = .systemFont(ofSize: 10)
        statusText.textColor = .tertiaryLabelColor
        statusLabel = statusText

        var rows: [NSView] = [header, rawRow]
        if let terseRow { rows.append(terseRow) }
        rows.append(statusText)
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        var constraints: [NSLayoutConstraint] = [
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            effect.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            rawRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ]
        if let terseRow {
            constraints.append(terseRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24))
        }
        NSLayoutConstraint.activate(constraints)
        return effect
    }

    /// Mark what the rewrite changed: dropped words struck + dimmed in RAW,
    /// new/changed words tinted in TERSE.
    private func applyDiff(raw: String, terse: String) {
        let highlights = TranscriptDiffLogic.highlights(raw: raw, terse: terse)
        rawRow?.setText(raw, marking: highlights.rawDeletions, as: .deletion)
        polishedRow?.setText(terse, marking: highlights.terseInsertions, as: .insertion)
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

    // MARK: - Restyle (change the polish style, re-polish the raw)

    @objc private func styleButtonClicked(_ sender: NSButton) {
        guard let id = shownID else { return }
        // Restyle a settled review (a rewrite OR a declined raw-only view) but
        // never mid-polish — a second polish would race the first. Also honor
        // the click shield.
        guard Date().timeIntervalSince(shownAt) >= Self.clickShield,
              let request = shownRequest, request.id == id,
              let styles = stylesProvider?(), !styles.isEmpty else { return }
        switch request.polish {
        case .rewrite, .none: break
        case .pending:        return
        }
        let menu = NSMenu()
        for style in styles {
            let item = NSMenuItem(title: style.name, action: #selector(styleMenuPicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = StyleChoice(id: style.id, name: style.name)
            item.state = (style.name.uppercased() == request.badge) ? .on : .off
            menu.addItem(item)
        }
        // popUp runs its own tracking loop and needs no key window — the safe
        // pattern for this never-key panel (same reason as FirstMouseButton).
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func styleMenuPicked(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? StyleChoice, let id = shownID else { return }
        onSelectStyle?(id, choice.id, choice.name)
    }

    /// Repaint for a restyle: new badge, rewrite row back to "…", status back to
    /// "Rewriting…". The streamed re-polish then flows in through `setPolished`,
    /// whose final update re-applies the raw↔new diff.
    func beginRepolish(id: UInt64, badge: String) {
        guard shownID == id, var request = shownRequest, let panel else { return }
        request.badge = badge
        request.polish = .pending
        shownRequest = request
        shownBadge = badge
        status = .polishing
        panel.contentView = buildContent(request)
        positionAndReveal(panel)
        isHovering = pointerIsOverPanel
        refreshStatus()
    }

    // MARK: - Edit before insert

    /// A pencil was clicked. Resolve the candidate's current text and open the
    /// editor. Guards mirror `fireChoice`: honor the click shield, ignore a
    /// click aimed at a since-advanced request, and no-op editing the rewrite
    /// before it has settled (same as clicking the "…" terse row).
    private func fireEdit(id: UInt64, _ source: EditSource) {
        guard Date().timeIntervalSince(shownAt) >= Self.clickShield else { return }
        guard !isEditing, let request = shownRequest, request.id == id, shownID == id else { return }
        let prefill: String
        switch source {
        case .raw:
            prefill = request.raw
        case .polished:
            guard case .rewrite(let rewrite) = request.polish else { return }
            prefill = rewrite
        }
        enterEditMode(id: id, prefill: prefill, source: source)
    }

    private func enterEditMode(id: UInt64, prefill: String, source: EditSource) {
        guard let panel, shownID == id else { return }
        isEditing = true
        editingSource = source
        savedFrontApp = NSWorkspace.shared.frontmostApplication
        statusTimer?.invalidate()
        statusTimer = nil
        statusLabel = nil

        // Editing runs in the separate activating EditPanel (the review panel
        // can't take Character Viewer input — see the class notes). Hand the
        // editor its content and swap the review panel out for it.
        let editPanel = self.editPanel ?? Self.makeEditPanel()
        self.editPanel = editPanel
        editPanel.contentView = buildEditContent(prefill: prefill, id: id)
        panel.orderOut(nil)

        // Activate and reveal the editor as a key/main window (the app stays a
        // never-in-Dock .accessory — no policy flip needed). Typing and the
        // Character Viewer both target this window's first responder.
        NSApp.activate(ignoringOtherApps: true)
        positionAndReveal(editPanel, activate: true)
        if let textView = editTextView {
            editPanel.makeFirstResponder(textView)
            // Caret at the end so a "last-minute change" starts where you'd type.
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }
        onBeginEdit?(id)
    }

    /// Copy the edited text to the clipboard and hand keyboard focus back to the
    /// target, then settle WITHOUT pasting (the caret has moved — see
    /// `ReviewQueueLogic.copyEdited`). Deliberate action, no click shield.
    private func copyEdit(id: UInt64) {
        guard isEditing, shownID == id else { return }
        let text = editTextView?.string ?? ""
        leaveEditMode()
        onCopyEdit?(id, text)
    }

    /// Save the edited text back into the review HUD: a raw edit re-polishes with
    /// the current style, a styled edit re-runs the diff. Hands focus back first
    /// (the HUD returns to never-key review mode).
    private func saveEdit(id: UInt64) {
        guard isEditing, shownID == id else { return }
        let text = editTextView?.string ?? ""
        let editingRaw = editingSource == .raw
        leaveEditMode()
        onSaveEdit?(id, text, editingRaw)
    }

    /// Back out of the editor to the two-candidate review, re-arming the
    /// countdown. Keeps the HUD visible; hands focus back to the target.
    private func cancelEditMode(id: UInt64) {
        guard isEditing, shownID == id, let panel, let request = shownRequest else { return }
        leaveEditMode()
        status = .awaitClick   // placeholder until onCancelEdit re-arms the deadman
        panel.contentView = buildContent(request)
        // Re-show the review panel the editor replaced (never activating).
        positionAndReveal(panel)
        isHovering = pointerIsOverPanel
        startStatusTimer()
        refreshStatus()
        onCancelEdit?(id)
    }

    /// Close the editor window and hand focus back to the target: order the
    /// EditPanel out and re-front `savedFrontApp` so the caret returns there.
    /// Save/Cancel re-show the review panel after this; Copy hides everything.
    private func leaveEditMode() {
        isEditing = false
        editingSource = nil
        editTextView = nil
        editPanel?.orderOut(nil)
        savedFrontApp?.activate()
        savedFrontApp = nil
    }

    private func buildEditContent(prefill: String, id: UInt64) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: "Edit before insert")
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        // NSTextView-in-NSScrollView: the standard programmatic wiring so the
        // view grows with text and scrolls past the fixed box height.
        let scroll = NSScrollView()
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let textView = EditTextView()
        textView.string = prefill
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.onCopy = { [weak self] in self?.copyEdit(id: id) }
        textView.onSave = { [weak self] in self?.saveEdit(id: id) }
        textView.onCancel = { [weak self] in self?.cancelEditMode(id: id) }
        scroll.documentView = textView
        self.editTextView = textView

        // No key equivalents on these buttons: EditTextView.keyDown owns the
        // ⌘⏎/⌘S/esc shortcuts (setting them here too would double-fire).
        let copy = FirstMouseButton()
        copy.title = "Copy"
        copy.bezelStyle = .rounded
        copy.toolTip = "Copy to clipboard, insert nothing (⌘⏎)"
        copy.target = self
        copy.action = #selector(copyClicked)

        let save = FirstMouseButton()
        save.title = "Save"
        save.bezelStyle = .rounded
        save.toolTip = "Save back to review — re-styles a raw edit, re-diffs a styled edit (⌘S)"
        save.target = self
        save.action = #selector(saveClicked)

        let cancel = FirstMouseButton()
        cancel.title = "Cancel"
        cancel.bezelStyle = .rounded
        cancel.toolTip = "Discard the edit (esc)"
        cancel.target = self
        cancel.action = #selector(cancelClicked)

        let hint = NSTextField(labelWithString: "⌘⏎ copy · ⌘S save · esc cancel")
        hint.font = .systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor

        let footer = NSStackView(views: [hint, NSView(), cancel, save, copy])
        footer.orientation = .horizontal
        footer.spacing = 8

        let stack = NSStackView(views: [title, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            effect.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            scroll.heightAnchor.constraint(equalToConstant: 140),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
        ])
        return effect
    }

    @objc private func copyClicked() {
        guard let id = shownID else { return }
        copyEdit(id: id)
    }

    @objc private func saveClicked() {
        guard let id = shownID else { return }
        saveEdit(id: id)
    }

    @objc private func cancelClicked() {
        guard let id = shownID else { return }
        cancelEditMode(id: id)
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

    /// True when there is no rewrite to compare — a declined/echoed polish
    /// shown as a raw-only review (drives the raw-only status wording).
    private var isRawOnly: Bool {
        // .some(.none): the request is shown AND its polish settled to .none.
        // A bare `case .none` would match Optional.none (no request shown) —
        // never the PolishState.none we mean, so the raw-only wording never fired.
        if case .some(.none) = shownRequest?.polish { return true }
        return false
    }

    private func refreshStatus() {
        guard let label = statusLabel else { return }
        let rawOnly = isRawOnly
        switch status {
        case .polishing:
            label.stringValue = "Rewriting… — click RAW to use it now, ✕ for nothing"
        case .awaitClick:
            label.stringValue = rawOnly
                ? "No rewrite — click RAW to insert, edit it, or ✕ for nothing"
                : "Click a version to use it — ✕ for nothing"
        case .countdown(let deadline):
            if isHovering {
                label.stringValue = "Paused — click a version, or ✕ for nothing"
            } else {
                let remaining = Int(max(0, deadline.timeIntervalSinceNow).rounded())
                label.stringValue = rawOnly
                    ? "RAW auto-inserts in \(remaining)s — click to insert now, edit, or ✕"
                    : "\(shownBadge) auto-inserts in \(remaining)s · RAW goes to the clipboard"
            }
        }
    }

}
