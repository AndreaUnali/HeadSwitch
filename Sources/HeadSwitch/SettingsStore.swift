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
    /// Punti di calibrazione per schermo: 5 (veloce) o 9 (preciso).
    @Published var calibrationPointCount: Int {
        didSet { UserDefaults.standard.set(calibrationPointCount, forKey: "calibrationPointCount") }
    }
    /// Punti di calibrazione per ogni schermo (display ID -> righe [u, v, yaw, pitch]).
    @Published var calibration: [String: [[Double]]] {
        didSet { UserDefaults.standard.set(calibration, forKey: "calibrationSamples") }
    }

    private init() {
        let d = UserDefaults.standard
        trackingEnabled       = d.object(forKey: "trackingEnabled") as? Bool ?? false
        dwellMilliseconds     = d.object(forKey: "dwellMilliseconds") as? Double ?? 400
        glowEnabled           = d.object(forKey: "glowEnabled") as? Bool ?? true
        calibrationPointCount = d.object(forKey: "calibrationPointCount") as? Int ?? 5
        calibration           = d.dictionary(forKey: "calibrationSamples") as? [String: [[Double]]] ?? [:]
    }
}
