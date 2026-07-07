import AppKit

final class MenuBar {
    enum State {
        case loading(String)        // model downloading / warming up
        case idle                   // ready, waiting for hotkey
        case listening              // recording audio (Naples yellow)
        case transcribing           // running Whisper on the captured audio
        case error(String)
    }

    /// Naples yellow / mustard — the listening indicator.
    private static let naplesYellow = NSColor(srgbRed: 0xFA/255.0, green: 0xDA/255.0, blue: 0x5E/255.0, alpha: 1.0)

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
    private let recordMenuItem = NSMenuItem(title: "Start Recording", action: nil, keyEquivalent: "")

    /// Language ▸ submenu (Auto · Parakeet's 28 · Whisper-only extras) and the
    /// Accuracy Mode checkbox. MenuBar only renders and reports; the persisted
    /// state lives in `LanguageSetting`, owned by `AppDelegate`.
    private let languageMenu = NSMenu()
    private let accuracyMenuItem = NSMenuItem(title: "Accuracy Mode (Whisper, all languages)",
                                              action: nil, keyEquivalent: "")
    private let polishMenuItem = NSMenuItem(title: "Polish Transcript (AI cleanup)",
                                            action: nil, keyEquivalent: "")
    private let copyModeMenuItem = NSMenuItem(title: "Copy Instead of Paste",
                                              action: nil, keyEquivalent: "")
    private let reviewMenuItem = NSMenuItem(title: "Review Before Paste",
                                            action: nil, keyEquivalent: "")

    /// Whisper-only pins offered below the Parakeet set. Norwegian is here on
    /// purpose: FluidAudio's `Language` enum has no "no"/"nb", so Norwegian must
    /// route to Whisper (see `EngineRouter`). The Whisper section additionally
    /// gets `EngineRouter.whisperPreferred` (Danish) prepended at build time —
    /// languages Parakeet supports but Whisper transcribes materially better.
    private static let whisperOnlyCodes = ["no", "ja", "zh", "ko", "ar"]

    /// Rotating SF Symbol shown (in Naples yellow) while Whisper transcribes.
    private var spinnerTimer: Timer?
    private var spinnerAngle: CGFloat = 0
    private static let spinnerSymbol = "arrow.triangle.2.circlepath"

