import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ItemKind: Hashable {
    case pdf
    case image
}

struct InputItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let kind: ItemKind
    let pageCount: Int

    var name: String { url.lastPathComponent }

    var subtitle: String {
        switch kind {
        case .pdf: return "PDF · \(Naming.pages(pageCount))"
        case .image: return "Image"
        }
    }

    /// Returns nil when the file is not a readable PDF or image.
    static func make(from url: URL) -> InputItem? {
        let detected = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        guard let type = detected ?? UTType(filenameExtension: url.pathExtension) else { return nil }

        if type.conforms(to: .pdf) {
            guard let doc = PDFDocument(url: url) else { return nil }
            return InputItem(url: url, kind: .pdf, pageCount: doc.pageCount)
        }
        if type.conforms(to: .image),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetCount(source) > 0 {
            return InputItem(url: url, kind: .image, pageCount: 1)
        }
        return nil
    }
}

enum PageSizeOption: String, CaseIterable, Identifiable {
    case fitImage
    case a4
    case letter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fitImage: return "Fit to image"
        case .a4: return "A4"
        case .letter: return "US Letter"
        }
    }

    var margin: CGFloat { self == .fitImage ? 0 : 24 }

    /// Page size in PDF points. Paper sizes rotate to landscape for wide images.
    func pageSize(for image: CGSize) -> CGSize {
        let landscape = image.width > image.height
        switch self {
        case .fitImage:
            let longest = max(image.width, image.height)
            let scale: CGFloat = longest > 842 ? 842 / longest : 1
            return CGSize(width: max(1, (image.width * scale).rounded()),
                          height: max(1, (image.height * scale).rounded()))
        case .a4:
            return landscape ? CGSize(width: 841.89, height: 595.28) : CGSize(width: 595.28, height: 841.89)
        case .letter:
            return landscape ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792)
        }
    }
}

enum ImageQuality: String, CaseIterable, Identifiable {
    case high
    case balanced
    case small

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: return "High"
        case .balanced: return "Balanced"
        case .small: return "Small file"
        }
    }

    var maxPixelSize: Int {
        switch self {
        case .high: return 4000
        case .balanced: return 2500
        case .small: return 1600
        }
    }

    var jpegQuality: CGFloat {
        switch self {
        case .high: return 0.9
        case .balanced: return 0.75
        case .small: return 0.55
        }
    }
}

struct CombineOptions {
    var pageSize: PageSizeOption
    var quality: ImageQuality
    var ocr: Bool
}

enum CompressionLevel: String, CaseIterable, Identifiable {
    case light
    case balanced
    case strong

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "Light: keep everything sharp"
        case .balanced: return "Balanced: recommended"
        case .strong: return "Strong: smallest file"
        }
    }

    var detail: String {
        switch self {
        case .light:
            return "Optimises the images inside the PDF. Text and vector graphics stay untouched. Works best on PDFs with large photos."
        case .balanced:
            return "Re-draws every page as a 150 dpi image. Big savings on scans; still sharp on screen and for printing."
        case .strong:
            return "Re-draws every page as a 100 dpi image. Smallest file, fine for reading on screen."
        }
    }

    var rasterizes: Bool { self != .light }

    var dpi: CGFloat {
        switch self {
        case .light: return 0
        case .balanced: return 150
        case .strong: return 100
        }
    }

    var jpegQuality: CGFloat {
        switch self {
        case .light: return 0.8
        case .balanced: return 0.65
        case .strong: return 0.5
        }
    }
}

enum ImageFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg

    var id: String { rawValue }
    var label: String { self == .png ? "PNG" : "JPEG" }
    var fileExtension: String { self == .png ? "png" : "jpg" }
    var utType: UTType { self == .png ? .png : .jpeg }
}

enum Naming {
    static func base(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    static func pages(_ count: Int) -> String {
        "\(count) page\(count == 1 ? "" : "s")"
    }

    static func fileSize(_ url: URL?) -> Int64 {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }

    static func sizeString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
