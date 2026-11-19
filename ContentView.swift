import SwiftUI
import PhotosUI
import AVFoundation
import AVKit

struct ContentView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var videoURL: URL?
    @State private var frameImage: UIImage?
    @State private var frameCG: CGImage?
    @State private var boxes: [Box] = []
    @State private var mode: DetectMode = .rects
    @State private var activeID: UUID?
    @State private var draft: CGRect?
    @State private var busy = false
    @State private var progress = 0.0
    @State private var resultURL: URL?
    @State private var message: String?

    @State private var useBlobs = false
    @State private var blob = BlobSettings()
    @State private var blobRects: [CGRect] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Label(frameImage == nil ? "Выбрать видео" : "Другое видео", systemImage: "video.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    if let frameImage {
                        Picker("Режим", selection: $useBlobs) {
                            Text("Рамки + трекинг").tag(false)
                            Text("Блобы (цвет/яркость)").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: useBlobs) { _, _ in recomputeBlobs() }

                        preview(frameImage)

                        if useBlobs {
                            blobEditor
                        } else {
                            Text("Тап по рамке: включить. Ещё тап: выключить. Протяни пальцем по кадру, чтобы нарисовать свою рамку.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Picker("Что искать", selection: $mode) {
                                ForEach(DetectMode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .onChange(of: mode) { _, _ in redetect() }

                            editor
                        }

                        Button {
                            Task { await render() }
                        } label: {
                            if busy {
                                ProgressView(value: progress).frame(maxWidth: .infinity)
                            } else {
                                Label("Сделать видео", systemImage: "wand.and.stars").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .disabled(busy || (!useBlobs && !boxes.contains(where: { $0.enabled })))
                    }

                    if let resultURL {
                        VideoPlayer(player: AVPlayer(url: resultURL))
                            .frame(height: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        HStack {
                            Button("Сохранить в галерею") { saveToPhotos(resultURL) }
                                .buttonStyle(.bordered)
                            ShareLink(item: resultURL)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("BlobTracker")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task {
                    if let v = try? await item.loadTransferable(type: VideoFile.self) {
                        await setVideo(v.url)
                    } else {
                        message = "Не получилось загрузить видео"
                    }
                }
            }
            .onChange(of: blob) { _, _ in recomputeBlobs() }
            .alert("BlobTracker", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    // MARK: - Preview with overlay

    private func preview(_ img: UIImage) -> some View {
        Image(uiImage: img)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geo in
                    let W = geo.size.width
                    let H = geo.size.height
                    ZStack(alignment: .topLeading) {
                        if useBlobs {
                            ForEach(blobRects.indices, id: \.self) { i in
                                let r = uiRect(blobRects[i], W, H)
                                Rectangle()
                                    .stroke(blob.color.ui, lineWidth: 2)
                                    .frame(width: r.width, height: r.height)
                                    .offset(x: r.minX, y: r.minY)
                            }
                        } else {
                            ForEach(boxes) { b in
                                let r = uiRect(b.rect, W, H)
                                Rectangle()
                                    .stroke(b.enabled ? b.color.ui : Color.white.opacity(0.4),
                                            lineWidth: b.id == activeID ? 3.5 : (b.enabled ? 2 : 1))
                                    .frame(width: r.width, height: r.height)
                                    .offset(x: r.minX, y: r.minY)
                                if b.enabled && !b.label.isEmpty {
                                    Text(b.label)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(b.color.ui)
                                        .offset(x: r.minX, y: max(0, r.minY - 15))
                                }
                            }
                            if let d = draft {
                                Rectangle()
                                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                                    .frame(width: d.width, height: d.height)
                                    .offset(x: d.minX, y: d.minY)
                            }
                        }
                    }
                    .frame(width: W, height: H, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in
                                guard !useBlobs else { return }
                                if hypot(v.translation.width, v.translation.height) > 10 {
                                    draft = CGRect(
                                        x: min(v.startLocation.x, v.location.x),
                                        y: min(v.startLocation.y, v.location.y),
                                        width: abs(v.location.x - v.startLocation.x),
                                        height: abs(v.location.y - v.startLocation.y))
                                }
                            }
                            .onEnded { v in
                                let moved = hypot(v.translation.width, v.translation.height)
                                if useBlobs {
                                    if moved <= 10 { pickColor(at: v.location, W, H) }
                                } else if moved > 10, let d = draft {
                                    addManualBox(d, W, H)
                                } else {
                                    tap(at: v.location, W, H)
                                }
                                draft = nil
                            }
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Editors

    @ViewBuilder
    private var editor: some View {
        if let i = boxes.firstIndex(where: { $0.id == activeID }) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Подпись (например: do you see him too?)", text: $boxes[i].label)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("OFFLINE") { boxes[i].label = "OFFLINE"; boxes[i].color = .red }
                    Button("ONLINE") { boxes[i].label = "ONLINE"; boxes[i].color = .green }
                    Spacer()
                    ForEach(BoxColor.allCases) { c in
                        Circle()
                            .fill(c.ui)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().stroke(.white, lineWidth: boxes[i].color == c ? 2 : 0))
                            .onTapGesture { boxes[i].color = c }
                    }
                }
                .buttonStyle(.bordered)

                Button("Удалить рамку", role: .destructive) {
                    boxes.remove(at: i)
                    activeID = nil
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var blobEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Что ловить", selection: $blob.kind) {
                ForEach(BlobSettings.Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            if blob.kind == .color {
                HStack {
                    Text("Цвет:")
                    Circle()
                        .fill(Color(red: blob.tr, green: blob.tg, blue: blob.tb))
                        .frame(width: 22, height: 22)
                    Text("тапни по кадру, чтобы выбрать")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                sliderRow("Допуск цвета", $blob.tolerance, 0.05...0.7)
            } else {
                sliderRow(blob.kind == .bright ? "Порог яркости" : "Порог темноты", $blob.threshold, 0.05...0.95)
            }

            sliderRow("Минимальный размер пятна", $blob.minArea, 0.0003...0.05)
            Stepper("Макс. рамок: \(blob.maxBlobs)", value: $blob.maxBlobs, in: 1...60)

            TextField("Подписи через запятую (OFFLINE, ONLINE)", text: $blob.labels)
                .textFieldStyle(.roundedBorder)

            HStack {
                Text("Цвет рамок")
                Spacer()
                ForEach(BoxColor.allCases) { c in
                    Circle()
                        .fill(c.ui)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(.white, lineWidth: blob.color == c ? 2 : 0))
                        .onTapGesture { blob.color = c }
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func sliderRow(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.footnote)
            Slider(value: value, in: range)
        }
    }

    // MARK: - Geometry helpers

    /// Normalized bottom-left rect -> top-left rect in points.
    private func uiRect(_ r: CGRect, _ W: CGFloat, _ H: CGFloat) -> CGRect {
        CGRect(x: r.minX * W, y: (1 - r.maxY) * H, width: r.width * W, height: r.height * H)
    }

    private func tap(at p: CGPoint, _ W: CGFloat, _ H: CGFloat) {
        let n = CGPoint(x: p.x / W, y: 1 - p.y / H)
        let hits = boxes.indices.filter { boxes[$0].rect.contains(n) }
        guard let i = hits.min(by: { area(boxes[$0].rect) < area(boxes[$1].rect) }) else {
            activeID = nil
            return
        }
        if boxes[i].enabled && activeID == boxes[i].id {
            boxes[i].enabled = false
            activeID = nil
        } else {
            boxes[i].enabled = true
            activeID = boxes[i].id
        }
    }

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    private func addManualBox(_ d: CGRect, _ W: CGFloat, _ H: CGFloat) {
        let x = max(0, d.minX / W)
        let w = min(1 - x, d.width / W)
        let yTop = max(0, d.minY / H)
        let h = min(1 - yTop, d.height / H)
        guard w > 0.01, h > 0.01 else { return }
        var b = Box(rect: CGRect(x: x, y: 1 - yTop - h, width: w, height: h))
        b.enabled = true
        boxes.append(b)
        activeID = b.id
    }

    private func pickColor(at p: CGPoint, _ W: CGFloat, _ H: CGFloat) {
        guard blob.kind == .color, let cg = frameCG else { return }
        if let c = BlobDetector.pickColor(image: cg, nx: Double(p.x / W), ny: Double(p.y / H)) {
            blob.tr = c.0
            blob.tg = c.1
            blob.tb = c.2
        }
    }

    // MARK: - Actions

    private func setVideo(_ url: URL) async {
        videoURL = url
        resultURL = nil
        activeID = nil
        do {
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            let cg = try await gen.image(at: .zero).image
            frameCG = cg
            frameImage = UIImage(cgImage: cg)
            redetect()
            recomputeBlobs()
        } catch {
            message = "Не удалось взять кадр: \(error.localizedDescription)"
        }
    }

    private func redetect() {
        guard let cg = frameCG else { return }
        let m = mode
        activeID = nil
        Task {
            let rects = await Task.detached { Detector.detect(cg, mode: m) }.value
            // keep boxes the user already enabled or drew by hand
            let kept = boxes.filter { $0.enabled }
            boxes = kept + rects.map { Box(rect: $0) }
        }
    }

    private func recomputeBlobs() {
        guard useBlobs, let cg = frameCG else {
            blobRects = []
            return
        }
        blobRects = BlobDetector.detect(image: cg, settings: blob)
    }

    private func render() async {
        guard let url = videoURL else { return }
        let renderMode: RenderMode
        if useBlobs {
            renderMode = .blobs(blob)
        } else {
            let chosen = boxes.filter { $0.enabled }
            guard !chosen.isEmpty else { return }
            renderMode = .track(chosen)
        }
        busy = true
        progress = 0
        resultURL = nil
        do {
            let out = try await VideoProcessor().run(url: url, mode: renderMode) { p in
                DispatchQueue.main.async { self.progress = p }
            }
            resultURL = out
        } catch {
            message = error.localizedDescription
        }
        busy = false
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { message = "Нет доступа к галерее" }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, _ in
                DispatchQueue.main.async { message = ok ? "Сохранено в галерею" : "Не удалось сохранить" }
            }
        }
    }
}
