import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PDFKit

// MARK: - Options

enum ResizeMode: String, CaseIterable, Identifiable {
    case percent
    case longestSide
    case width
    case height
    case fitBox
    case exactFill

    var id: String { rawValue }

    var label: String {
        switch self {
        case .percent: return "Percentage"
        case .longestSide: return "Longest side"
        case .width: return "Width"
        case .height: return "Height"
        case .fitBox: return "Fit inside a box"
        case .exactFill: return "Exact size (crop to fill)"
        }
    }

    var usesBox: Bool { self == .fitBox || self == .exactFill }
}

struct OutputFormatOption: Hashable, Identifiable {
    let id: String          // UTI, or "original"
    let label: String
    let fileExtension: String
    let lossy: Bool
    let supportsAlpha: Bool

    var isOriginal: Bool { id == "original" }
    var isPDF: Bool { id == UTType.pdf.identifier }

    static let original = OutputFormatOption(id: "original", label: "Same as original", fileExtension: "",
                                             lossy: true, supportsAlpha: true)
    static let jpeg = OutputFormatOption(id: UTType.jpeg.identifier, label: "JPEG", fileExtension: "jpg",
                                         lossy: true, supportsAlpha: false)
    static let pdf = OutputFormatOption(id: UTType.pdf.identifier, label: "PDF (one per image)", fileExtension: "pdf",
                                        lossy: true, supportsAlpha: false)

    /// Formats this Mac can write, discovered at runtime from ImageIO.
    static let available: [OutputFormatOption] = {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let candidates: [OutputFormatOption] = [
            jpeg,
            OutputFormatOption(id: UTType.png.identifier, label: "PNG", fileExtension: "png", lossy: false, supportsAlpha: true),
            OutputFormatOption(id: UTType.heic.identifier, label: "HEIC", fileExtension: "heic", lossy: true, supportsAlpha: true),
            OutputFormatOption(id: UTType.webP.identifier, label: "WebP", fileExtension: "webp", lossy: true, supportsAlpha: true),
            OutputFormatOption(id: UTType.tiff.identifier, label: "TIFF", fileExtension: "tiff", lossy: false, supportsAlpha: true),
            OutputFormatOption(id: UTType.gif.identifier, label: "GIF", fileExtension: "gif", lossy: false, supportsAlpha: true),
            OutputFormatOption(id: UTType.bmp.identifier, label: "BMP", fileExtension: "bmp", lossy: false, supportsAlpha: false)
        ]
        return candidates.filter { writable.contains($0.id) } + [pdf]
    }()
}

struct BatchOptions {
    var resize: ResizeMode?            // nil = keep size
    var percent: Double = 50
    var pixels: Int = 1600
    var boxWidth: Int = 1920
    var boxHeight: Int = 1080
    var dontEnlarge = true
    var format: OutputFormatOption = .original
    var quality: Double = 0.85
    var limitFileSize = false
    var maxKilobytes: Int = 500
    var stripMetadata = false
    var background = RGB(r: 1, g: 1, b: 1)
    var suffix = ""
    var saveNextToOriginals = false
    // Enhance (Batch Convert)
    var straightenDocuments = false
    var adjustments = LayerAdjustments()
    var combinePDF = false

    var hasEnhancements: Bool { straightenDocuments || !adjustments.isIdentity }

    static var resizeDefaults: BatchOptions {
        var options = BatchOptions()
        options.resize = .longestSide
        options.suffix = "-resized"
        return options
    }

    static var convertDefaults: BatchOptions {
        var options = BatchOptions()
        options.format = .jpeg
        return options
    }
}

enum BatchError: LocalizedError {
    case unreadable(String)
    case cannotEncode(String)
    case allFailed([String])

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "“\(name)” couldn't be read."
        case .cannotEncode(let name): return "“\(name)” couldn't be saved in that format."
        case .allFailed(let names): return "None of the images could be processed:\n" + names.prefix(8).joined(separator: "\n")
        }
    }
}

// MARK: - Engine

