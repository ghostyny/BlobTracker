import AVFoundation
import Vision
import CoreText
import CoreGraphics

enum ProcError: LocalizedError {
    case noVideo
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .noVideo: return "В файле нет видеодорожки"
        case .failed(let s): return s
        }
    }
}

/// Holds the Vision trackers and the current position of every box.
final class TrackState {
    let boxes: [Box]
    var requests: [VNTrackObjectRequest]
    var alive: [Bool]
    var rects: [CGRect]
    let seq = VNSequenceRequestHandler()

    init(boxes: [Box]) {
        self.boxes = boxes
        self.rects = boxes.map { $0.rect }
        self.alive = Array(repeating: true, count: boxes.count)
        self.requests = boxes.map { b in
            let obs = VNDetectedObjectObservation(boundingBox: b.rect)
            let req = VNTrackObjectRequest(detectedObjectObservation: obs)
            req.trackingLevel = .accurate
            return req
        }
    }

    func step(_ pb: CVPixelBuffer) {
        let idx = requests.indices.filter { alive[$0] }
        if idx.isEmpty { return }
        do {
            try seq.perform(idx.map { requests[$0] }, on: pb, orientation: .up)
        } catch {
            return // keep last known positions for this frame
        }
        for i in idx {
            guard let obs = requests[i].results?.first as? VNDetectedObjectObservation,
                  obs.confidence > 0.25 else {
                alive[i] = false
                requests[i].isLastFrame = true
                continue
            }
            rects[i] = obs.boundingBox
            requests[i].inputObservation = obs
        }
    }
}

enum Overlay {
    /// Draws all alive boxes straight into the BGRA pixel buffer.
    static func draw(on pb: CVPixelBuffer, state: TrackState) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }

        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo
        ) else { return }

        let W = CGFloat(w), H = CGFloat(h)
        let lw = max(2, W * 0.004)

        for i in state.boxes.indices where state.alive[i] {
            let b = state.boxes[i]
            let n = state.rects[i]
            let r = CGRect(x: n.minX * W, y: n.minY * H, width: n.width * W, height: n.height * H)

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: lw * 3, color: b.color.cg) // glow
            ctx.setStrokeColor(b.color.cg)
            ctx.setLineWidth(lw)
            ctx.stroke(r)

            if !b.label.isEmpty {
                let fontSize = max(14, W * 0.032)
                let font = CTFontCreateWithName("HelveticaNeue-CondensedBold" as CFString, fontSize, nil)
                let attrs: [CFString: Any] = [
                    kCTFontAttributeName: font,
                    kCTForegroundColorAttributeName: b.color.cg
                ]
                if let str = CFAttributedStringCreate(nil, b.label as CFString, attrs as CFDictionary) {
                    let line = CTLineCreateWithAttributedString(str)
                    let tw = CTLineGetBoundsWithOptions(line, []).width
                    let stretch: CGFloat = 1.6 // vertical stretch like in the reference videos
                    ctx.textMatrix = CGAffineTransform(scaleX: 1, y: stretch)
                    let x = min(max(4, r.minX), max(4, W - tw - 4))
                    var y = r.maxY + lw + 3
                    if y + fontSize * stretch > H { y = r.minY - fontSize * stretch - 3 }
                    ctx.textPosition = CGPoint(x: x, y: y)
                    CTLineDraw(line, ctx)
                }
            }
            ctx.restoreGState()
        }
    }
}

final class VideoProcessor {
    func run(url: URL, boxes: [Box], progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcError.noVideo
        }

        // Composition applies the preferred transform, so frames come out upright.
        let comp = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        let evenW = max(2, Int(comp.renderSize.width) & ~1)
        let evenH = max(2, Int(comp.renderSize.height) & ~1)
        comp.renderSize = CGSize(width: evenW, height: evenH)

        let duration = max(0.001, try await asset.load(.duration).seconds)
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        var audioHint: CMFormatDescription?
        if let aTrack { audioHint = try await aTrack.load(.formatDescriptions).first }

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: [vTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        vOut.videoComposition = comp
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        if let aTrack {
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            if reader.canAdd(o) { reader.add(o); aOut = o }
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tracked_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: outURL)
        let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: evenW,
            AVVideoHeightKey: evenH,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: evenW * evenH * 6]
        ])
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: evenW,
                kCVPixelBufferHeightKey as String: evenH
            ]
        )
        writer.add(vIn)

        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioHint)
            i.expectsMediaDataInRealTime = false
            if writer.canAdd(i) { writer.add(i); aIn = i }
        }

        let state = TrackState(boxes: boxes)

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            guard reader.startReading() else {
                cont.resume(throwing: reader.error ?? ProcError.failed("Не удалось прочитать видео"))
                return
            }
            guard writer.startWriting() else {
                cont.resume(throwing: writer.error ?? ProcError.failed("Не удалось начать запись"))
                return
            }
            writer.startSession(atSourceTime: .zero)

            let group = DispatchGroup()
            var lastReported = 0.0

            group.enter()
            vIn.requestMediaDataWhenReady(on: DispatchQueue(label: "bt.video")) {
                while vIn.isReadyForMoreMediaData {
                    guard let sb = vOut.copyNextSampleBuffer(),
                          let pb = CMSampleBufferGetImageBuffer(sb) else {
                        vIn.markAsFinished()
                        group.leave()
                        return
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                    state.step(pb)
                    Overlay.draw(on: pb, state: state)
                    if !adaptor.append(pb, withPresentationTime: pts) {
                        vIn.markAsFinished()
                        group.leave()
                        return
                    }
                    let p = min(1, pts.seconds / duration)
                    if p - lastReported > 0.01 {
                        lastReported = p
                        progress(p)
                    }
                }
            }

            if let aIn, let aOut {
                group.enter()
                aIn.requestMediaDataWhenReady(on: DispatchQueue(label: "bt.audio")) {
                    while aIn.isReadyForMoreMediaData {
                        if let sb = aOut.copyNextSampleBuffer() {
                            aIn.append(sb)
                        } else {
                            aIn.markAsFinished()
                            group.leave()
                            return
                        }
                    }
                }
            }

            group.notify(queue: .global()) {
                if reader.status == .failed {
                    writer.cancelWriting()
                    cont.resume(throwing: reader.error ?? ProcError.failed("Ошибка чтения"))
                    return
                }
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume(returning: outURL)
                    } else {
                        cont.resume(throwing: writer.error ?? ProcError.failed("Ошибка записи"))
                    }
                }
            }
        }
    }
}
