import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var trackingEnabled: Bool {
        didSet { UserDefaults.standard.set(trackingEnabled, forKey: "trackingEnabled") }
    }
    /// Quanto devi restare a guardare uno schermo prima del cambio di focus.
    @Published var dwellMilliseconds: Double {
        didSet { UserDefaults.standard.set(dwellMilliseconds, forKey: "dwellMilliseconds") }
    }
    /// Luce di contorno sulla finestra quando cambia il focus.
    @Published var glowEnabled: Bool {
        didSet { UserDefaults.standard.set(glowEnabled, forKey: "glowEnabled") }
    }
    /// Yaw misurati per ogni schermo (display ID -> punti da sinistra a destra).
    @Published var calibration: [String: [Double]] {
        didSet { UserDefaults.standard.set(calibration, forKey: "calibrationPoints") }
    }

    private init() {
        let d = UserDefaults.standard
        trackingEnabled   = d.object(forKey: "trackingEnabled") as? Bool ?? false
        dwellMilliseconds = d.object(forKey: "dwellMilliseconds") as? Double ?? 400
        glowEnabled       = d.object(forKey: "glowEnabled") as? Bool ?? true
        calibration       = d.dictionary(forKey: "calibrationPoints") as? [String: [Double]] ?? [:]
    }
}
