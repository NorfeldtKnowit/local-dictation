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

    /// Rotating SF Symbol shown (in Naples yellow) while Whisper transcribes.
    private var spinnerTimer: Timer?
    private var spinnerAngle: CGFloat = 0
    private static let spinnerSymbol = "arrow.triangle.2.circlepath"

    var onQuit: (() -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onOpenInputMonitoring: (() -> Void)?
    var onOpenMicrophone: (() -> Void)?
    var onToggleRecord: (() -> Void)?

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
                symbol = "mic"
                title = "Idle — hold Right Option to dictate"
            case .listening:
                symbol = "mic.fill"
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
