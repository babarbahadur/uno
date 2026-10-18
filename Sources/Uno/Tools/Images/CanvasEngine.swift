import Foundation
import AppKit
import CoreImage
import ImageIO
import PDFKit
import Vision
import UniformTypeIdentifiers

enum CanvasError: LocalizedError {
    case renderFailed
    case cannotSave(String)
    case noSubject
    case noDocument

    var errorDescription: String? {
        switch self {
        case .renderFailed: return "The canvas couldn't be rendered."
        case .cannotSave(let name): return "Couldn't save “\(name)”."
        case .noSubject: return "No person or object was found to cut out."
        case .noDocument: return "No document edges were found. Try Distort and drag the corners yourself."
        }
    }
}

// MARK: - Loading images

enum ImageLoader {
    struct Loaded {
        let image: CGImage
        let preview: CGImage
        let dpi: CGFloat?
        let name: String

        var naturalSize: CGSize { CGSize(width: image.width, height: image.height) }
    }

    static let maxPixels = 8000
    static let previewPixels = 1600

    static func load(url: URL) -> Loaded? {
        let name = url.deletingPathExtension().lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .pdf) == true {
            guard let page = PDFDocument(url: url)?.page(at: 0)?.pageRef else { return nil }
            let size = PDFEngine.displaySize(of: page)
            let scale = min(300.0 / 72.0, CGFloat(maxPixels) / max(1, max(size.width, size.height)))
            guard let image = PDFEngine.render(page, size: size, scale: scale) else { return nil }
            return Loaded(image: image, preview: makePreview(image), dpi: 300, name: name)
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = min(maxPixels, max(1, max(width, height)))
        guard let image = thumbnail(source, maxPixels: longest),
              let preview = thumbnail(source, maxPixels: min(previewPixels, longest)) else { return nil }
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double).map { CGFloat($0) }
        return Loaded(image: image, preview: preview, dpi: dpi, name: name)
    }

    /// Decodes an image with its EXIF orientation applied, limited to `maxPixels` on the long side.
    static func thumbnail(_ source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func makePreview(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > previewPixels else { return image }
        let scale = CGFloat(previewPixels) / CGFloat(longest)
        let w = max(1, Int(CGFloat(image.width) * scale))
        let h = max(1, Int(CGFloat(image.height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    static func fromPasteboard() -> Loaded? {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let first = urls.first, let loaded = load(url: first) {
            return loaded
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return Loaded(image: cg, preview: makePreview(cg), dpi: nil, name: "Pasted image")
    }
}

// MARK: - Text

enum CanvasTextRenderer {
    static func render(_ content: TextContent) -> CGImage? {
        let scale = TextContent.renderScale
        let size = max(4, content.fontSize) * scale
        var font = NSFont(name: content.fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        if content.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        let attributed = NSAttributedString(string: content.string.isEmpty ? " " : content.string, attributes: [
            .font: font,
            .foregroundColor: content.color.nsColor
        ])
        let bounds = attributed.boundingRect(with: NSSize(width: 100_000, height: 100_000),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
        let pad = ceil(size * 0.1)
        let width = Int(ceil(bounds.width + pad * 2))
        let height = Int(ceil(bounds.height + pad * 2))
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attributed.draw(with: NSRect(x: pad, y: pad, width: ceil(bounds.width) + 1, height: ceil(bounds.height) + 1),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}

// MARK: - Filters (Core Image, on device)

enum ImageFilters {
    static let context = CIContext(options: [.cacheIntermediates: false])

    /// Divides the image by a heavily blurred copy of itself: removes shadows and uneven lighting,
    /// which turns grey paper white.
    private static let flattenKernel: CIColorKernel? = CIColorKernel(source: """
        kernel vec4 flattenLighting(__sample image, __sample background) {
            vec3 result = clamp(image.rgb / max(background.rgb, vec3(0.04)), 0.0, 1.0);
            return vec4(result, image.a);
        }
        """)

    static func apply(_ adjustments: LayerAdjustments, to image: CGImage) -> CGImage {
        guard !adjustments.isIdentity else { return image }
        let input = CIImage(cgImage: image)
        var output = applyPreset(adjustments.filter, to: input)

        if adjustments.brightness != 0 || adjustments.contrast != 1 || adjustments.saturation != 1 {
            output = output.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: adjustments.brightness,
                kCIInputContrastKey: adjustments.contrast,
                kCIInputSaturationKey: adjustments.saturation
            ])
        }
        if adjustments.sharpness > 0 {
            output = output.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: adjustments.sharpness
            ])
        }
        output = output.cropped(to: input.extent)
        return context.createCGImage(output, from: input.extent) ?? image
    }

    private static func applyPreset(_ preset: FilterPreset, to input: CIImage) -> CIImage {
        let extent = input.extent
        switch preset {
        case .none:
            return input

        case .autoEnhance:
            var image = input
            for filter in input.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let result = filter.outputImage { image = result }
            }
            return image

        case .scanColor:
            return flatten(input)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputContrastKey: 1.25, kCIInputBrightnessKey: 0.02, kCIInputSaturationKey: 1.1
                ])
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: 0.6])

        case .scanBW:
            return flatten(input)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0, kCIInputContrastKey: 1.9, kCIInputBrightnessKey: 0.08
                ])
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.5, kCIInputIntensityKey: 0.8])

        case .photocopy:
            return flatten(input)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0, kCIInputContrastKey: 2.6, kCIInputBrightnessKey: 0.12
                ])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6])
                .cropped(to: extent)
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.5, kCIInputIntensityKey: 1.0])

        case .scannedCopy:
            // Make a clean digital image look like it went through a scanner: paper tint, softness, grain.
            let toned = input
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0.7, kCIInputContrastKey: 1.08, kCIInputBrightnessKey: 0.02
                ])
                .applyingFilter("CIWhitePointAdjust", parameters: [
                    kCIInputColorKey: CIColor(red: 1.0, green: 0.98, blue: 0.93)
                ])
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.7])
                .cropped(to: extent)
            let grain = CIFilter(name: "CIRandomGenerator")?.outputImage?
                .cropped(to: extent)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.05, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0.05, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0.05, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBiasVector": CIVector(x: -0.025, y: -0.025, z: -0.025, w: 0)
                ])
            guard let grain else { return toned }
            return grain.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: toned])

        case .mono:
            return input.applyingFilter("CIPhotoEffectNoir")

        case .sepia:
            return input.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])

        case .vivid:
            return input
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.8])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1])
        }
    }

    private static func flatten(_ input: CIImage) -> CIImage {
        let extent = input.extent
        let radius = max(extent.width, extent.height) / 40
        let background = input
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)
        guard let kernel = flattenKernel,
              let result = kernel.apply(extent: extent, arguments: [input, background]) else { return input }
        return result
    }
}

