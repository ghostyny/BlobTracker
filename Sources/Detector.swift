import Vision
import CoreGraphics

enum Detector {
    /// Returns normalized rects (origin bottom-left) found on a single frame.
    static func detect(_ image: CGImage, mode: DetectMode) -> [CGRect] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        switch mode {
        case .rects:
            let r = VNDetectRectanglesRequest()
            r.minimumAspectRatio = 0.15
            r.maximumObservations = 60
            r.minimumSize = 0.015
            r.minimumConfidence = 0.4
            r.quadratureTolerance = 25
            try? handler.perform([r])
            return (r.results ?? []).map { $0.boundingBox }

        case .objects:
            let r = VNGenerateObjectnessBasedSaliencyImageRequest()
            try? handler.perform([r])
            return (r.results?.first?.salientObjects ?? []).map { $0.boundingBox }

        case .people:
            let r = VNDetectHumanRectanglesRequest()
            r.upperBodyOnly = false
            try? handler.perform([r])
            return (r.results ?? []).map { $0.boundingBox }

        case .faces:
            let r = VNDetectFaceRectanglesRequest()
            try? handler.perform([r])
            return (r.results ?? []).map { $0.boundingBox }

        case .text:
            let r = VNRecognizeTextRequest()
            r.recognitionLevel = .fast
            try? handler.perform([r])
            return (r.results ?? []).map { $0.boundingBox }
        }
    }
}