    var onQuit: (() -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onOpenInputMonitoring: (() -> Void)?
    var onOpenMicrophone: (() -> Void)?
    var onToggleRecord: (() -> Void)?
    /// Fired with "auto" or an ISO code when the user picks a language.
    var onSelectLanguage: ((String) -> Void)?
    /// Fired with the new value when the user toggles Accuracy Mode.
    var onToggleAccuracy: ((Bool) -> Void)?
    /// Fired with the new value when the user toggles Polish Transcript.
    var onTogglePolish: ((Bool) -> Void)?
    /// Fired with the new value when the user toggles Copy Instead of Paste.
    var onToggleCopyMode: ((Bool) -> Void)?
    /// Fired with the new value when the user toggles Review Before Paste.
    var onToggleReview: ((Bool) -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureMenu()
        // We deliberately do NOT assign `statusItem.menu` — that would make every
        // click open the dropdown. Instead we handle the button action ourselves so
        // a left-click toggles recording and a right/Control-click shows the menu.
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        update(.loading("Starting…"))
    }

    private func configureMenu() {
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hold Right Option, or click the icon, to dictate", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        recordMenuItem.target = self
        recordMenuItem.action = #selector(toggleRecord)
        menu.addItem(recordMenuItem)
        menu.addItem(.separator())

        // Language ▸ submenu + Accuracy Mode checkbox. State additions are menu
        // ITEMS only — the State enum above keeps exactly its 5 cases.
        configureLanguageMenu()
        let languageItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)

        accuracyMenuItem.target = self
        accuracyMenuItem.action = #selector(toggleAccuracy)
        accuracyMenuItem.toolTip = "Route every utterance to Whisper large-v3 — slower, most accurate, all languages."
        menu.addItem(accuracyMenuItem)

        polishMenuItem.target = self
        polishMenuItem.action = #selector(togglePolish)
        polishMenuItem.toolTip = "Fix misheard words, restarts and fillers with the on-device Apple "
                               + "Intelligence model. Requires Apple Intelligence to be enabled in "
                               + "System Settings; inactive (no effect) otherwise."
        menu.addItem(polishMenuItem)

        reviewMenuItem.target = self
        reviewMenuItem.action = #selector(toggleReview)
        reviewMenuItem.toolTip = "After each dictation, show a small overlay with the raw transcript "
                               + "and a terse AI rewrite; click the one to insert (the raw version "
                               + "auto-inserts after a few seconds). Requires Polish Transcript."
        menu.addItem(reviewMenuItem)

        copyModeMenuItem.target = self
        copyModeMenuItem.action = #selector(toggleCopyMode)
        copyModeMenuItem.toolTip = "Leave the transcript on the clipboard instead of pasting it "
                                 + "into the focused app — paste it yourself with Cmd+V."
        menu.addItem(copyModeMenuItem)
        menu.addItem(.separator())

        let micItem = NSMenuItem(title: "Open Microphone settings…",
                                 action: #selector(openMicrophone),
                                 keyEquivalent: "")
        micItem.target = self
        menu.addItem(micItem)

        let axItem = NSMenuItem(title: "Open Accessibility settings…",
                                action: #selector(openAccessibility),
                                keyEquivalent: "")
        axItem.target = self
        menu.addItem(axItem)

        let imItem = NSMenuItem(title: "Open Input Monitoring settings…",
                                action: #selector(openInputMonitoring),
                                keyEquivalent: "")
        imItem.target = self
        menu.addItem(imItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Auto ✓ · the 28 FluidAudio `Language` cases (Parakeet, low latency) ·
    /// separator · a curated "Other (Whisper)" list of pins Parakeet can't do.
    /// Each selectable item carries its "auto"/ISO code in `representedObject`
    /// so one action handles them all and checkmarks are a simple code compare.
    private func configureLanguageMenu() {
        let auto = NSMenuItem(title: "Auto", action: #selector(selectLanguage(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = "auto"
        // Known accepted limitation (documented here rather than papered over):
        // Auto detects only among Parakeet's 28; other languages need a pin.
        // (Danish IS auto-detected — from the transcript — and re-routed to
        // Whisper for quality, including mid-utterance Danish/English mixing.)
        auto.toolTip = "Detects among Parakeet's languages; Danish is re-routed to Whisper "
                     + "automatically. For Norwegian, Japanese, Chinese, Korean or Arabic, "
                     + "pin the language below or enable Accuracy Mode."
        languageMenu.addItem(auto)
        languageMenu.addItem(.separator())

        // EngineRouter is the routing source of truth (derived from FluidAudio's
        // Language enum minus the Whisper-preferred set); building the submenu
        // from it keeps the menu and the router incapable of drifting apart.
        for code in Self.displaySorted(Array(EngineRouter.parakeetMenuLanguages)) {
            languageMenu.addItem(languageItem(code: code))
        }

        languageMenu.addItem(.separator())
        // nil action → AppKit auto-disables it: a section header, not a choice.
        languageMenu.addItem(NSMenuItem(title: "Other (Whisper)", action: nil, keyEquivalent: ""))
        for code in Self.displaySorted(Array(EngineRouter.whisperPreferred)) + Self.whisperOnlyCodes {
            languageMenu.addItem(languageItem(code: code))
        }
    }

    private func languageItem(code: String) -> NSMenuItem {
        let item = NSMenuItem(title: Self.displayName(code),
                              action: #selector(selectLanguage(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = code
        return item
    }

    /// Human-readable name in the user's UI locale ("da" → "Danish"/"dansk").
    private static func displayName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private static func displaySorted(_ codes: [String]) -> [String] {
        codes.sorted {
            displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending
        }
    }

    /// Render the current language pin (checkmark). Called by `AppDelegate` at
    /// launch with the persisted value and again after each selection.
    func setLanguage(_ code: String) {
        DispatchQueue.main.async { [self] in
            for item in languageMenu.items {
                item.state = ((item.representedObject as? String) == code) ? .on : .off
            }
        }
    }

    /// Render the Accuracy Mode checkbox.
    func setAccuracyMode(_ enabled: Bool) {
        DispatchQueue.main.async { [self] in
            accuracyMenuItem.state = enabled ? .on : .off
        }
    }

    /// Render the Polish Transcript checkbox.
    func setPolishTranscript(_ enabled: Bool) {
        DispatchQueue.main.async { [self] in
            polishMenuItem.state = enabled ? .on : .off
        }
    }

    /// Render the Copy Instead of Paste checkbox.
    func setCopyMode(_ enabled: Bool) {
        DispatchQueue.main.async { [self] in
            copyModeMenuItem.state = enabled ? .on : .off
        }
    }

    /// Render the Review Before Paste checkbox.
    func setReview(_ enabled: Bool) {
        DispatchQueue.main.async { [self] in
            reviewMenuItem.state = enabled ? .on : .off
        }
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        setLanguage(code)
        onSelectLanguage?(code)
    }

    @objc private func toggleAccuracy() {
        let enabled = accuracyMenuItem.state != .on
        setAccuracyMode(enabled)
        onToggleAccuracy?(enabled)
    }

    @objc private func togglePolish() {
        let enabled = polishMenuItem.state != .on
        setPolishTranscript(enabled)
        onTogglePolish?(enabled)
    }

    @objc private func toggleCopyMode() {
        let enabled = copyModeMenuItem.state != .on
        setCopyMode(enabled)
        onToggleCopyMode?(enabled)
    }

    @objc private func toggleReview() {
        let enabled = reviewMenuItem.state != .on
        setReview(enabled)
        onToggleReview?(enabled)
    }

    func update(_ state: State) {
        DispatchQueue.main.async { [self] in
            let symbol: String
            let title: String
            var tint: NSColor? = nil
            var template = true
            var transcribing = false

            recordMenuItem.title = "Start Recording"

            switch state {
            case .loading(let what):
                symbol = "arrow.down.circle"
                title = what
            case .idle:
                // Deliberately NOT a mic: macOS itself shows a mic indicator in
                // the menu bar while we record, so a mic here reads as a
                // duplicate. The waveform is the app's own identity.
                symbol = "waveform"
                title = "Idle — hold Right Option to dictate"
            case .listening:
                symbol = "waveform.circle.fill"
                title = "Listening…"
                tint = Self.naplesYellow
                template = false
                recordMenuItem.title = "Stop Recording"
            case .transcribing:
                symbol = "waveform"
                title = "Transcribing…"
                transcribing = true
            case .error(let message):
                symbol = "exclamationmark.triangle"
                title = "Error: \(message)"
            }

            statusMenuItem.title = title

            // While transcribing, replace the icon with a live spinner so it's
            // obvious work is happening; otherwise show the state's symbol.
            if transcribing {
                startSpinner()
            } else {
                stopSpinner()
                if let button = statusItem.button {
                    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                    image?.isTemplate = template
                    button.image = image
                    button.contentTintColor = tint
                }
            }
        }
    }

    private func startSpinner() {
        statusItem.button?.contentTintColor = Self.naplesYellow
        renderSpinnerFrame()
        guard spinnerTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.renderSpinnerFrame()
        }
        // .common so it keeps spinning even while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        spinnerTimer = timer
    }

    private func renderSpinnerFrame() {
        spinnerAngle -= .pi / 18   // ~10° clockwise per tick
        statusItem.button?.image = Self.rotatedSpinnerImage(angle: spinnerAngle)
    }

    private func stopSpinner() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
        spinnerAngle = 0
        statusItem.button?.contentTintColor = nil
    }

    /// The spinner symbol drawn rotated by `angle`, as a template image so the
    /// button's `contentTintColor` (Naples yellow) colors it.
    private static func rotatedSpinnerImage(angle: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        guard let base = NSImage(systemSymbolName: spinnerSymbol, accessibilityDescription: "Transcribing")?
            .withSymbolConfiguration(config) else { return nil }
        let size = base.size
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: angle)
            ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        }
        base.draw(in: NSRect(origin: .zero, size: size))
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    /// Left-click toggles recording; right-click (or Control-click) shows the menu.
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { onToggleRecord?(); return }
        let wantsMenu = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if wantsMenu {
            showMenu()
        } else {
            onToggleRecord?()
        }
    }

    /// Pop the dropdown under the status item. Assigning `menu` then clicking is
    /// the AppKit-sanctioned way to get correct positioning and button highlight;
    /// we clear it again immediately so a subsequent left-click still toggles.
    private func showMenu() {
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func toggleRecord() { onToggleRecord?() }
    @objc private func quit() { onQuit?() }
    @objc private func openAccessibility() { onOpenAccessibility?() }
    @objc private func openInputMonitoring() { onOpenInputMonitoring?() }
    @objc private func openMicrophone() { onOpenMicrophone?() }
}