// MARK: - On-device AI (Vision)

enum ImageAI {
    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw CanvasError.noSubject }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let masked = CIImage(cvPixelBuffer: buffer)
        guard let output = ImageFilters.context.createCGImage(masked, from: masked.extent) else {
            throw CanvasError.renderFailed
        }
        return output
    }

    /// Finds a document in the photo and returns it flattened and straightened.
    static func straightenDocument(_ image: CGImage) throws -> CGImage {
        guard let corners = detectDocument(image) else { throw CanvasError.noDocument }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        // Vision returns normalised coordinates with the origin at the bottom left, like Core Image.
        func vector(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": vector(corners.topLeft),
            "inputTopRight": vector(corners.topRight),
            "inputBottomRight": vector(corners.bottomRight),
            "inputBottomLeft": vector(corners.bottomLeft)
        ])
        guard !output.extent.isInfinite, output.extent.width > 1,
              let result = ImageFilters.context.createCGImage(output, from: output.extent.integral) else {
            throw CanvasError.renderFailed
        }
        return result
    }

    private static func detectDocument(_ image: CGImage) -> VNRectangleObservation? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let documentRequest = VNDetectDocumentSegmentationRequest()
        if (try? handler.perform([documentRequest])) != nil,
           let observation = documentRequest.results?.first, observation.confidence > 0.3 {
            return observation
        }
        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.maximumObservations = 1
        rectangleRequest.minimumConfidence = 0.5
        rectangleRequest.minimumAspectRatio = 0.2
        rectangleRequest.minimumSize = 0.2
        if (try? handler.perform([rectangleRequest])) != nil {
            return rectangleRequest.results?.first
        }
        return nil
    }
}

// MARK: - Rendering & export

enum CanvasExportFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg
    case pdf

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
    var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpeg: return .jpeg
        case .pdf: return .pdf
        }
    }
}

struct ExportResolution: Identifiable, Hashable {
    let id: String
    let label: String
    let scale: CGFloat
    let dpi: CGFloat
}

enum CanvasRenderer {
    static func resolutions(for doc: CanvasDocument) -> [ExportResolution] {
        if doc.isPhysical {
            let options: [(Int, String)] = [
                (72, "Low · screen & email"), (150, "Medium"), (300, "High · print"), (600, "Maximum")
            ]
            return options.map { option -> ExportResolution in
                let dpi = CGFloat(option.0)
                return ExportResolution(id: "dpi\(option.0)", label: "\(option.1) (\(option.0) dpi)",
                                        scale: dpi / doc.dpi, dpi: dpi)
            }
        }
        let options: [(String, String, CGFloat)] = [
            ("scale25", "Small (25%)", 0.25), ("scale50", "Medium (50%)", 0.5),
            ("scale100", "Original (100%)", 1.0), ("scale200", "Large (200%)", 2.0)
        ]
        return options.map { option -> ExportResolution in
            ExportResolution(id: option.0, label: option.1, scale: option.2, dpi: doc.dpi * option.2)
        }
    }

