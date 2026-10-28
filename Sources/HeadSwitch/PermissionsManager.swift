import AppKit
import AVFoundation
import ApplicationServices

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()

    func refresh() {
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func ensureCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            refresh(); return true
        case .notDetermined:
            let ok = await AVCaptureDevice.requestAccess(for: .video)
            refresh(); return ok
        default:
            refresh(); return false
        }
    }

    /// Mostra il dialogo di sistema per l'Accessibilità se l'app non è ancora autorizzata.
    func promptAccessibilityIfNeeded() {
        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refresh()
    }

    static func openCameraSettings() { open("Privacy_Camera") }
    static func openAccessibilitySettings() { open("Privacy_Accessibility") }

    private static func open(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
