import Foundation
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import Uno

/// Builds test files (PDFs, images) in a throwaway folder. Nothing touches the user's own files.
enum Fixtures {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    static let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    static let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("UnoTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Text

    static func draw(text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat, color: CGColor = black) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes) as CFAttributedString)
        ctx.textMatrix = .identity
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    // MARK: PDFs

    /// A PDF with real (selectable) text "Page N" on every page.
    @discardableResult
    static func makePDF(at url: URL, pages: Int, size: CGSize = CGSize(width: 595, height: 842)) -> URL {
        var box = CGRect(origin: .zero, size: size)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        for index in 1...max(1, pages) {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(white)
            ctx.fill(box)
            draw(text: "Page \(index)", in: ctx, at: CGPoint(x: 72, y: size.height - 120), size: 36)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// A PDF whose only page is a picture of text, like a scan (no text layer).
    @discardableResult
    static func makeScannedPDF(at url: URL, text: String) -> URL {
        let image = makeImage(width: 1240, height: 1754, color: white, text: text)
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.draw(image, in: box)
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    @discardableResult
    static func makeLockedPDF(at url: URL, pages: Int = 2, password: String) -> URL {
        let plain = url.deletingLastPathComponent().appendingPathComponent("plain-\(UUID().uuidString).pdf")
        makePDF(at: plain, pages: pages)
        let doc = PDFDocument(url: plain)!
        precondition(doc.write(to: url, withOptions: [.userPasswordOption: password, .ownerPasswordOption: password]))
        return url
    }

    // MARK: Images

    /// Solid image, optionally transparent around a coloured centre, optionally with large text.
    static func makeImage(width: Int, height: Int, color: CGColor, transparentEdges: Bool = false, text: String? = nil) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if transparentEdges {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        } else {
            ctx.setFillColor(color)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let text {
            draw(text: text, in: ctx, at: CGPoint(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.55),
                 size: CGFloat(width) / 12)
        }
        return ctx.makeImage()!
    }

    /// Image whose left half is red and right half is blue (to check flips and orientation).
    static func makeSplitImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red)
        ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        ctx.setFillColor(blue)
        ctx.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return ctx.makeImage()!
    }

    /// A light "sheet of paper" with text on a dark table, slightly tilted, for document detection.
    static func makeDocumentPhoto(width: Int = 1600, height: Int = 1200) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.15, green: 0.13, blue: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let paper = CGMutablePath()
        paper.addLines(between: [CGPoint(x: 380, y: 140), CGPoint(x: 1240, y: 190),
                                 CGPoint(x: 1190, y: 1080), CGPoint(x: 330, y: 1030)])
        paper.closeSubpath()
        ctx.addPath(paper)
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.96, blue: 0.94, alpha: 1))
        ctx.fillPath()
        for row in 0..<8 {
            draw(text: "Line of text \(row)", in: ctx, at: CGPoint(x: 460, y: 900 - CGFloat(row) * 80), size: 34)
        }
        return ctx.makeImage()!
    }

    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType = .png, properties: [CFString: Any] = [:]) -> URL {
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return url
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    static func item(_ url: URL, file: StaticString = #filePath, line: UInt = #line) -> InputItem {
        guard let item = InputItem.make(from: url) else {
            XCTFail("Could not read fixture \(url.lastPathComponent)", file: file, line: line)
            fatalError()
        }
        return item
    }

    // MARK: Pixels

    struct Pixel {
        let r: UInt8, g: UInt8, b: UInt8, a: UInt8
        var isReddish: Bool { r > 180 && g < 90 && b < 90 }
        var isBluish: Bool { b > 180 && r < 90 && g < 90 }
        var isWhitish: Bool { r > 225 && g > 225 && b > 225 }
        var isDark: Bool { Int(r) + Int(g) + Int(b) < 200 }
    }

    /// Pixel at (x, y), measured from the top-left corner.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> Pixel {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        return data.withUnsafeMutableBytes { buffer -> Pixel in
            let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let bytes = buffer.bindMemory(to: UInt8.self)
            let i = (min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)) * 4
            return Pixel(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2], a: bytes[i + 3])
        }
    }

    /// Renders a PDF page to an image for pixel checks.
    static func render(page: PDFPage) -> CGImage {
        let cgPage = page.pageRef!
        let size = PDFEngine.displaySize(of: cgPage)
        return PDFEngine.render(cgPage, size: size, scale: 1)!
    }
}
