import AppKit
import CoreGraphics

/// Inserts text into the focused application by stashing it on the
/// pasteboard, posting a synthetic Cmd+V, and restoring the original
/// pasteboard contents shortly afterwards. `copy(_:)` is the alternative
/// delivery: the text STAYS on the clipboard (no Cmd+V, no restore) for
/// the user to paste wherever and whenever they want.
enum TextInjector {
    private static let kVKCommand: CGKeyCode = 0x37
    private static let kVKANSI_V: CGKeyCode = 0x09

    /// Copy-only delivery: replace the clipboard with the transcript and leave
    /// it there. Deliberately no snapshot/restore — restoring would immediately
    /// overwrite the very text the user asked to keep on the clipboard.
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        // Prefix logged so a transcript clobbered by the next copy staging is
        // still recoverable from the log (mirrors the paste-path logging).
        Log.info("copy \(text.count) chars to clipboard (copy-instead-of-paste mode): \(text.prefix(120))", "inject")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func paste(_ text: String) {
        guard !text.isEmpty else { return }
        let frontApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "<unknown>"
        let trusted = AXIsProcessTrusted()
        Log.info("paste \(text.count) chars → \(frontApp), ax-trusted=\(trusted)", "inject")
        if !trusted {
            Log.error("Accessibility NOT trusted at paste time — Cmd+V will be silently dropped. Re-grant in System Settings (and re-sign the binary after each rebuild).", "inject")
        }

        let pb = NSPasteboard.general
        let saved = snapshot(of: pb)

        pb.clearContents()
        pb.setString(text, forType: .string)

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            restore(saved, to: pb)
            Log.debug("pasteboard restored", "inject")
        }
    }

    private static func postCommandV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: kVKCommand, keyDown: true)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: kVKANSI_V, keyDown: true)
        vDown?.flags = .maskCommand
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: kVKANSI_V, keyDown: false)
        vUp?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: kVKCommand, keyDown: false)

        for ev in [cmdDown, vDown, vUp, cmdUp] {
            ev?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Pasteboard snapshot / restore

    private struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func snapshot(of pb: NSPasteboard) -> Snapshot {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            items.append(dict)
        }
        return Snapshot(items: items)
    }

    private static func restore(_ snap: Snapshot, to pb: NSPasteboard) {
        pb.clearContents()
        guard !snap.items.isEmpty else { return }
        let newItems = snap.items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            return item
        }
        pb.writeObjects(newItems)
    }
}
