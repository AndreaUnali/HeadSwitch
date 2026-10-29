import Foundation

/// Un punto di calibrazione: posizione normalizzata sullo schermo
/// (u: 0 = bordo sinistro … 1 = destro, v: 0 = alto … 1 = basso) e posa della testa misurata (gradi).
struct PoseSample: Sendable {
    var u: Double
    var v: Double
    var yaw: Double
    var pitch: Double
}

/// Modello di UNO schermo: posa(u, v) = A·[u, v] + t, ricavato ai minimi quadrati dai suoi punti di calibrazione.
/// Descrive quale regione di pose (yaw, pitch) corrisponde a "sto guardando questo schermo".
struct ScreenPoseModel: Sendable {
    var yu = 0.0, yv = 0.0, y0 = 0.0     // yaw   = yu·u + yv·v + y0
    var pu = 0.0, pv = 0.0, p0 = 0.0     // pitch = pu·u + pv·v + p0

    func yaw(_ u: Double, _ v: Double) -> Double { yu * u + yv * v + y0 }
    func pitch(_ u: Double, _ v: Double) -> Double { pu * u + pv * v + p0 }
    var centerYaw: Double { yaw(0.5, 0.5) }
    var centerPitch: Double { pitch(0.5, 0.5) }

    static func fit(_ samples: [PoseSample]) -> ScreenPoseModel? {
        guard samples.count >= 4 else { return nil }
        var m = [[Double]](repeating: [0, 0, 0], count: 3)
        var by = [0.0, 0.0, 0.0]
        var bp = [0.0, 0.0, 0.0]
        for s in samples {
            let f = [s.u, s.v, 1.0]
            for i in 0..<3 {
                for j in 0..<3 { m[i][j] += f[i] * f[j] }
                by[i] += f[i] * s.yaw
                bp[i] += f[i] * s.pitch
            }
        }
        m[0][0] += 1e-3
        m[1][1] += 1e-3
        guard let ys = solve3(m, by), let ps = solve3(m, bp) else { return nil }
        return ScreenPoseModel(yu: ys[0], yv: ys[1], y0: ys[2], pu: ps[0], pv: ps[1], p0: ps[2])
    }

    /// Distanza (gradi) tra una posa e la regione dello schermo: 0 = stai guardando dentro lo schermo.
    /// Cerca il punto (u, v) dello schermo più vicino alla posa; la regolarizzazione verso il centro
    /// evita instabilità quando una direzione (tipicamente il pitch) è poco informativa.
    func distance(yaw py: Double, pitch pp: Double, pitchWeight w: Double) -> Double {
        let lambda = 25.0
        let a00 = yu, a01 = yv
        let a10 = pu * w, a11 = pv * w
        let r0 = py - y0
        let r1 = (pp - p0) * w
        let m00 = a00 * a00 + a10 * a10 + lambda
        let m01 = a00 * a01 + a10 * a11
        let m11 = a01 * a01 + a11 * a11 + lambda
        let b0 = a00 * r0 + a10 * r1 + lambda * 0.5
        let b1 = a01 * r0 + a11 * r1 + lambda * 0.5
        let det = m00 * m11 - m01 * m01
        var u = (b0 * m11 - b1 * m01) / det
        var v = (m00 * b1 - m01 * b0) / det
        u = min(max(u, 0), 1)
        v = min(max(v, 0), 1)
        let ey = py - yaw(u, v)
        let ep = (pp - pitch(u, v)) * w
        return (ey * ey + ep * ep).squareRoot()
    }
}

private func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
    var m = a
    var x = b
    let n = 3
    for c in 0..<n {
        var piv = c
        for r in c..<n where abs(m[r][c]) > abs(m[piv][c]) { piv = r }
        guard abs(m[piv][c]) > 1e-9 else { return nil }
        m.swapAt(c, piv)
        x.swapAt(c, piv)
        for r in (c + 1)..<n {
            let f = m[r][c] / m[c][c]
            for k in c..<n { m[r][k] -= f * m[c][k] }
            x[r] -= f * x[c]
        }
    }
    var res = [Double](repeating: 0, count: n)
    for r in stride(from: n - 1, through: 0, by: -1) {
        var s = x[r]
        for k in (r + 1)..<n { s -= m[r][k] * res[k] }
        res[r] = s / m[r][r]
    }
    return res
}

struct GazeConfig: Sendable {
    /// Un modello per schermo, nello stesso ordine di `NSScreen.leftToRight`.
    var models: [ScreenPoseModel] = []
    /// 0...1: quanto fidarsi del pitch. Se il pitch varia poco tra i punti calibrati è solo rumore e viene ignorato
    /// (schermi alla stessa altezza); con schermi sfalsati in verticale/diagonale sale a 1.
    var pitchWeight: Double = 0
    /// Per cambiare schermo il nuovo deve essere più vicino del corrente di almeno questi gradi (isteresi).
    var margin: Double = 2.5
    /// Oltre questa distanza da tutti gli schermi stai guardando altrove (tastiera, telefono…): nessun cambio.
    var awayDistance: Double = 18
    /// Errore medio (gradi) del modello sui punti di calibrazione: indicatore della qualità.
    var fitError: Double = 0
    var dwell: TimeInterval = 0.4
    var smoothingAlpha: Double = 0.5

    var isCalibrated: Bool { models.count >= 2 }

