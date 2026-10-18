import Foundation
import AppKit
import PDFKit
import CoreGraphics
import CoreText
import ImageIO
import Vision
import UniformTypeIdentifiers

enum PDFEngineError: LocalizedError {
    case unreadable(String)
    case locked(String)
    case cannotWrite(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "“\(name)” couldn't be read."
        case .locked(let name): return "“\(name)” is password-protected. Use the Remove Password tool first, then try again."
        case .cannotWrite(let name): return "Couldn't save “\(name)”."
        case .empty: return "There were no pages to save."
        }
    }
}

/// Opens a fresh PDFDocument for background work (PDFKit documents shouldn't be shared across threads).
struct PDFOpener {
    let url: URL
    let password: String?

    var name: String { url.lastPathComponent }
    var baseName: String { Naming.base(url) }

    func open() throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw PDFEngineError.unreadable(name) }
        if doc.isLocked {
            guard let password, doc.unlock(withPassword: password) else { throw PDFEngineError.locked(name) }
        }
        return doc
    }
}

struct PageSpec {
    let index: Int      // page index in the source document
    let rotation: Int   // extra rotation in degrees (multiple of 90)
}

struct SignaturePlacement: Identifiable, Equatable {
    let id = UUID()
    var page: Int
    var center: CGPoint   // normalised 0…1, origin top-left
    var width: CGFloat    // fraction of the page width
}

/// All processing happens on this Mac: PDFKit, Core Graphics and Vision. Nothing is uploaded.
enum PDFEngine {

    // MARK: - Merge / Images to PDF

    @discardableResult
    static func combine(_ items: [InputItem],
                        to output: URL,
                        options: CombineOptions,
                        progress: @escaping (Double) -> Void) throws -> Int {
        let result = PDFDocument()
        var keepAlive: [PDFDocument] = []
        let total = max(1, items.reduce(0) { $0 + $1.pageCount })
        var done = 0

        func tick() {
            done += 1
            progress(Double(done) / Double(total))
        }

        for item in items {
            switch item.kind {
            case .pdf:
                guard let source = PDFDocument(url: item.url) else { throw PDFEngineError.unreadable(item.name) }
                if source.isLocked { throw PDFEngineError.locked(item.name) }
                keepAlive.append(source)

                for index in 0..<source.pageCount {
                    guard let page = source.page(at: index) else { continue }
                    if options.ocr, needsOCR(page),
                       let ocrDoc = searchableCopy(of: page),
                       let ocrPage = ocrDoc.page(at: 0)?.copy() as? PDFPage {
                        keepAlive.append(ocrDoc)
                        result.insert(ocrPage, at: result.pageCount)
                    } else if let copy = page.copy() as? PDFPage {
                        result.insert(copy, at: result.pageCount)
                    }
                    tick()
                }

            case .image:
                let doc = try imagePageDocument(for: item, options: options)
                keepAlive.append(doc)
                if let page = doc.page(at: 0)?.copy() as? PDFPage {
                    result.insert(page, at: result.pageCount)
                }
                tick()
            }
        }

        let pageCount = result.pageCount
        guard pageCount > 0 else { throw PDFEngineError.empty }
        try write(result, to: output)
        withExtendedLifetime(keepAlive) {}
        return pageCount
    }

    static func imagesToSeparatePDFs(_ items: [InputItem],
                                     options: CombineOptions,
                                     folder: URL,
                                     progress: @escaping (Double) -> Void) throws -> [URL] {
        var outputs: [URL] = []
        for (n, item) in items.enumerated() {
            let doc = try imagePageDocument(for: item, options: options)
            let url = uniqueURL(folder.appendingPathComponent(Naming.base(item.url) + ".pdf"))
            try write(doc, to: url)
            outputs.append(url)
            progress(Double(n + 1) / Double(max(1, items.count)))
        }
        return outputs
    }

    // MARK: - Page selection tools (organize, delete, extract, split)

