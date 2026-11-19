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

struct DrawItem {
    var rect: CGRect      // normalized, origin bottom-left
    var label: String
    var color: BoxColor
}

enum RenderMode {
    case track([Box])
    case blobs(BlobSettings)
}

/// Follows the chosen boxes from frame to frame.
/// A fresh request is built from the previous result on every frame (Apple's recommended pattern).
final class TrackState {
    let boxes: [Box]
    var obs: [VNDetectedObjectObservation]
    var alive: [Bool]
    var lostFrames: [Int]
    var rects: [CGRect]
    let seq = VNSequenceRequestHandler()

    init(boxes: [Box]) {
        self.boxes = boxes
        self.rects = boxes.map { $0.rect }
        self.obs = boxes.map { VNDetectedObjectObservation(boundingBox: $0.rect) }
        self.alive = Array(repeating: true, count: boxes.count)
        self.lostFrames = Array(repeating: 0, count: boxes.count)
    }

    var items: [DrawItem] {
        boxes.indices.filter { alive[$0] }.map {
            DrawItem(rect: rects[$0], label: boxes[$0].label, color: boxes[$0].color)
        }
    }

    func step(_ pb: CVPixelBuffer) {
        let idx = boxes.indices.filter { alive[$0] }
        if idx.isEmpty { return }

        let reqs: [VNTrackObjectRequest] = idx.map { i in
            let r = VNTrackObjectRequest(detectedObjectObservation: obs[i])
            r.trackingLevel = .accurate
            return r
        }

        do {
            try seq.perform(reqs, on: pb, orientation: .up)
        } catch {
            return // keep last known positions for this frame
        }

        for (k, i) in idx.enumerated() {
            guard let o = reqs[k].results?.first as? VNDetectedObjectObservation else {
                lostFrames[i] += 1
                if lostFrames[i] > 30 { alive[i] = false }
                continue
            }
            obs[i] = o
            rects[i] = o.boundingBox
            if o.confidence < 0.2 {
                lostFrames[i] += 1
                if lostFrames[i] > 45 { alive[i] = false }
            } else {
                lostFrames[i] = 0
            }
        }
    }
}

enum Overlay {
    /// Draws the boxes straight into the BGRA pixel buffer.
    static func draw(on pb: CVPixelBuffer, items: [DrawItem]) {
        if items.isEmpty { return }
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

        for it in items {
            let n = it.rect
            let r = CGRect(x: n.minX * W, y: n.minY * H, width: n.width * W, height: n.height * H)

            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: lw * 3, color: it.color.cg) // glow
            ctx.setStrokeColor(it.color.cg)
            ctx.setLineWidth(lw)
            ctx.stroke(r)

            if !it.label.isEmpty {
                let fontSize = max(14, W * 0.032)
                let font = CTFontCreateWithName("HelveticaNeue-CondensedBold" as CFString, fontSize, nil)
                let attrs: [CFString: Any] = [
                    kCTFontAttributeName: font,
                    kCTForegroundColorAttributeName: it.color.cg
                ]
                if let str = CFAttributedStringCreate(nil, it.label as CFString, attrs as CFDictionary) {
                    let line = CTLineCreateWithAttributedString(str)
                    let tw = CTLineGetBoundsWithOptions(line, []).width
                    let stretch: CGFloat = 1.6
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
    func run(url: URL, mode: RenderMode, progress: @escaping (Double) -> Void) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcError.noVideo
        }

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

        // Mode setup
        var trackBoxes: [Box] = []
        var blobSettings = BlobSettings()
        var blobLabels: [String] = []
        var useBlobs = false
        switch mode {
        case .track(let b):
            trackBoxes = b
        case .blobs(let s):
            useBlobs = true
            blobSettings = s
            blobLabels = s.labels.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let state = TrackState(boxes: trackBoxes)
        let blobsOn = useBlobs
        let bs = blobSettings
        let labels = blobLabels

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

                    var items: [DrawItem]
                    if blobsOn {
                        let rects = BlobDetector.detect(pixelBuffer: pb, settings: bs)
                        items = []
                        for (k, r) in rects.enumerated() {
                            let text = labels.isEmpty ? "" : labels[k % labels.count]
                            items.append(DrawItem(rect: r, label: text, color: bs.color))
                        }
                    } else {
                        state.step(pb)
                        items = state.items
                    }
                    Overlay.draw(on: pb, items: items)

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