enum BatchImageEngine {
    struct Summary {
        var outputs: [URL] = []
        var failures: [String] = []
        var bytesIn: Int64 = 0
        var bytesOut: Int64 = 0
        var notStraightened: [String] = []
    }

    /// Result of processing one image.
    struct Output {
        let url: URL
        let straightenFailed: Bool
    }

    /// Shared, lock-protected state for parallel processing.
    private final class BatchState: @unchecked Sendable {
        var summary = Summary()
        var reserved = Set<String>()
        var finished = 0
        var ordered: [Int: URL] = [:]
    }

    /// Plan for one image: the output canvas, and the scale of the image drawn centred inside it.
    struct Plan {
        let canvas: CGSize      // output pixel size
        let content: CGSize     // size the image is drawn at, centred (larger than canvas when cropping)
        let scale: CGFloat
    }

    static func orientedSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func orientedSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return orientedSize(of: source)
    }

    static func plan(for size: CGSize, options: BatchOptions) -> Plan {
        let w = max(1, size.width), h = max(1, size.height)
        guard let mode = options.resize else {
            return Plan(canvas: CGSize(width: w, height: h), content: CGSize(width: w, height: h), scale: 1)
        }

        let px = CGFloat(max(1, options.pixels))
        let boxW = CGFloat(max(1, options.boxWidth)), boxH = CGFloat(max(1, options.boxHeight))
        var scale: CGFloat
        switch mode {
        case .percent: scale = CGFloat(max(1, options.percent)) / 100
        case .longestSide: scale = px / max(w, h)
        case .width: scale = px / w
        case .height: scale = px / h
        case .fitBox: scale = min(boxW / w, boxH / h)
        case .exactFill: scale = max(boxW / w, boxH / h)
        }

        if mode == .exactFill {
            return Plan(canvas: CGSize(width: boxW, height: boxH),
                        content: CGSize(width: w * scale, height: h * scale), scale: scale)
        }
        if options.dontEnlarge && mode != .percent { scale = min(scale, 1) }
        let canvas = CGSize(width: max(1, (w * scale).rounded()), height: max(1, (h * scale).rounded()))
        return Plan(canvas: canvas, content: canvas, scale: scale)
    }

    static func run(_ items: [InputItem],
                    options: BatchOptions,
                    folder: URL?,
                    progress: @escaping (Double) -> Void) -> Summary {
        let state = BatchState()
        let lock = NSLock()
        let combining = options.combinePDF && options.format.isPDF && items.count > 1
        // When combining, single pages go to a temporary folder first.
        let tempFolder = combining
            ? FileManager.default.temporaryDirectory.appendingPathComponent("Uno-\(UUID().uuidString)", isDirectory: true)
            : nil
        if let tempFolder { try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true) }
        let pageOptions: BatchOptions = {
            var copy = options
            if combining { copy.suffix = "" }
            return copy
        }()

        let queue = OperationQueue()
        // Vision work is heavy; run fewer at once when straightening.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        queue.maxConcurrentOperationCount = options.straightenDocuments ? 2 : max(2, min(4, cores / 2))

        for (index, item) in items.enumerated() {
            queue.addOperation {
                let reserve: (URL) -> URL = { candidate in
                    lock.lock()
                    defer { lock.unlock() }
                    let url = uniqueURL(candidate, reserved: state.reserved)
                    state.reserved.insert(url.path)
                    return url
                }
                let result = Result {
                    try process(item.url, options: pageOptions, folder: tempFolder ?? folder, reserve: reserve)
                }
                let bytesIn = Naming.fileSize(item.url)

                lock.lock()
                switch result {
                case .success(let output):
                    state.ordered[index] = output.url
                    state.summary.bytesIn += bytesIn
                    if output.straightenFailed { state.summary.notStraightened.append(item.name) }
                case .failure:
                    state.summary.failures.append(item.name)
                }
                state.finished += 1
                let fraction = Double(state.finished) / Double(max(1, items.count)) * (combining ? 0.9 : 1)
                lock.unlock()
                progress(fraction)
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        var summary = state.summary
        let inOrder = state.ordered.keys.sorted().compactMap { state.ordered[$0] }

        if combining, let tempFolder {
            defer { try? FileManager.default.removeItem(at: tempFolder) }
            let combined = PDFDocument()
            var sources: [PDFDocument] = []
            for url in inOrder {
                guard let doc = PDFDocument(url: url) else { continue }
                sources.append(doc)
                for i in 0..<doc.pageCount {
                    if let page = doc.page(at: i)?.copy() as? PDFPage {
                        combined.insert(page, at: combined.pageCount)
                    }
                }
            }
            let outFolder = folder ?? items[0].url.deletingLastPathComponent()
            let name = Naming.base(items[0].url) + (options.suffix.isEmpty ? " combined" : options.suffix)
            let target = uniqueURL(outFolder.appendingPathComponent(name).appendingPathExtension("pdf"), reserved: [])
            if combined.pageCount > 0, (try? PDFEngine.write(combined, to: target)) != nil {
                summary.outputs = [target]
                summary.bytesOut = Naming.fileSize(target)
            } else {
                summary.failures = items.map(\.name)
                summary.outputs = []
            }
            withExtendedLifetime(sources) {}
            progress(1)
        } else {
            summary.outputs = inOrder
            summary.bytesOut = inOrder.reduce(0) { $0 + Naming.fileSize($1) }
        }
        return summary
    }

    static func process(_ url: URL, options: BatchOptions, folder: URL?, reserve: (URL) -> URL) throws -> Output {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              var size = orientedSize(of: source) else { throw BatchError.unreadable(name) }

        let format = resolvedFormat(options.format, source: source)
        var straightenFailed = false
        let decoded: CGImage

        if options.straightenDocuments {
            // Straighten first (at up to 4000 px), then plan the resize from the corrected size.
            guard let full = ImageLoader.thumbnail(source, maxPixels: Int(min(4000, max(size.width, size.height)))) else {
                throw BatchError.unreadable(name)
            }
            if let flattened = try? ImageAI.straightenDocument(full) {
                decoded = flattened
            } else {
                decoded = full
                straightenFailed = true
            }
            size = CGSize(width: decoded.width, height: decoded.height)
        } else {
            // Decode only as many pixels as needed (fast, low memory), with EXIF rotation applied.
            let scale = Self.plan(for: size, options: options).scale
            let decodePixels = Int(ceil(max(size.width, size.height) * min(scale, 1)))
            guard let thumb = ImageLoader.thumbnail(source, maxPixels: max(1, min(decodePixels, 16000))) else {
                throw BatchError.unreadable(name)
            }
            decoded = thumb
        }

        let plan = Self.plan(for: size, options: options)
        guard var image = draw(decoded, plan: plan, opaque: !format.supportsAlpha, background: options.background) else {
            throw BatchError.unreadable(name)
        }
        if !options.adjustments.isIdentity {
            image = ImageFilters.apply(options.adjustments, to: image)
        }

        let properties = metadata(from: source, strip: options.stripMetadata)
        let outFolder = folder ?? url.deletingLastPathComponent()
        let ext = format.fileExtension.isEmpty ? url.pathExtension : format.fileExtension
        let target = reserve(outFolder.appendingPathComponent(Naming.base(url) + options.suffix).appendingPathExtension(ext))

        if format.isPDF {
            try writePDF(image, dpi: properties[kCGImagePropertyDPIWidth] as? Double, quality: options.quality, to: target)
            return Output(url: target, straightenFailed: straightenFailed)
        }

        let limit = options.limitFileSize ? max(10, options.maxKilobytes) * 1024 : Int.max
        var data: Data?
        for _ in 0..<8 {
            data = encodeWithinLimit(image, format: format, properties: properties, quality: options.quality, limit: limit)
            if let data, data.count <= limit { break }
            // Still too big at the lowest quality: shrink the pixels and try again.
            guard let smaller = downscale(image, by: 0.8) else { break }
            image = smaller
        }
        guard let output = data else { throw BatchError.cannotEncode(name) }
        try output.write(to: target, options: .atomic)
        return Output(url: target, straightenFailed: straightenFailed)
    }

    // MARK: Helpers

    static func resolvedFormat(_ option: OutputFormatOption, source: CGImageSource) -> OutputFormatOption {
        guard option.isOriginal else { return option }
        let type = CGImageSourceGetType(source).map { $0 as String }
        return OutputFormatOption.available.first { $0.id == type && !$0.isPDF } ?? .jpeg
    }

    static func draw(_ image: CGImage, plan: Plan, opaque: Bool, background: RGB) -> CGImage? {
        let width = Int(plan.canvas.width), height = Int(plan.canvas.height)
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        // Keep wide-gamut colour (e.g. iPhone Display P3) when possible.
        let preferred = image.colorSpace?.model == .rgb ? image.colorSpace : nil
        func makeContext(_ space: CGColorSpace) -> CGContext? {
            CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard width > 0, height > 0,
              let ctx = preferred.flatMap(makeContext) ?? makeContext(srgb) else { return nil }

        let full = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        if opaque {
            ctx.setFillColor(background.cgColor)
            ctx.fill(full)
        }
        let content = plan.content
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (full.width - content.width) / 2, y: (full.height - content.height) / 2,
                                   width: content.width, height: content.height))
        return ctx.makeImage()
    }

    static func metadata(from source: CGImageSource, strip: Bool) -> [CFString: Any] {
        var result: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        guard let original = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return result }
        if let dpi = original[kCGImagePropertyDPIWidth] {
            result[kCGImagePropertyDPIWidth] = dpi
            result[kCGImagePropertyDPIHeight] = original[kCGImagePropertyDPIHeight] ?? dpi
        }
        guard !strip else { return result }
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
            if let value = original[key] { result[key] = value }
        }
        // Pixels are already rotated upright.
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        return result
    }

    static func encode(_ image: CGImage, format: OutputFormatOption, properties: [CFString: Any], quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, format.id as CFString, 1, nil) else {
            return nil
        }
        var props = properties
        if format.lossy { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, props as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// For lossy formats, binary-searches the quality to get under `limit` bytes.
    static func encodeWithinLimit(_ image: CGImage, format: OutputFormatOption, properties: [CFString: Any],
                                  quality: Double, limit: Int) -> Data? {
        guard let first = encode(image, format: format, properties: properties, quality: quality) else { return nil }
        guard first.count > limit, format.lossy else { return first }

        var low = 0.05, high = quality
        var best: Data?
        for _ in 0..<7 {
            let mid = (low + high) / 2
            guard let attempt = encode(image, format: format, properties: properties, quality: mid) else { break }
            if attempt.count <= limit {
                best = attempt
                low = mid
            } else {
                high = mid
            }
        }
        return best ?? encode(image, format: format, properties: properties, quality: 0.05)
    }

    static func downscale(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = Int(CGFloat(image.width) * factor), height = Int(CGFloat(image.height) * factor)
        guard width >= 16, height >= 16,
              let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    static func writePDF(_ image: CGImage, dpi: Double?, quality: Double, to url: URL) throws {
        let resolution = CGFloat(dpi ?? 150)
        var size = CGSize(width: CGFloat(image.width) / resolution * 72, height: CGFloat(image.height) / resolution * 72)
        let longest = max(size.width, size.height)
        if longest > 842 {
            size = CGSize(width: size.width * 842 / longest, height: size.height * 842 / longest)
        }
        var box = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw BatchError.cannotEncode(url.lastPathComponent) }
        let embedded = PDFEngine.jpegBacked(image, quality: CGFloat(quality)) ?? image
        ctx.beginPDFPage(nil)
        ctx.interpolationQuality = .high
        ctx.draw(embedded, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Never overwrites: appends " (2)", " (3)"… if a file exists or another job claimed the name.
    static func uniqueURL(_ url: URL, reserved: Set<String>) -> URL {
        let fm = FileManager.default
        func taken(_ candidate: URL) -> Bool {
            fm.fileExists(atPath: candidate.path) || reserved.contains(candidate.path)
        }
        guard taken(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            if !taken(candidate) { return candidate }
            n += 1
        }
    }
}
