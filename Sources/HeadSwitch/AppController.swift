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
    /// Mostra nella barra dei menu l'angolo misurato e lo schermo rilevato (per verificare la calibrazione).
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
    private var window: [Double] = []
    private var stableFrames = 0
    private var acceptedYaw: Double?
    private var calibModel: CalibrationModel?

    /// Posizioni orizzontali (frazione della larghezza) dei punti da guardare su ogni schermo.
    private static let calibrationFractions: [Double] = [0.12, 0.5, 0.88]
    /// Un punto è acquisito quando lo yaw resta entro `stabilitySpread` gradi per ~1 secondo.
    private static let stabilityWindow = 8
    private static let stabilitySpread = 3.0
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
        detector.onSample = { [weak self] raw in
            Task { @MainActor in self?.receive(raw: raw) }
        }

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

    private func gazeConfig() -> GazeConfig {
        let dwell = settings.dwellMilliseconds / 1000
        let screens = NSScreen.leftToRight
        guard screens.count >= 2 else { return GazeConfig(dwell: dwell) }
        let points = screens.map { settings.calibration[String($0.displayID)] ?? [] }
        return GazeConfig.make(points: points, dwell: dwell, smoothingAlpha: 0.5) ?? GazeConfig(dwell: dwell)
    }

    private var isCalibrated: Bool { gazeConfig().isCalibrated }

    private func syncConfig() { detector.updateConfig(gazeConfig()) }

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

    private func receive(raw: Double?) {
        if collecting {
            guard let raw else {
                window.removeAll(); stableFrames = 0; calibModel?.progress = 0
                return
            }
            window.append(raw)
            if window.count > Self.stabilityWindow { window.removeFirst() }
            if window.count == Self.stabilityWindow,
               let lo = window.min(), let hi = window.max(), hi - lo <= Self.stabilitySpread {
                stableFrames += 1
            } else {
                stableFrames = 0
            }
            calibModel?.progress = min(1, Double(stableFrames) / Double(Self.stableFramesNeeded))
            if stableFrames >= Self.stableFramesNeeded, acceptedYaw == nil {
                acceptedYaw = median(window)
            }
            return
        }
        if diagnostics { updateLive(raw) }
    }

    private func updateLive(_ raw: Double?) {
        guard Date().timeIntervalSince(lastLiveUpdate) > 0.25 else { return }
        lastLiveUpdate = Date()
        guard let raw else { liveInfo = "no volto"; return }
        let c = gazeConfig()
        guard c.isCalibrated else { liveInfo = String(format: "%+.0f°", raw); return }
        let v = raw * c.sign
        var z = 0
        while z < c.boundaries.count && v > c.boundaries[z] { z += 1 }
        liveInfo = String(format: "%+.0f° → %d", v, z + 1)
    }

    // MARK: - Calibrazione guidata

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

        var result: [String: [Double]] = [:]
        for (i, screen) in screens.enumerated() {
            var points: [Double] = []
            for (j, fraction) in Self.calibrationFractions.enumerated() {
                guard settings.trackingEnabled else { return }
                let panel = CalibrationPanel(screen: screen, fraction: fraction,
                                             screenIndex: i + 1, screenTotal: screens.count,
                                             pointIndex: j + 1, pointTotal: Self.calibrationFractions.count)
                panel.show()
                try? await Task.sleep(nanoseconds: 700_000_000)      // tempo minimo per girare la testa

                // Aspetta che la testa sia ferma (~1 s entro 3°), poi prendi la misura.
                window.removeAll(); stableFrames = 0; acceptedYaw = nil
                calibModel = panel.model
                collecting = true
                var waited = 0.0
                while acceptedYaw == nil && waited < 10 && settings.trackingEnabled {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    waited += 0.05
                }
                collecting = false
                calibModel = nil
                panel.close()

                guard settings.trackingEnabled else { return }
                guard let yaw = acceptedYaw else {
                    fail("Non riesco a misurare una posizione stabile. Guarda il punto girando la testa, tienila ferma finché l'anello non si completa, e controlla che il volto sia ben illuminato. Poi scegli «Ricalibra schermi».")
                    return
                }
                points.append(yaw)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            result[String(screen.displayID)] = points
        }

        let ordered = screens.map { result[String($0.displayID)] ?? [] }
        guard GazeConfig.make(points: ordered, dwell: 0.4, smoothingAlpha: 0.5) != nil else {
            fail("Gli angoli misurati per i due schermi sono troppo simili o in ordine strano. Gira bene la testa verso ogni punto e riprova da «Ricalibra schermi».")
            return
        }

        settings.calibration = result
        syncConfig()
        let centers = ordered.map { String(format: "%+.0f°", $0.reduce(0, +) / Double($0.count)) }
        statusText = "Attivo · calibrato ✓ (\(centers.joined(separator: "  ")))"
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

    // MARK: - Cambio di focus

    private func handleZone(_ zone: Int) {
        let screens = NSScreen.leftToRight
        guard zone < screens.count, !isBusy else { return }
        statusText = "Attivo · guardi lo schermo \(zone + 1)"
        guard NSEvent.pressedMouseButtons == 0 else { return }   // non interrompere un trascinamento
        let screen = screens[zone]
        let focused = WindowManager.focusTopWindow(on: screen)
        if settings.glowEnabled { FocusGlow.shared.flash(window: focused, screen: screen) }
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
