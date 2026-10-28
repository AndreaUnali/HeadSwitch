import Vision
import CoreMedia

/// Estrae lo yaw dal frame con Vision (revisione 3 di VNDetectFaceRectanglesRequest,
/// che popola yaw/pitch/roll in VNFaceObservation) e lo passa al detector.
final class VisionProcessor {
    private let detector: GazeZoneDetector
    private let handler = VNSequenceRequestHandler()
    private let request: VNDetectFaceRectanglesRequest

    init(detector: GazeZoneDetector) {
        self.detector = detector
        let r = VNDetectFaceRectanglesRequest()
        r.revision = VNDetectFaceRectanglesRequestRevision3
        self.request = r
    }

    func process(sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        do {
            try handler.perform([request], on: pixelBuffer, orientation: .up)
            // Volto principale = quello più grande; ignora persone sullo sfondo.
            let face = request.results?
                .filter { $0.boundingBox.width > 0.12 }
                .max { $0.boundingBox.width * $0.boundingBox.height <
                       $1.boundingBox.width * $1.boundingBox.height }
            detector.process(yawRadians: face?.yaw?.doubleValue, at: t)
        } catch {
            detector.process(yawRadians: nil, at: t)
        }
    }
}
