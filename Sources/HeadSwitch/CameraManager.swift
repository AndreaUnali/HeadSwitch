import AVFoundation

/// Cattura a bassa risoluzione (VGA) e a frame rate ridotto: a Vision basta poco per stimare lo yaw
/// e meno pixel/frame = meno CPU, meno calore, meno batteria.
final class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let targetFPS: Double
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "headswitch.camera.session", qos: .utility)
    private let frameQueue = DispatchQueue(label: "headswitch.camera.frames", qos: .utility)
    private var isConfigured = false
    private var lastProcessed: TimeInterval = 0   // toccato solo da frameQueue

    init(targetFPS: Double) {
        self.targetFPS = targetFPS
        super.init()
    }

    func start() {
        sessionQueue.async { [self] in
            guard configureIfNeeded() else { return }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
        frameQueue.async { [self] in lastProcessed = 0 }
    }

    // MARK: - Configurazione

    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }

        // Preferisci la camera integrata (evita iPhone/Continuity Camera come default).
        let builtIn = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified
        ).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        let nv12 = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if output.availableVideoPixelFormatTypes.contains(nv12) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: nv12]
        }
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()

        limitFrameRate(of: device)
        isConfigured = true
        return true
    }

    private func limitFrameRate(of device: AVCaptureDevice) {
        // Impostare una durata non supportata solleva un'eccezione ObjC: controlla prima.
        let supported = device.activeFormat.videoSupportedFrameRateRanges
            .contains { $0.minFrameRate <= targetFPS && targetFPS <= $0.maxFrameRate }
        guard supported, (try? device.lockForConfiguration()) != nil else { return }
        let d = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
        device.activeVideoMinFrameDuration = d
        device.activeVideoMaxFrameDuration = d
        device.unlockForConfiguration()
    }

    // MARK: - Delegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Throttle software: ulteriore garanzia se il device ignora il frame rate richiesto.
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard t - lastProcessed >= (1.0 / targetFPS) * 0.9 else { return }
        lastProcessed = t
        onFrame?(sampleBuffer)
    }
}