    static func assemble(_ source: PDFDocument, pages: [PageSpec], progress: (Double) -> Void = { _ in }) -> PDFDocument {
        let doc = PDFDocument()
        for (n, spec) in pages.enumerated() {
            guard let copy = source.page(at: spec.index)?.copy() as? PDFPage else { continue }
            if spec.rotation != 0 {
                copy.rotation = ((copy.rotation + spec.rotation) % 360 + 360) % 360
            }
            doc.insert(copy, at: doc.pageCount)
            progress(Double(n + 1) / Double(max(1, pages.count)))
        }
        return doc
    }

    static func allPages(of doc: PDFDocument) -> [PageSpec] {
        (0..<doc.pageCount).map { PageSpec(index: $0, rotation: 0) }
    }

    @discardableResult
    static func savePages(_ opener: PDFOpener,
                          pages: [PageSpec],
                          to output: URL,
                          progress: @escaping (Double) -> Void) throws -> Int {
        let source = try opener.open()
        let doc = assemble(source, pages: pages, progress: progress)
        guard doc.pageCount > 0 else { throw PDFEngineError.empty }
        try write(doc, to: output)
        withExtendedLifetime(source) {}
        return doc.pageCount
    }

    static func extractSeparately(_ opener: PDFOpener,
                                  pages: [PageSpec],
                                  folder: URL,
                                  progress: @escaping (Double) -> Void) throws -> [URL] {
        let source = try opener.open()
        let digits = max(2, String(source.pageCount).count)
        var outputs: [URL] = []
        for (n, spec) in pages.enumerated() {
            let single = assemble(source, pages: [spec])
            guard single.pageCount > 0 else { continue }
            let number = String(format: "%0\(digits)d", spec.index + 1)
            let url = uniqueURL(folder.appendingPathComponent("\(opener.baseName) - page \(number).pdf"))
            try write(single, to: url)
            outputs.append(url)
            progress(Double(n + 1) / Double(max(1, pages.count)))
        }
        withExtendedLifetime(source) {}
        return outputs
    }

    static func split(_ opener: PDFOpener,
                      pagesPerFile: Int,
                      folder: URL,
                      progress: @escaping (Double) -> Void) throws -> [URL] {
        let source = try opener.open()
        let count = source.pageCount
        let chunk = max(1, pagesPerFile)
        let digits = max(2, String(count).count)
        var outputs: [URL] = []

        for start in stride(from: 0, to: count, by: chunk) {
            let end = min(start + chunk, count)
            let specs = (start..<end).map { PageSpec(index: $0, rotation: 0) }
            let part = assemble(source, pages: specs)
            let first = String(format: "%0\(digits)d", start + 1)
            let last = String(format: "%0\(digits)d", end)
            let label = end - start == 1 ? "page \(first)" : "pages \(first)-\(last)"
            let url = uniqueURL(folder.appendingPathComponent("\(opener.baseName) - \(label).pdf"))
            try write(part, to: url)
            outputs.append(url)
            progress(Double(end) / Double(max(1, count)))
        }
        withExtendedLifetime(source) {}
        return outputs
    }

    // MARK: - Compress