    static func defaultResolution(for doc: CanvasDocument) -> ExportResolution {
        let all = resolutions(for: doc)
        return all.first { $0.id == (doc.isPhysical ? "dpi300" : "scale100") } ?? all[0]
    }

    static func pixelSize(_ doc: CanvasDocument, scale: CGFloat) -> CGSize {
        let k = min(scale, 16000 / max(1, max(doc.width, doc.height)))
        return CGSize(width: max(1, (doc.width * k).rounded()), height: max(1, (doc.height * k).rounded()))
    }

    /// Renders the whole canvas with full-resolution images and adjustments.
    static func render(_ doc: CanvasDocument, scale: CGFloat, opaque: Bool) -> CGImage? {
        let size = pixelSize(doc, scale: scale)
        let k = size.width / max(1, doc.width)
        let width = Int(size.width), height = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        if let background = doc.backgroundColor {
            ctx.setFillColor(background)
            ctx.fill(full)
        } else if opaque {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(full)
        }
        ctx.interpolationQuality = .high

        for layer in doc.layers where !layer.isHidden {
            let image = ImageFilters.apply(layer.adjustments, to: layer.image)

            if let corners = layer.corners, corners.count == 4 {
                // Perspective: Core Image works bottom-up in output pixels.
                func device(_ p: CGPoint) -> CIVector { CIVector(x: p.x * k, y: CGFloat(height) - p.y * k) }
                let output = CIImage(cgImage: image).applyingFilter("CIPerspectiveTransform", parameters: [
                    "inputTopLeft": device(corners[0]),
                    "inputTopRight": device(corners[1]),
                    "inputBottomRight": device(corners[2]),
                    "inputBottomLeft": device(corners[3])
                ])
                let visible = output.extent.intersection(full).integral
                guard !visible.isNull, !visible.isEmpty,
                      let warped = ImageFilters.context.createCGImage(output, from: visible) else { continue }
                ctx.saveGState()
                ctx.setAlpha(layer.opacity)
                ctx.draw(warped, in: visible)
                ctx.restoreGState()
            } else {
                ctx.saveGState()
                ctx.setAlpha(layer.opacity)
                // Canvas space: y down, 1 unit = 1 canvas pixel.
                ctx.translateBy(x: 0, y: CGFloat(height))
                ctx.scaleBy(x: k, y: -k)
                ctx.concatenate(layer.affine)
                // Image space is y down too, so flip the image itself.
                ctx.translateBy(x: 0, y: layer.naturalSize.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(image, in: CGRect(origin: .zero, size: layer.naturalSize))
                ctx.restoreGState()
            }
        }
        return ctx.makeImage()
    }

    static func export(_ doc: CanvasDocument, format: CanvasExportFormat, resolution: ExportResolution,
                       quality: CGFloat, to url: URL) throws {
        guard let image = render(doc, scale: resolution.scale, opaque: format != .png) else {
            throw CanvasError.renderFailed
        }
        switch format {
        case .png, .jpeg:
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
                throw CanvasError.cannotSave(url.lastPathComponent)
            }
            var properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: resolution.dpi,
                kCGImagePropertyDPIHeight: resolution.dpi
            ]
            if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CanvasError.cannotSave(url.lastPathComponent) }

        case .pdf:
            var box = CGRect(origin: .zero, size: physicalPointSize(doc))
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else {
                throw CanvasError.cannotSave(url.lastPathComponent)
            }
            let embedded = PDFEngine.jpegBacked(image, quality: max(quality, 0.85)) ?? image
            ctx.beginPDFPage(nil)
            ctx.interpolationQuality = .high
            ctx.draw(embedded, in: box)
            ctx.endPDFPage()
            ctx.closePDF()
        }
    }

    /// Canvas size in PDF points (1/72 inch).
    static func physicalPointSize(_ doc: CanvasDocument) -> CGSize {
        CGSize(width: doc.width / max(1, doc.dpi) * 72, height: doc.height / max(1, doc.dpi) * 72)
    }

    /// Prints the canvas at its exact physical size (e.g. a 35×45 mm photo prints at 35×45 mm).
    static func print(_ doc: CanvasDocument) {
        let scale: CGFloat = doc.isPhysical ? 300 / max(1, doc.dpi) : 1
        guard let image = render(doc, scale: scale, opaque: true) else { return }
        let size = physicalPointSize(doc)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown

        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.orientation = size.width > size.height ? .landscape : .portrait
        _ = NSPrintOperation(view: view, printInfo: info).run()
    }
}
