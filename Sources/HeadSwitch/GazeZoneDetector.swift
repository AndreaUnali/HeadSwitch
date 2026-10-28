import Foundation

struct GazeConfig: Sendable {
    /// +1 / -1: orienta lo yaw in modo che cresca da sinistra a destra (dipende dalla webcam, si ricava dalla calibrazione).
    var sign: Double = 1
    /// Confini tra schermi adiacenti nello spazio orientato: N schermi -> N-1 valori crescenti.
    var boundaries: [Double] = []
    /// Quanto oltre il confine devi andare prima che il cambio venga preso in considerazione (gradi).
    var hysteresis: Double = 2
    var dwell: TimeInterval = 0.4
    var smoothingAlpha: Double = 0.5

    var isCalibrated: Bool { !boundaries.isEmpty }

    /// Costruisce la configurazione dai punti calibrati: per ogni schermo (da sinistra a destra)
    /// la lista di yaw misurati guardando punti diversi dello schermo (sinistra, centro, destra).
    /// Il confine tra due schermi sta a metà tra il bordo interno dell'uno e quello dell'altro.
    /// Ritorna nil se le misure non sono coerenti (schermi non ordinati o angoli troppo vicini).
    static func make(points: [[Double]], dwell: TimeInterval, smoothingAlpha: Double) -> GazeConfig? {
        guard points.count >= 2, points.allSatisfy({ !$0.isEmpty }) else { return nil }
        let centersRaw = points.map { $0.reduce(0, +) / Double($0.count) }
        guard let first = centersRaw.first, let last = centersRaw.last, first != last else { return nil }
        let sign: Double = last > first ? 1 : -1

        let centers = centersRaw.map { $0 * sign }
        let oriented = points.map { $0.map { $0 * sign }.sorted() }

        var minGap = Double.infinity
        for i in 1..<centers.count {
            let gap = centers[i] - centers[i - 1]
            guard gap >= 5 else { return nil }      // schermi non distinguibili o in ordine sbagliato
            minGap = min(minGap, gap)
        }

        // Confine = metà tra i bordi interni dei due schermi, ma mai fuori dal tratto centrale (25%-75%)
        // dell'intervallo tra i due centri: una misura sporca sui bordi non può spostarlo troppo.
        var boundaries: [Double] = []
        for i in 0..<(oriented.count - 1) {
            let g = centers[i + 1] - centers[i]
            let edges = ((oriented[i].last ?? centers[i]) + (oriented[i + 1].first ?? centers[i + 1])) / 2
            boundaries.append(min(max(edges, centers[i] + 0.25 * g), centers[i + 1] - 0.25 * g))
        }
        let hysteresis = min(6, max(2, 0.12 * minGap))
        return GazeConfig(sign: sign, boundaries: boundaries, hysteresis: hysteresis,
                          dwell: dwell, smoothingAlpha: smoothingAlpha)
    }
}

/// Capisce quale schermo stai guardando confrontando lo yaw (smussato) con i confini calibrati.
/// Cambia zona solo se superi il confine di un margine (isteresi) e resti lì per `dwell` secondi.
/// Funziona con qualsiasi numero di schermi affiancati in orizzontale.
final class GazeZoneDetector: @unchecked Sendable {
    var onZoneChange: (@Sendable (Int) -> Void)?
    /// Yaw grezzo smussato (usato dalla calibrazione). nil = nessun volto.
    var onSample: (@Sendable (Double?) -> Void)?

    private let lock = NSLock()
    private var config = GazeConfig()
    private var wantsSamples = false
    private var suppressed = false
    private var smoothed: Double?
    private var current: Int?
    private var candidate: Int?
    private var candidateSince: TimeInterval = 0

    func updateConfig(_ new: GazeConfig) { lock.lock(); config = new; lock.unlock() }
    func setWantsSamples(_ on: Bool) { lock.lock(); wantsSamples = on; lock.unlock() }
    func setSuppressed(_ on: Bool) { lock.lock(); suppressed = on; lock.unlock() }
    func reset() {
        lock.lock(); smoothed = nil; current = nil; candidate = nil; lock.unlock()
    }

    /// `yawRadians == nil` = nessun volto (es. giri la testa oltre ciò che Vision riesce a seguire).
    func process(yawRadians: Double?, at time: TimeInterval) {
        var changed: Int?
        var outRaw: Double?

        lock.lock()
        let c = config
        let sampling = wantsSamples
        if let yawRadians {
            let deg = yawRadians * 180 / .pi
            let raw = smoothed.map { c.smoothingAlpha * deg + (1 - c.smoothingAlpha) * $0 } ?? deg
            smoothed = raw
            outRaw = raw
            if !suppressed, c.isCalibrated {
                changed = classify(raw, time, c)
            }
        } else {
            smoothed = nil
            candidate = nil      // la zona corrente resta quella: niente azioni se perdi il volto
        }
        lock.unlock()

        if let changed { onZoneChange?(changed) }
        if sampling { onSample?(outRaw) }
    }

    // Da chiamare con il lock preso.
    private func classify(_ raw: Double, _ time: TimeInterval, _ c: GazeConfig) -> Int? {
        let v = raw * c.sign
        let b = c.boundaries
        var z = 0
        while z < b.count && v > b[z] { z += 1 }          // zona "nuda", senza isteresi

        guard let cur = current, cur <= b.count else {
            current = z; candidate = nil                   // prima misura: nessuna azione
            return nil
        }
        if z == cur { candidate = nil; return nil }

        let passes = z > cur ? v > b[z - 1] + c.hysteresis : v < b[z] - c.hysteresis
        guard passes else { candidate = nil; return nil }

        if candidate != z { candidate = z; candidateSince = time; return nil }
        if time - candidateSince >= c.dwell {
            current = z; candidate = nil
            return z
        }
        return nil
    }
}