    /// Returns the size of the written file in bytes.
    static func compress(_ opener: PDFOpener,
                         level: CompressionLevel,
                         ocr: Bool,
                         to output: URL,
                         progress: @escaping (Double) -> Void) throws -> Int64 {
        let source = try opener.open()
        var keepAlive: [PDFDocument] = [source]

        if !level.rasterizes {
            progress(0.2)
            let doc = assemble(source, pages: allPages(of: source))
            try write(doc, to: output, options: [
                .saveImagesAsJPEGOption: true,
                .optimizeImagesForScreenOption: true
            ])
            progress(1)
        } else {
            let result = PDFDocument()
            let count = source.pageCount
            for index in 0..<count {
                guard let page = source.page(at: index), let cgPage = page.pageRef else { continue }
                let size = displaySize(of: cgPage)
                let scale = min(level.dpi / 72, 6000 / max(1, max(size.width, size.height)))
                guard let bitmap = render(cgPage, size: size, scale: scale) else { continue }
                let embedded = jpegBacked(bitmap, quality: level.jpegQuality) ?? bitmap

                var lines: [TextLine] = []
                if ocr {
                    let ocrImage = level.dpi < 150 ? (renderForOCR(cgPage, size: size) ?? bitmap) : bitmap
                    lines = recognizeText(in: ocrImage)
                }
                let pageRect = CGRect(origin: .zero, size: size)
                if let single = singlePageDocument(size: size, draw: { ctx in
                    ctx.interpolationQuality = .high
                    ctx.draw(embedded, in: pageRect)
                    drawInvisibleText(lines, in: pageRect, context: ctx)
                }), let newPage = single.page(at: 0)?.copy() as? PDFPage {
                    keepAlive.append(single)
                    result.insert(newPage, at: result.pageCount)
                }
                progress(Double(index + 1) / Double(max(1, count)))
            }
            guard result.pageCount > 0 else { throw PDFEngineError.empty }
            try write(result, to: output)
        }
        withExtendedLifetime(keepAlive) {}
        return Naming.fileSize(output)
    }

    // MARK: - Passwords

    static func protect(_ opener: PDFOpener, password: String, to output: URL) throws {
        let source = try opener.open()
        let doc = assemble(source, pages: allPages(of: source))
        try write(doc, to: output, options: [
            .userPasswordOption: password,
            .ownerPasswordOption: password
        ])
        withExtendedLifetime(source) {}
    }

    static func removePassword(_ opener: PDFOpener, to output: URL) throws {
        let source = try opener.open()
        // Copying the pages into a new document drops the encryption.
        let doc = assemble(source, pages: allPages(of: source))
        guard doc.pageCount > 0 else { throw PDFEngineError.empty }
        try write(doc, to: output)
        withExtendedLifetime(source) {}
    }

    // MARK: - PDF to images

