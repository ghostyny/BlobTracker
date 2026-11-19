import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

enum BoxColor: String, CaseIterable, Identifiable {
    case red, green, blue, yellow
    var id: String { rawValue }

    var ui: Color {
        switch self {
        case .red: return Color(red: 1.0, green: 0.05, blue: 0.05)
        case .green: return Color(red: 0.1, green: 1.0, blue: 0.1)
        case .blue: return Color(red: 0.25, green: 0.45, blue: 1.0)
        case .yellow: return Color(red: 1.0, green: 0.9, blue: 0.0)
        }
    }

    var cg: CGColor {
        switch self {
        case .red: return CGColor(red: 1.0, green: 0.05, blue: 0.05, alpha: 1)
        case .green: return CGColor(red: 0.1, green: 1.0, blue: 0.1, alpha: 1)
        case .blue: return CGColor(red: 0.25, green: 0.45, blue: 1.0, alpha: 1)
        case .yellow: return CGColor(red: 1.0, green: 0.9, blue: 0.0, alpha: 1)
        }
    }
}

/// rect is normalized (0...1) with the origin at the BOTTOM-left, like Vision uses.
struct Box: Identifiable {
    let id = UUID()
    var rect: CGRect
    var label = ""
    var color: BoxColor = .red
    var enabled = false
}

enum DetectMode: String, CaseIterable, Identifiable {
    case rects = "Окна / прямоугольники"
    case objects = "Объекты"
    case people = "Люди"
    case faces = "Лица"
    case text = "Текст"
    var id: String { rawValue }
}

struct VideoFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".mov")
            try FileManager.default.copyItem(at: received.file, to: dest)
            return VideoFile(url: dest)
        }
    }
}
