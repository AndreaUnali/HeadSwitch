import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    let settings = SettingsStore.shared
    let permissions = PermissionsManager()

    @Published var statusText = "Spento"
    @Published var isBusy = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Mostra nella barra dei menu yaw, pitch e schermo rilevato (per verificare la calibrazione).
    @Published var diagnostics = false {
        didSet {
            detector.setWantsSamples(diagnostics || isBusy)
            if !diagnostics { liveInfo = "" }
        }
    }
    @Published var liveInfo = ""

    private let detector: GazeZoneDetector
    private let camera: CameraManager
    private let vision: VisionProcessor
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var ready = false              // permessi concessi
    private var pausedBySystem = false
    private var screenCheckTask: Task<Void, Never>?
    private var lastLiveUpdate = Date.distantPast

    // Stato della misura di un punto di calibrazione
    private var collecting = false
    private var window: [(yaw: Double, pitch: Double)] = []
    private var stableFrames = 0
    private var acceptedPose: (yaw: Double, pitch: Double)?
    private var calibModel: CalibrationModel?

    // Selezione per finestra (beta)
    private var lastGaze: (zone: Int, point: CGPoint)?
    private var windowCandidate: Int?
    private var windowCandidateSince = Date.distantPast
    private var lastWindowCheck = Date.distantPast

    /// Un punto è acquisito quando yaw e pitch restano stabili per ~1 secondo.
    private static let stabilityWindow = 8
    private static let yawSpread = 4.0
    private static let pitchSpread = 5.0
    private static let stableFramesNeeded = 5

    private init() {
        let det = GazeZoneDetector()
        let vis = VisionProcessor(detector: det)
        let cam = CameraManager(targetFPS: 12)
        cam.onFrame = { buffer in vis.process(sampleBuffer: buffer) }
        detector = det; vision = vis; camera = cam
    }

    // MARK: - Avvio

    func start() {
        guard !started else { return }
        started = true
        NSApp.setActivationPolicy(.accessory)   // niente icona nel Dock

        // Primo avvio: attiva subito tutto (permessi + calibrazione guidata).
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            settings.trackingEnabled = true
        }

        detector.onZoneChange = { [weak self] zone in
            Task { @MainActor in self?.handleZone(zone) }
        }
        detector.onSample = { [weak self] yaw, pitch in
            Task { @MainActor in self?.receive(yaw: yaw, pitch: pitch) }
        }

        detector.onGaze = { [weak self] zone, u, v in
            Task { @MainActor in self?.receiveGaze(zone: zone, u: u, v: v) }
        }
        WindowManager.configure()

        syncConfig()
        settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.syncConfig() }
            .store(in: &cancellables)

        settings.$trackingEnabled
            .removeDuplicates()
            .sink { [weak self] on in Task { @MainActor in await self?.applyTracking(on) } }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.screensChanged() } }

        observeSystemPower()
    }

    // MARK: - Tracking on/off

    private func applyTracking(_ on: Bool) async {
        guard on else {
            ready = false
            updateCamera()
            statusText = "Spento"
            return
        }

        statusText = "Avvio…"
        guard await permissions.ensureCamera() else {
            settings.trackingEnabled = false
            statusText = "Webcam negata: abilitala in Impostazioni di Sistema"
            PermissionsManager.openCameraSettings()
            return
        }
        guard settings.trackingEnabled else { return }

        permissions.promptAccessibilityIfNeeded()
        if !AXIsProcessTrusted() {
            statusText = "Attiva HeadSwitch in Impostazioni → Accessibilità…"
            while !AXIsProcessTrusted() && settings.trackingEnabled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            permissions.refresh()
        }
        guard settings.trackingEnabled else { return }

        ready = true
        updateCamera()
        await autoCalibrateIfNeeded()
    }

    /// Accende la camera solo quando serve: tracking attivo, permessi ok, almeno 2 schermi, Mac non in sleep.
    private func updateCamera() {
        let shouldRun = settings.trackingEnabled && ready && !pausedBySystem && NSScreen.screens.count >= 2
        if shouldRun { camera.start() } else { camera.stop(); detector.reset() }
    }

    // MARK: - Configurazione schermi

    private func poseSamples(for screen: NSScreen, from calibration: [String: [[Double]]]) -> [PoseSample] {
        (calibration[String(screen.displayID)] ?? []).compactMap { row in
            row.count == 4 ? PoseSample(u: row[0], v: row[1], yaw: row[2], pitch: row[3]) : nil
        }
    }

    private func gazeConfig() -> GazeConfig {
        let dwell = settings.dwellMilliseconds / 1000
        let screens = NSScreen.leftToRight
        guard screens.count >= 2 else { return GazeConfig(dwell: dwell) }
        let samples = screens.map { poseSamples(for: $0, from: settings.calibration) }
        return GazeConfig.make(samples: samples, dwell: dwell, smoothingAlpha: 0.5) ?? GazeConfig(dwell: dwell)
    }

    private var isCalibrated: Bool { gazeConfig().isCalibrated }

    private func syncConfig() {
        detector.updateConfig(gazeConfig())
        detector.setWantsGaze(settings.windowSelection)
    }

    private func screensChanged() {
        syncConfig()
        updateCamera()
        screenCheckTask?.cancel()
        screenCheckTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // aspetta che la configurazione si assesti
            guard !Task.isCancelled, ready, settings.trackingEnabled, !isBusy else { return }
            await autoCalibrateIfNeeded()
        }
    }

    private func autoCalibrateIfNeeded() async {
        guard !isBusy else { return }
        guard NSScreen.screens.count >= 2 else {
            statusText = "Collega un secondo schermo per usarmi"
            return
        }
        if isCalibrated { statusText = "Attivo"; return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)   // lascia scaldare la camera
        await runCalibration()
    }

    // MARK: - Campioni dalla camera (calibrazione + diagnostica)

    private func receive(yaw: Double?, pitch: Double?) {
        if collecting {
            guard let yaw, let pitch else {
                window.removeAll(); stableFrames = 0; calibModel?.progress = 0
                return
            }
            window.append((yaw: yaw, pitch: pitch))
            if window.count > Self.stabilityWindow { window.removeFirst() }
            if window.count == Self.stabilityWindow {
                let ys = window.map { $0.yaw }
                let ps = window.map { $0.pitch }
                let stable = (ys.max()! - ys.min()!) <= Self.yawSpread && (ps.max()! - ps.min()!) <= Self.pitchSpread
                stableFrames = stable ? stableFrames + 1 : 0
            } else {
                stableFrames = 0
            }
            calibModel?.progress = min(1, Double(stableFrames) / Double(Self.stableFramesNeeded))
            if stableFrames >= Self.stableFramesNeeded, acceptedPose == nil {
                acceptedPose = medianPose(window)
            }
            return
        }
        if diagnostics { updateLive(yaw: yaw, pitch: pitch) }
    }

    private func updateLive(yaw: Double?, pitch: Double?) {
        guard Date().timeIntervalSince(lastLiveUpdate) > 0.25 else { return }
        lastLiveUpdate = Date()
        guard let yaw, let pitch else { liveInfo = "no volto"; return }
        if let best = gazeConfig().nearest(yaw: yaw, pitch: pitch) {
            liveInfo = String(format: "%+.0f° %+.0f° → %d", yaw, pitch, best.index + 1)
        } else {
            liveInfo = String(format: "%+.0f° %+.0f°", yaw, pitch)
        }
    }

    // MARK: - Calibrazione guidata

    /// Punti da guardare su ogni schermo (u: sinistra→destra, v: alto→basso), in un ordine comodo da seguire.
    private func calibrationGrid() -> [(u: Double, v: Double)] {
        if settings.calibrationPointCount >= 9 {
            return [(0.12, 0.15), (0.5, 0.15), (0.88, 0.15),
                    (0.88, 0.5), (0.5, 0.5), (0.12, 0.5),
                    (0.12, 0.85), (0.5, 0.85), (0.88, 0.85)]
        }
        return [(0.12, 0.5), (0.5, 0.5), (0.88, 0.5), (0.5, 0.15), (0.5, 0.85)]
    }

    func requestCalibration() {
        guard !isBusy, ready else { return }
        Task { await runCalibration() }
    }

    private func runCalibration() async {
        let screens = NSScreen.leftToRight
        guard screens.count >= 2 else { statusText = "Collega un secondo schermo per calibrare"; return }
        guard !isBusy else { return }

        isBusy = true
        statusText = "Calibrazione in corso…"
        detector.setSuppressed(true)
        detector.setWantsSamples(true)
        detector.reset()
        camera.start()
        defer {
            isBusy = false
            collecting = false
            calibModel = nil
            detector.setWantsSamples(diagnostics)
            detector.setSuppressed(false)
            detector.reset()
        }

        let grid = calibrationGrid()
        var result: [String: [[Double]]] = [:]
        for (i, screen) in screens.enumerated() {
            var rows: [[Double]] = []
            for (j, spot) in grid.enumerated() {
                guard settings.trackingEnabled else { return }
                let panel = CalibrationPanel(screen: screen, u: spot.u, v: spot.v,
                                             screenIndex: i + 1, screenTotal: screens.count,
                                             screenName: screen.localizedName,
                                             pointIndex: j + 1, pointTotal: grid.count)
                panel.show()
                try? await Task.sleep(nanoseconds: 700_000_000)      // tempo minimo per girare la testa

                // Aspetta che la testa sia ferma (~1 s), poi prendi la misura.
                window.removeAll(); stableFrames = 0; acceptedPose = nil
                calibModel = panel.model
                collecting = true
                var waited = 0.0
                while acceptedPose == nil && waited < 10 && settings.trackingEnabled {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    waited += 0.05
                }
                // Se non si è mai fermata del tutto, usa comunque le ultime misure (meglio di fallire).
                if acceptedPose == nil, window.count >= Self.stabilityWindow {
                    acceptedPose = medianPose(window)
                }
                collecting = false
                calibModel = nil
                panel.close()

                guard settings.trackingEnabled else { return }
                guard let pose = acceptedPose else {
                    fail("Non riesco a vedere il tuo volto. Controlla che la webcam non sia coperta e che ci sia luce, poi scegli «Ricalibra schermi».")
                    return
                }
                rows.append([spot.u, spot.v, pose.yaw, pose.pitch])
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            result[String(screen.displayID)] = rows
        }

        let samples = screens.map { poseSamples(for: $0, from: result) }
        guard let config = GazeConfig.make(samples: samples, dwell: 0.4, smoothingAlpha: 0.5) else {
            fail("Gli angoli misurati per gli schermi sono troppo simili. Gira bene la testa verso ogni punto e riprova da «Ricalibra schermi».")
            return
        }

        settings.calibration = result
        syncConfig()
        statusText = String(format: "Attivo · calibrato ✓ (errore ~%.1f°)", config.fitError)
    }

    private func fail(_ text: String) {
        statusText = "Calibrazione non riuscita"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Calibrazione non riuscita"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        return s[s.count / 2]
    }

    private func medianPose(_ w: [(yaw: Double, pitch: Double)]) -> (yaw: Double, pitch: Double) {
        (yaw: median(w.map { $0.yaw }), pitch: median(w.map { $0.pitch }))
    }

    // MARK: - Cambio di focus

    private func handleZone(_ zone: Int) {
        let screens = NSScreen.leftToRight
        guard zone < screens.count, !isBusy else { return }
        statusText = "Attivo · guardi lo schermo \(zone + 1)"
        guard NSEvent.pressedMouseButtons == 0 else { return }   // non interrompere un trascinamento
        let screen = screens[zone]

        var focused: FocusedWindow?
        if settings.windowSelection, let g = lastGaze, g.zone == zone,
           let target = WindowManager.windowUnder(g.point) {
            focused = WindowManager.focus(target)                // la finestra sotto lo sguardo
        }
        if focused == nil { focused = WindowManager.focusTopWindow(on: screen) }
        if settings.glowEnabled { FocusGlow.shared.flash(window: focused, screen: screen) }
    }

    // MARK: - Selezione per finestra (beta)

    private func receiveGaze(zone: Int, u: Double, v: Double) {
        let screens = NSScreen.leftToRight
        guard zone < screens.count else { return }
        let d = CGDisplayBounds(screens[zone].displayID)        // coordinate CG, y verso il basso
        let point = CGPoint(x: d.minX + u * d.width, y: d.minY + v * d.height)
        lastGaze = (zone, point)

        guard settings.windowSelection, ready, !isBusy else { return }
        let now = Date()
        guard now.timeIntervalSince(lastWindowCheck) > 0.1 else { return }
        lastWindowCheck = now
        updateWindowFocus(at: point, on: screens[zone])
    }

    private func updateWindowFocus(at point: CGPoint, on screen: NSScreen) {
        guard let target = WindowManager.windowUnder(point) else { windowCandidate = nil; return }

        // Stai ancora guardando la finestra già a fuoco (con un po' di tolleranza): non fare nulla.
        if let f = WindowManager.focusedWindowBounds() {
            let margin = max(30.0, 0.04 * CGDisplayBounds(screen.displayID).width)
            if f.insetBy(dx: -margin, dy: -margin).contains(point) || WindowManager.sameFrame(f, target.bounds) {
                windowCandidate = nil
                return
            }
        }

        // Nuova finestra: deve restare sotto lo sguardo per `dwell` secondi.
        if windowCandidate != target.windowNumber {
            windowCandidate = target.windowNumber
            windowCandidateSince = Date()
            return
        }
        guard Date().timeIntervalSince(windowCandidateSince) >= settings.dwellMilliseconds / 1000 else { return }
        guard keyboardIdle else { return }                       // stai scrivendo: aspetta
        guard NSEvent.pressedMouseButtons == 0 else { return }

        windowCandidate = nil
        if let focused = WindowManager.focus(target), settings.glowEnabled {
            FocusGlow.shared.flash(window: focused, screen: screen)
        }
    }

    /// Nessun tasto premuto negli ultimi ~0,8 s: evita di spostare il focus mentre scrivi.
    private var keyboardIdle: Bool {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) > 0.8
    }

    // MARK: - Apri al login

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            statusText = "Impossibile impostare l'apertura al login"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - Risparmio energetico

    private func observeSystemPower() {
        let nc = NSWorkspace.shared.notificationCenter
        let pauseNames: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        let resumeNames: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
        ]
        for n in pauseNames {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pausedBySystem = true; self?.updateCamera() }
            }
        }
        for n in resumeNames {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pausedBySystem = false; self?.updateCamera() }
            }
        }
    }
}