    func nearest(yaw: Double, pitch: Double) -> (index: Int, distance: Double)? {
        var best: (index: Int, distance: Double)?
        for (i, m) in models.enumerated() {
            let d = m.distance(yaw: yaw, pitch: pitch, pitchWeight: pitchWeight)
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best
    }

    /// `samples`: i punti di calibrazione di ogni schermo, nell'ordine di `NSScreen.leftToRight`.
    /// Ritorna nil se le misure non sono coerenti (punti mancanti o schermi non distinguibili).
    static func make(samples: [[PoseSample]], dwell: TimeInterval, smoothingAlpha: Double) -> GazeConfig? {
        guard samples.count >= 2, samples.allSatisfy({ $0.count >= 4 }) else { return nil }
        let models = samples.compactMap { ScreenPoseModel.fit($0) }
        guard models.count == samples.count else { return nil }

        let all = samples.flatMap { $0 }
        let pitches = all.map { $0.pitch }
        let pitchSpan = (pitches.max() ?? 0) - (pitches.min() ?? 0)
        let wp = min(1, max(0, (pitchSpan - 4) / 8))     // < 4° = rumore, > 12° = affidabile

        for i in 0..<models.count {
            for j in (i + 1)..<models.count {
                let dy = models[i].centerYaw - models[j].centerYaw
                let dp = (models[i].centerPitch - models[j].centerPitch) * wp
                guard (dy * dy + dp * dp).squareRoot() >= 6 else { return nil }   // schermi non distinguibili
            }
        }

        var sse = 0.0
        for (m, ss) in zip(models, samples) {
            for s in ss {
                let ey = s.yaw - m.yaw(s.u, s.v)
                let ep = (s.pitch - m.pitch(s.u, s.v)) * wp
                sse += ey * ey + ep * ep
            }
        }
        let rms = (sse / Double(all.count)).squareRoot()
        return GazeConfig(models: models, pitchWeight: wp, fitError: rms, dwell: dwell, smoothingAlpha: smoothingAlpha)
    }
}

/// Capisce quale schermo stai guardando confrontando la posa (yaw, pitch) con il modello di ogni schermo.
/// Cambia schermo solo se il nuovo è nettamente più vicino (isteresi) e resti lì per `dwell` secondi.
/// Funziona con qualsiasi disposizione (affiancati, sopra/sotto, in diagonale): la disposizione è nei dati.
final class GazeZoneDetector: @unchecked Sendable {
    var onZoneChange: (@Sendable (Int) -> Void)?
    /// Posa smussata (yaw, pitch in gradi). nil = nessun volto.
    var onSample: (@Sendable (Double?, Double?) -> Void)?

    private let lock = NSLock()
    private var config = GazeConfig()
    private var wantsSamples = false
    private var suppressed = false
    private var smoothedYaw: Double?
    private var smoothedPitch: Double?
    private var current: Int?
    private var candidate: Int?
    private var candidateSince: TimeInterval = 0

    func updateConfig(_ new: GazeConfig) { lock.lock(); config = new; lock.unlock() }
    func setWantsSamples(_ on: Bool) { lock.lock(); wantsSamples = on; lock.unlock() }
    func setSuppressed(_ on: Bool) { lock.lock(); suppressed = on; lock.unlock() }
    func reset() {
        lock.lock()
        smoothedYaw = nil; smoothedPitch = nil; current = nil; candidate = nil
        lock.unlock()
    }

    /// `yawRadians == nil` = nessun volto (es. giri la testa oltre ciò che Vision riesce a seguire).
    func process(yawRadians: Double?, pitchRadians: Double?, at time: TimeInterval) {
        var changed: Int?
        var outYaw: Double?
        var outPitch: Double?

        lock.lock()
        let c = config
        let sampling = wantsSamples
        if let yawRadians {
            let yawDeg = yawRadians * 180 / .pi
            let pitchDeg = pitchRadians.map { $0 * 180 / .pi } ?? smoothedPitch ?? 0
            let a = c.smoothingAlpha
            let ys = smoothedYaw.map { a * yawDeg + (1 - a) * $0 } ?? yawDeg
            let ps = smoothedPitch.map { a * pitchDeg + (1 - a) * $0 } ?? pitchDeg
            smoothedYaw = ys
            smoothedPitch = ps
            outYaw = ys
            outPitch = ps
            if !suppressed, c.isCalibrated {
                changed = classify(yaw: ys, pitch: ps, time: time, config: c)
            }
        } else {
            smoothedYaw = nil
            smoothedPitch = nil
            candidate = nil      // lo schermo corrente resta quello: niente azioni se perdi il volto
        }
        lock.unlock()

        if let changed { onZoneChange?(changed) }
        if sampling { onSample?(outYaw, outPitch) }
    }

    // Da chiamare con il lock preso.
    private func classify(yaw: Double, pitch: Double, time: TimeInterval, config c: GazeConfig) -> Int? {
        guard let best = c.nearest(yaw: yaw, pitch: pitch) else { return nil }
        guard let cur = current, cur < c.models.count else {
            current = best.index; candidate = nil      // prima misura: nessuna azione
            return nil
        }
        if best.index == cur || best.distance > c.awayDistance { candidate = nil; return nil }

        let dCur = c.models[cur].distance(yaw: yaw, pitch: pitch, pitchWeight: c.pitchWeight)
        guard best.distance + c.margin < dCur else { candidate = nil; return nil }

        if candidate != best.index { candidate = best.index; candidateSince = time; return nil }
        if time - candidateSince >= c.dwell {
            current = best.index; candidate = nil
            return best.index
        }
        return nil
    }
}