    static func exportImages(_ opener: PDFOpener,
                             format: ImageFormat,
                             dpi: CGFloat,
                             folder: URL,
                             progress: @escaping (Double) -> Void) throws -> [URL] {
        let source = try opener.open()
        let count = source.pageCount
        let digits = max(2, String(count).count)
        var outputs: [URL] = []

        for index in 0..<count {
            guard let cgPage = source.page(at: index)?.pageRef else { continue }
            let size = displaySize(of: cgPage)
            let scale = min(dpi / 72, 12000 / max(1, max(size.width, size.height)))
            guard let image = render(cgPage, size: size, scale: scale) else { continue }
            let number = String(format: "%0\(digits)d", index + 1)
            let url = uniqueURL(folder.appendingPathComponent("\(opener.baseName) - page \(number).\(format.fileExtension)"))
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
                throw PDFEngineError.cannotWrite(url.lastPathComponent)
            }
            let properties: [CFString: Any] = [
                kCGImageDestinationLossyCompressionQuality: 0.9,
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw PDFEngineError.cannotWrite(url.lastPathComponent) }
            outputs.append(url)
            progress(Double(index + 1) / Double(max(1, count)))
        }
        return outputs
    }

    // MARK: - Make searchable (OCR)

    static func makeSearchable(_ opener: PDFOpener,
                               to output: URL,
                               progress: @escaping (Double) -> Void) throws -> (recognised: Int, total: Int) {
        let source = try opener.open()
        let result = PDFDocument()
        var keepAlive: [PDFDocument] = [source]
        var recognised = 0
        let count = source.pageCount

        for index in 0..<count {
            guard let page = source.page(at: index) else { continue }
            if needsOCR(page),
               let ocrDoc = searchableCopy(of: page),
               let ocrPage = ocrDoc.page(at: 0)?.copy() as? PDFPage {
                keepAlive.append(ocrDoc)
                result.insert(ocrPage, at: result.pageCount)
                recognised += 1
            } else if let copy = page.copy() as? PDFPage {
                result.insert(copy, at: result.pageCount)
            }
            progress(Double(index + 1) / Double(max(1, count)))
        }
        guard result.pageCount > 0 else { throw PDFEngineError.empty }
        try write(result, to: output)
        withExtendedLifetime(keepAlive) {}
        return (recognised, count)
    }

    // MARK: - Sign

    static func sign(_ opener: PDFOpener,
                     placements: [SignaturePlacement],
                     signature: CGImage,
                     to output: URL,
                     progress: @escaping (Double) -> Void) throws {
        let source = try opener.open()
        let result = PDFDocument()
        var keepAlive: [PDFDocument] = [source]
        let aspect = CGFloat(signature.height) / CGFloat(max(1, signature.width))
        let count = source.pageCount

        for index in 0..<count {
            guard let page = source.page(at: index) else { continue }
            let mine = placements.filter { $0.page == index }
            var signedPage: PDFPage?

            if !mine.isEmpty, let cgPage = page.pageRef {
                let size = displaySize(of: cgPage)
                let doc = singlePageDocument(size: size) { ctx in
                    ctx.saveGState()
                    drawPage(cgPage, in: ctx, size: size)
                    ctx.restoreGState()
                    ctx.interpolationQuality = .high
                    for placement in mine {
                        let width = placement.width * size.width
                        let height = width * aspect
                        let rect = CGRect(x: placement.center.x * size.width - width / 2,
                                          y: size.height - placement.center.y * size.height - height / 2,
                                          width: width,
                                          height: height)
                        ctx.draw(signature, in: rect)
                    }
                }
                if let doc, let newPage = doc.page(at: 0)?.copy() as? PDFPage {
                    keepAlive.append(doc)
                    signedPage = newPage
                }
            }

            if let signedPage {
                result.insert(signedPage, at: result.pageCount)
            } else if let copy = page.copy() as? PDFPage {
                result.insert(copy, at: result.pageCount)
            }
            progress(Double(index + 1) / Double(max(1, count)))
        }
        try write(result, to: output)
        withExtendedLifetime(keepAlive) {}
    }

    // MARK: - Images

    static func imagePageDocument(for item: InputItem, options: CombineOptions) throws -> PDFDocument {
        guard let bitmap = loadFlattenedImage(at: item.url, maxPixelSize: options.quality.maxPixelSize) else {
            throw PDFEngineError.unreadable(item.name)
        }
        let embedded = jpegBacked(bitmap, quality: options.quality.jpegQuality) ?? bitmap
        let imageSize = CGSize(width: bitmap.width, height: bitmap.height)
        let pageSize = options.pageSize.pageSize(for: imageSize)
        let margin = options.pageSize.margin
        let content = CGRect(origin: .zero, size: pageSize).insetBy(dx: margin, dy: margin)
        let imageRect = aspectFit(imageSize, in: content)
        let lines = options.ocr ? recognizeText(in: bitmap) : []

        guard let doc = singlePageDocument(size: pageSize, draw: { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(embedded, in: imageRect)
            drawInvisibleText(lines, in: imageRect, context: ctx)
        }) else {
            throw PDFEngineError.unreadable(item.name)
        }
        return doc
    }

    /// Loads an image, applies EXIF rotation, downsizes it and puts it on a white background.
    static func loadFlattenedImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let raw = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let width = raw.width, height = raw.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return raw }
        let rect = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        ctx.setFillColor(CGColor.white)
        ctx.fill(rect)
        ctx.draw(raw, in: rect)
        return ctx.makeImage() ?? raw
    }

    static func jpegBacked(_ image: CGImage, quality: CGFloat) -> CGImage? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    // MARK: - OCR (on-device, Apple Vision)

    struct TextLine {
        let text: String
        let box: CGRect   // normalised 0…1, origin bottom-left
    }

    static func recognizeText(in image: CGImage) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return TextLine(text: candidate.string, box: observation.boundingBox)
        }
    }

    /// Draws recognised text invisibly over the image so the PDF becomes searchable and selectable.
    static func drawInvisibleText(_ lines: [TextLine], in rect: CGRect, context ctx: CGContext) {
        for line in lines {
            let box = CGRect(x: rect.minX + line.box.minX * rect.width,
                             y: rect.minY + line.box.minY * rect.height,
                             width: line.box.width * rect.width,
                             height: line.box.height * rect.height)
            guard box.width > 1, box.height > 1, !line.text.isEmpty else { continue }

            let font = CTFontCreateWithName("Helvetica" as CFString, box.height * 0.85, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font
            ]
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: attributes) as CFAttributedString)
            let lineWidth = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            guard lineWidth > 0 else { continue }

            ctx.saveGState()
            ctx.setTextDrawingMode(.invisible)
            ctx.textMatrix = .identity
            ctx.translateBy(x: box.minX, y: box.minY + box.height * 0.15)
            ctx.scaleBy(x: box.width / lineWidth, y: 1)
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
    }

    static func needsOCR(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Re-creates a scanned PDF page with an invisible text layer on top.
    static func searchableCopy(of page: PDFPage) -> PDFDocument? {
        guard let cgPage = page.pageRef else { return nil }
        let size = displaySize(of: cgPage)
        guard let image = renderForOCR(cgPage, size: size) else { return nil }
        let lines = recognizeText(in: image)
        guard !lines.isEmpty else { return nil }

        return singlePageDocument(size: size) { ctx in
            ctx.saveGState()
            drawPage(cgPage, in: ctx, size: size)
            ctx.restoreGState()
            drawInvisibleText(lines, in: CGRect(origin: .zero, size: size), context: ctx)
        }
    }

    // MARK: - Core Graphics helpers

    /// Page size as displayed, i.e. with the page's rotation applied.
    static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        let rotated = abs(page.rotationAngle) % 180 == 90
        return rotated ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Draws a PDF page (respecting its rotation) into a rect of `size` at the origin.
    static func drawPage(_ page: CGPDFPage, in ctx: CGContext, size: CGSize) {
        let transform = page.getDrawingTransform(.cropBox,
                                                 rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0,
                                                 preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
    }

    /// Renders a page to a bitmap. `scale` 1 = 72 dpi.
    static func render(_ page: CGPDFPage, size: CGSize, scale: CGFloat) -> CGImage? {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor.white)
        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        drawPage(page, in: ctx, size: size)
        return ctx.makeImage()
    }

    static func renderForOCR(_ page: CGPDFPage, size: CGSize) -> CGImage? {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        return render(page, size: size, scale: min(2.5, 5000 / longest))
    }

    static func singlePageDocument(size: CGSize, draw: (CGContext) -> Void) -> PDFDocument? {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(origin: .zero, size: size)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        draw(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)
    }

    // MARK: - Files

    /// Writes via a temporary file so an input file can safely be overwritten.
    static func write(_ document: PDFDocument,
                      to output: URL,
                      options: [PDFDocumentWriteOption: Any]? = nil) throws {
        let fm = FileManager.default
        let tempDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: output.deletingLastPathComponent(), create: true)
        defer { try? fm.removeItem(at: tempDir) }
        let temp = tempDir.appendingPathComponent(output.lastPathComponent)
        let ok: Bool
        if let options {
            ok = document.write(to: temp, withOptions: options)
        } else {
            ok = document.write(to: temp)
        }
        guard ok else { throw PDFEngineError.cannotWrite(output.lastPathComponent) }
        if fm.fileExists(atPath: output.path) {
            _ = try fm.replaceItemAt(output, withItemAt: temp)
        } else {
            try fm.moveItem(at: temp, to: output)
        }
    }

    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) (\(n))").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
