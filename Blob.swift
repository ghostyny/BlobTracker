import CoreGraphics
import CoreVideo
import Foundation

struct BlobSettings: Equatable {
    enum Kind: String, CaseIterable, Identifiable {
        case color = "По цвету"
        case bright = "Светлое"
        case dark = "Тёмное"
        var id: String { rawValue }
    }

    var kind: Kind = .bright
    var tr: Double = 1.0
    var tg: Double = 0.8
    var tb: Double = 0.2
    var tolerance: Double = 0.25   // 0...1, color distance
    var threshold: Double = 0.75   // 0...1, brightness for bright/dark
    var minArea: Double = 0.002    // fraction of the frame
    var maxBlobs: Int = 15
    var labels: String = ""        // comma separated, assigned in a cycle
    var color: BoxColor = .red
}

enum BlobDetector {
    static let smallW = 200

    // MARK: Public API

    /// For every video frame (BGRA pixel buffer). Returns normalized rects, origin bottom-left.
    static func detect(pixelBuffer pb: CVPixelBuffer, settings s: BlobSettings) -> [CGRect] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }

        let W = CVPixelBufferGetWidth(pb)
        let H = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let sw = min(smallW, W)
        let sh = max(1, sw * H / W)

        var small = [UInt8](repeating: 0, count: sw * sh * 4)
        let src = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<sh {
            let py = min(H - 1, y * H / sh)
            for x in 0..<sw {
                let px = min(W - 1, x * W / sw)
                let o = py * bpr + px * 4
                let d = (y * sw + x) * 4
                small[d] = src[o]
                small[d + 1] = src[o + 1]
                small[d + 2] = src[o + 2]
            }
        }
        return blobs(small, sw, sh, s)
    }

    /// For the preview image.
    static func detect(image: CGImage, settings s: BlobSettings) -> [CGRect] {
        guard let (px, w, h) = smallBitmap(image) else { return [] }
        return blobs(px, w, h, s)
    }

    /// Color under a point. nx, ny are normalized with the origin at the TOP-left.
    static func pickColor(image: CGImage, nx: Double, ny: Double) -> (Double, Double, Double)? {
        guard let (px, w, h) = smallBitmap(image) else { return nil }
        let cx = min(w - 1, max(0, Int(nx * Double(w))))
        let cy = min(h - 1, max(0, Int(ny * Double(h))))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for dy in -1...1 {
            for dx in -1...1 {
                let x = min(w - 1, max(0, cx + dx))
                let y = min(h - 1, max(0, cy + dy))
                let o = (y * w + x) * 4
                b += Double(px[o])
                g += Double(px[o + 1])
                r += Double(px[o + 2])
                n += 1
            }
        }
        return (r / n / 255, g / n / 255, b / n / 255)
    }

    // MARK: Internals

    private static func smallBitmap(_ image: CGImage) -> ([UInt8], Int, Int)? {
        let sw = min(smallW, image.width)
        let sh = max(1, sw * image.height / image.width)
        var small = [UInt8](repeating: 0, count: sw * sh * 4)
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = small.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: sw, height: sh, bitsPerComponent: 8,
                bytesPerRow: sw * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            return true
        }
        return ok ? (small, sw, sh) : nil
    }

    /// px is BGRA, rows top to bottom.
    private static func blobs(_ px: [UInt8], _ w: Int, _ h: Int, _ s: BlobSettings) -> [CGRect] {
        let total = w * h
        var mask = [Bool](repeating: false, count: total)

        let maxDist = s.tolerance * 441.67 // 255 * sqrt(3)
        let maxD2 = maxDist * maxDist
        let tr = s.tr * 255, tg = s.tg * 255, tb = s.tb * 255
        let thr = s.threshold * 255

        for i in 0..<total {
            let b = Double(px[i * 4])
            let g = Double(px[i * 4 + 1])
            let r = Double(px[i * 4 + 2])
            switch s.kind {
            case .color:
                let dr = r - tr, dg = g - tg, db = b - tb
                mask[i] = dr * dr + dg * dg + db * db <= maxD2
            case .bright:
                mask[i] = (0.299 * r + 0.587 * g + 0.114 * b) >= thr
            case .dark:
                mask[i] = (0.299 * r + 0.587 * g + 0.114 * b) <= thr
            }
        }

        var seen = [Bool](repeating: false, count: total)
        var found: [(count: Int, rect: CGRect)] = []
        var stack: [Int] = []
        let minPix = max(2, Int(s.minArea * Double(total)))
        let maxPix = Int(0.5 * Double(total)) // ignore huge regions like the whole sky

        for start in 0..<total where mask[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var count = 0
            var minX = w, maxX = 0, minY = h, maxY = 0

            while let i = stack.popLast() {
                count += 1
                let x = i % w
                let y = i / w
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }

                if x > 0, mask[i - 1], !seen[i - 1] { seen[i - 1] = true; stack.append(i - 1) }
                if x < w - 1, mask[i + 1], !seen[i + 1] { seen[i + 1] = true; stack.append(i + 1) }
                if y > 0, mask[i - w], !seen[i - w] { seen[i - w] = true; stack.append(i - w) }
                if y < h - 1, mask[i + w], !seen[i + w] { seen[i + w] = true; stack.append(i + w) }
            }

            if count >= minPix && count <= maxPix {
                let rect = CGRect(
                    x: CGFloat(minX) / CGFloat(w),
                    y: 1 - CGFloat(maxY + 1) / CGFloat(h),
                    width: CGFloat(maxX - minX + 1) / CGFloat(w),
                    height: CGFloat(maxY - minY + 1) / CGFloat(h))
                found.append((count, rect))
            }
        }

        found.sort { $0.count > $1.count }
        return found.prefix(s.maxBlobs).map { $0.rect }
    }
}
