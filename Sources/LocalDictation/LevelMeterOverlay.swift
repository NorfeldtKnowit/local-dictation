import AppKit

/// Pure display math for the level meter, split out so it's unit-testable.
enum LevelMeterMath {
    /// Map raw chunk RMS (speech typically ~0.02-0.3) to a 0-1 bar height.
    /// The soft power curve keeps quiet speech clearly visible while loud
    /// speech saturates instead of clipping wildly.
    static func normalize(_ rms: Float) -> Float {
        min(1, pow(max(0, rms) * 6, 0.7))
    }
}

/// Small floating "listening" HUD: a live Naples-yellow waveform of the mic
/// level while the push-to-talk key is held. Pure feedback — no interaction
/// (`ignoresMouseEvents`), no decisions. Fed by `AudioRecorder.onLevel`
/// (~50 RMS values/s), shown on `beginRecording`, hidden on `endRecording`.
///
/// Same non-activating panel recipe as the review HUD: the target app never
/// loses key focus, and NSApp.activate must never appear here.
final class LevelMeterOverlay {
    private final class MeterPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Scrolling bar graph of the most recent levels (newest on the right).
    private final class MeterView: NSView {
        /// The listening color — matches the menu-bar icon's Naples yellow.
        private static let naplesYellow = NSColor(srgbRed: 0xFA/255.0, green: 0xDA/255.0,
                                                  blue: 0x5E/255.0, alpha: 1.0)
        private static let barWidth: CGFloat = 4
        private static let barGap: CGFloat = 3

        private var levels: [Float]
        private let barCount: Int

        init(barCount: Int) {
            self.barCount = barCount
            self.levels = Array(repeating: 0, count: barCount)
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override var intrinsicContentSize: NSSize {
            NSSize(width: CGFloat(barCount) * (Self.barWidth + Self.barGap) - Self.barGap,
                   height: 32)
        }

        func reset() {
            levels = Array(repeating: 0, count: barCount)
            needsDisplay = true
        }

        func push(_ level: Float) {
            levels.removeFirst()
            levels.append(level)
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            Self.naplesYellow.setFill()
            let midY = bounds.midY
            for (index, level) in levels.enumerated() {
                let height = max(3, CGFloat(level) * (bounds.height - 4))
                let x = CGFloat(index) * (Self.barWidth + Self.barGap)
                let bar = NSRect(x: x, y: midY - height / 2,
                                 width: Self.barWidth, height: height)
                NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
            }
        }
    }

    private var panel: MeterPanel?
    private var meterView: MeterView?

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        meterView?.reset()

        let size = panel.contentView?.fittingSize ?? NSSize(width: 220, height: 52)
        let visible = ScreenLocator.activeScreen()?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        // Sits just below where the review HUD appears, so a dictation started
        // while a review is still open doesn't cover the candidates.
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.maxY - size.height - 64)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Feed one raw RMS value (called on the main thread; `AppDelegate` hops
    /// off the capture queue). Cheap no-op while hidden.
    func push(rms: Float) {
        guard panel?.isVisible == true else { return }
        meterView?.push(LevelMeterMath.normalize(rms))
    }

    private func makePanel() -> MeterPanel {
        let panel = MeterPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Same load-bearing flags as the review HUD (see its comments):
        // .statusBar level (no isFloatingPanel — its setter clobbers level),
        // .fullScreenAuxiliary or it's invisible over full-screen apps,
        // hidesOnDeactivate=false or the never-active accessory hides it.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
                                    .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true   // pure display, clicks fall through
        panel.animationBehavior = .utilityWindow

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active   // never-key window: avoid the inactive fallback
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        let meter = MeterView(barCount: 28)
        meter.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(meter)
        NSLayoutConstraint.activate([
            meter.topAnchor.constraint(equalTo: effect.topAnchor, constant: 10),
            meter.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -10),
            meter.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 14),
            meter.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -14),
        ])
        meterView = meter
        panel.contentView = effect
        return panel
    }
}
