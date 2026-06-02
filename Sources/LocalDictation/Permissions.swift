import AppKit
import AVFoundation

enum Permissions {
    static func requestMicrophone() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        Log.info("AVCaptureDevice mic status=\(statusName(status)) bundle=\(Bundle.main.bundleIdentifier ?? "<none>") path=\(Bundle.main.bundlePath)", "perm")
        switch status {
        case .authorized:
            return true
        case .denied:
            Log.error("mic permission was previously DENIED — open System Settings → Microphone and toggle on, or run: tccutil reset Microphone com.norfeldt.local-dictation", "perm")
            return false
        case .restricted:
            Log.error("mic permission is RESTRICTED by policy (MDM/parental controls)", "perm")
            return false
        case .notDetermined:
            Log.info("mic permission notDetermined — requesting now (this should show the system prompt)", "perm")
            let granted = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    cont.resume(returning: granted)
                }
            }
            Log.info("requestAccess returned granted=\(granted)", "perm")
            return granted
        @unknown default:
            Log.warn("mic status unknown: \(status.rawValue)", "perm")
            return false
        }
    }

    private static func statusName(_ s: AVAuthorizationStatus) -> String {
        switch s {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown(\(s.rawValue))"
        }
    }

    /// Accessibility / Input Monitoring share a single API surface for
    /// CGEventTap. `AXIsProcessTrustedWithOptions` triggers the system
    /// prompt and reports current status.
    @discardableResult
    static func ensureAccessibility(prompt: Bool) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }

    static func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }
}
