import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Geometry helpers

extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x * rhs, y: lhs.y * rhs) }
    static func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint { CGPoint(x: lhs.x / rhs, y: lhs.y / rhs) }
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}

enum Geometry {
    static func contains(_ polygon: [CGPoint], _ point: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y) {
                let x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { $0 + $1 }
        return sum / CGFloat(points.count)
    }

    /// Rectangle spanned from an anchor to a point, optionally locked to an aspect ratio (width / height).
    static func rect(from anchor: CGPoint, to point: CGPoint, ratio: CGFloat?) -> CGRect {
        var w = point.x - anchor.x
        var h = point.y - anchor.y
        if let ratio, ratio > 0 {
            let signW: CGFloat = w >= 0 ? 1 : -1
            let signH: CGFloat = h >= 0 ? 1 : -1
            if abs(w) / ratio > abs(h) {
                h = signH * abs(w) / ratio
            } else {
                w = signW * abs(h) * ratio
            }
        }
        return CGRect(x: min(anchor.x, anchor.x + w), y: min(anchor.y, anchor.y + h), width: abs(w), height: abs(h))
    }
}

/// Projective mapping of the unit square onto a quad (Heckbert's formulation).
struct Homography {
    var a, b, c, d, e, f, g, h: CGFloat

    static func unitSquare(to p: [CGPoint]) -> Homography {
        let x0 = p[0].x, y0 = p[0].y, x1 = p[1].x, y1 = p[1].y
        let x2 = p[2].x, y2 = p[2].y, x3 = p[3].x, y3 = p[3].y
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        let det = dx1 * dy2 - dx2 * dy1
        if (abs(dx3) < 1e-9 && abs(dy3) < 1e-9) || abs(det) < 1e-12 {
            return Homography(a: x1 - x0, b: x3 - x0, c: x0, d: y1 - y0, e: y3 - y0, f: y0, g: 0, h: 0)
        }
        let g = (dx3 * dy2 - dx2 * dy3) / det
        let h = (dx1 * dy3 - dx3 * dy1) / det
        return Homography(a: x1 - x0 + g * x1, b: x3 - x0 + h * x3, c: x0,
                          d: y1 - y0 + g * y1, e: y3 - y0 + h * y3, f: y0,
                          g: g, h: h)
    }
}

// MARK: - Canvas setup

enum LengthUnit: String, CaseIterable, Identifiable {
    case mm
    case inch
    case px

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mm: return "mm"
        case .inch: return "in"
        case .px: return "px"
        }
    }

    func pixels(_ value: Double, dpi: Double) -> Double {
        switch self {
        case .mm: return value / 25.4 * dpi
        case .inch: return value * dpi
        case .px: return value
        }
    }
}

struct CanvasPreset: Identifiable, Hashable {
    let id: String
    let group: String
    let name: String
    let width: Double
    let height: Double
    let unit: LengthUnit

    var sizeText: String { "\(Self.format(width)) × \(Self.format(height)) \(unit.label)" }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    static let groups = ["Paper", "ID & photos", "Screen"]

    static let all: [CanvasPreset] = [
        CanvasPreset(id: "a4", group: "Paper", name: "A4", width: 210, height: 297, unit: .mm),
        CanvasPreset(id: "a5", group: "Paper", name: "A5", width: 148, height: 210, unit: .mm),
        CanvasPreset(id: "letter", group: "Paper", name: "US Letter", width: 8.5, height: 11, unit: .inch),
        CanvasPreset(id: "idcard", group: "ID & photos", name: "ID card", width: 85.6, height: 54, unit: .mm),
        CanvasPreset(id: "idphoto", group: "ID & photos", name: "ID / passport photo", width: 35, height: 45, unit: .mm),
        CanvasPreset(id: "usphoto", group: "ID & photos", name: "US passport photo", width: 2, height: 2, unit: .inch),
        CanvasPreset(id: "photo10x15", group: "ID & photos", name: "Photo 10 × 15", width: 100, height: 150, unit: .mm),
        CanvasPreset(id: "square", group: "Screen", name: "Square post", width: 1080, height: 1080, unit: .px),
        CanvasPreset(id: "fullhd", group: "Screen", name: "Full HD", width: 1920, height: 1080, unit: .px)
    ]
}

enum BackgroundKind: String, CaseIterable, Identifiable {
    case white
    case transparent
    case color

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white: return "White"
        case .transparent: return "Transparent"
        case .color: return "Colour"
        }
    }
}

struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double

    static let black = RGB(r: 0, g: 0, b: 0)
    static let lightBlue = RGB(r: 0.82, g: 0.89, b: 0.98)

    var color: Color { Color(red: r, green: g, blue: b) }
    var cgColor: CGColor { CGColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }

    init(r: Double, g: Double, b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        r = Double(ns.redComponent)
        g = Double(ns.greenComponent)
        b = Double(ns.blueComponent)
    }
}

struct CanvasSetup {
    var presetID = "a4"
    var rotated = false
    var dpi: Double = 300
    var customWidth: Double = 100
    var customHeight: Double = 100
    var customUnit: LengthUnit = .mm
    var background: BackgroundKind = .white
    var backgroundRGB = RGB.lightBlue

    var preset: CanvasPreset? { CanvasPreset.all.first { $0.id == presetID } }
    var unit: LengthUnit { preset?.unit ?? customUnit }
    var effectiveDPI: Double { unit == .px ? 72 : dpi }

    var physicalSize: (width: Double, height: Double) {
        let w = preset?.width ?? customWidth
        let h = preset?.height ?? customHeight
        return rotated ? (h, w) : (w, h)
    }

    var pixelSize: CGSize {
        let size = physicalSize
        let w = unit.pixels(size.width, dpi: effectiveDPI).rounded()
        let h = unit.pixels(size.height, dpi: effectiveDPI).rounded()
        return CGSize(width: min(20000, max(1, w)), height: min(20000, max(1, h)))
    }

    func makeDocument() -> CanvasDocument {
        let size = pixelSize
        return CanvasDocument(width: size.width, height: size.height,
                              dpi: CGFloat(effectiveDPI), isPhysical: unit != .px,
                              backgroundKind: background, backgroundRGB: backgroundRGB)
    }
}

// MARK: - Document & layers

struct CanvasDocument {
    var width: CGFloat
    var height: CGFloat
    var dpi: CGFloat
    var isPhysical: Bool
    var backgroundKind: BackgroundKind = .white
    var backgroundRGB = RGB.lightBlue
    var layers: [ImageLayer] = []

    var size: CGSize { CGSize(width: width, height: height) }
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    var backgroundColor: CGColor? {
        switch backgroundKind {
        case .white: return CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .transparent: return nil
        case .color: return backgroundRGB.cgColor
        }
    }

    var sizeDescription: String {
        let pixels = "\(Int(width)) × \(Int(height)) px"
        guard isPhysical, dpi > 0 else { return pixels }
        let mmW = width / dpi * 25.4
        let mmH = height / dpi * 25.4
        return String(format: "%.1f × %.1f mm · ", mmW, mmH) + pixels + " · \(Int(dpi)) dpi"
    }
}

enum FilterPreset: String, CaseIterable, Identifiable {
    case none
    case autoEnhance
    case scanColor
    case scanBW
    case photocopy
    case scannedCopy
    case mono
    case sepia
    case vivid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .autoEnhance: return "Auto enhance"
        case .scanColor: return "Scanned document (colour)"
        case .scanBW: return "Scanned document (B&W)"
        case .photocopy: return "Photocopy"
        case .scannedCopy: return "Scanned copy effect"
        case .mono: return "Black & white"
        case .sepia: return "Sepia"
        case .vivid: return "Vivid"
        }
    }
}

struct LayerAdjustments: Equatable {
    var filter: FilterPreset = .none
    var brightness: CGFloat = 0      // -0.5 … 0.5
    var contrast: CGFloat = 1        // 0.5 … 2
    var saturation: CGFloat = 1      // 0 … 2
    var sharpness: CGFloat = 0       // 0 … 2

    var isIdentity: Bool { self == LayerAdjustments() }
}

struct TextContent: Equatable {
    var string = "Your text"
    var fontName = "Helvetica Neue"
    var fontSize: CGFloat = 60       // in canvas pixels
    var bold = false
    var color = RGB.black

    static let fonts = ["Helvetica Neue", "Arial", "Avenir Next", "Futura", "Georgia",
                        "Times New Roman", "Courier New", "Menlo", "Snell Roundhand"]
    /// Text is rasterised at this multiple of its canvas size so it stays crisp when exported larger.
    static let renderScale: CGFloat = 3
}

struct ImageLayer: Identifiable {
    let id = UUID()
    var name: String
    var image: CGImage                // full resolution, unfiltered
    var preview: CGImage              // ≤ 1600 px, unfiltered
    var filteredPreview: CGImage?     // preview with adjustments applied
    var center: CGPoint
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    var rotation: CGFloat = 0         // degrees, clockwise
    var skewX: CGFloat = 0            // degrees
    var skewY: CGFloat = 0
    var flipH = false
    var flipV = false
    var opacity: CGFloat = 1
    var corners: [CGPoint]?           // TL, TR, BR, BL in canvas px when distorted
    var adjustments = LayerAdjustments()
    var text: TextContent?
    var isHidden = false

    var naturalSize: CGSize { CGSize(width: image.width, height: image.height) }
    var displayImage: CGImage { filteredPreview ?? preview }

    /// Maps image space (0…w, 0…h, y down) to canvas space (pixels, y down).
    var affine: CGAffineTransform {
        let w = naturalSize.width, h = naturalSize.height
        let sx: CGFloat = flipH ? -scaleX : scaleX
        let sy: CGFloat = flipV ? -scaleY : scaleY
        let shearX: CGFloat = tan(skewX * CGFloat.pi / 180)
        let shearY: CGFloat = tan(skewY * CGFloat.pi / 180)
        let radians: CGFloat = rotation * CGFloat.pi / 180
        let toCenter = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        let scale = CGAffineTransform(scaleX: sx, y: sy)
        let shear = CGAffineTransform(a: 1, b: shearY, c: shearX, d: 1, tx: 0, ty: 0)
        let rotate = CGAffineTransform(rotationAngle: radians)
        let place = CGAffineTransform(translationX: center.x, y: center.y)
        return toCenter.concatenating(scale).concatenating(shear).concatenating(rotate).concatenating(place)
    }

    /// Outline from the affine transform only (ignores distortion corners).
    var affineQuad: [CGPoint] {
        let w = naturalSize.width, h = naturalSize.height
        let t = affine
        return [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)]
            .map { $0.applying(t) }
    }

    /// Outline of the layer on the canvas: TL, TR, BR, BL of the image.
    var quad: [CGPoint] {
        if let corners, corners.count == 4 { return corners }
        return affineQuad
    }

    /// Transform used to draw the layer's view (1 canvas px = 1 point, then zoomed).
    func projection(zoom: CGFloat) -> ProjectionTransform {
        if let corners, corners.count == 4 {
            let w = max(1, naturalSize.width), h = max(1, naturalSize.height)
            let hm = Homography.unitSquare(to: corners)
            var p = ProjectionTransform()
            p.m11 = hm.a / w * zoom
            p.m21 = hm.b / h * zoom
            p.m31 = hm.c * zoom
            p.m12 = hm.d / w * zoom
            p.m22 = hm.e / h * zoom
            p.m32 = hm.f * zoom
            p.m13 = hm.g / w
            p.m23 = hm.h / h
            p.m33 = 1
            return p
        }
        return ProjectionTransform(affine.concatenating(CGAffineTransform(scaleX: zoom, y: zoom)))
    }

    mutating func resetTransform() {
        scaleX = 1
        scaleY = 1
        rotation = 0
        skewX = 0
        skewY = 0
        flipH = false
        flipV = false
        corners = nil
    }
}

// MARK: - Editor model

enum EditorMode: String, CaseIterable, Identifiable {
    case move
    case crop
    case distort

    var id: String { rawValue }

    var label: String {
        switch self {
        case .move: return "Move & Transform"
        case .crop: return "Crop"
        case .distort: return "Distort"
        }
    }

    var symbol: String {
        switch self {
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .crop: return "crop"
        case .distort: return "perspective"
        }
    }
}

enum CropAspect: String, CaseIterable, Identifiable {
    case free
    case original
    case square
    case fourThree
    case threeFour
    case sixteenNine
    case idPhoto
    case idCard
    case a4

    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original ratio"
        case .square: return "Square 1:1"
        case .fourThree: return "4:3"
        case .threeFour: return "3:4"
        case .sixteenNine: return "16:9"
        case .idPhoto: return "ID photo 35×45"
        case .idCard: return "ID card 85.6×54"
        case .a4: return "A4 portrait"
        }
    }

    func ratio(canvas: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return canvas.height > 0 ? canvas.width / canvas.height : nil
        case .square: return 1
        case .fourThree: return 4.0 / 3.0
        case .threeFour: return 3.0 / 4.0
        case .sixteenNine: return 16.0 / 9.0
        case .idPhoto: return 35.0 / 45.0
        case .idCard: return 85.6 / 54.0
        case .a4: return 210.0 / 297.0
        }
    }
}

enum AIAction {
    case removeBackground
    case straightenDocument

    var busyText: String {
        switch self {
        case .removeBackground: return "Removing background…"
        case .straightenDocument: return "Finding the document…"
        }
    }
}

final class CanvasEditorModel: ObservableObject {
    @Published var doc: CanvasDocument?
    @Published var selectedID: UUID?
    @Published var mode: EditorMode = .move {
        didSet { modeChanged(from: oldValue) }
    }
    @Published var cropRect: CGRect = .zero
    @Published var cropAspect: CropAspect = .free {
        didSet { refitCrop() }
    }
    @Published var zoom: CGFloat?
    @Published var keepProportions = true
    @Published var busyMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Last zoom used by the canvas view (not published, used by zoom buttons).
    var displayZoom: CGFloat = 1

    private var undoStack: [CanvasDocument] = [] { didSet { canUndo = !undoStack.isEmpty } }
    private var redoStack: [CanvasDocument] = [] { didSet { canRedo = !redoStack.isEmpty } }
    private var drag: DragAction?
    private var pendingCheckpoint = false
    private var cropBeforeDrag: CGRect?
    private var lastTextEditLayer: UUID?

    private enum DragAction {
        case none
        case move(start: ImageLayer)
        case scale(start: ImageLayer)
        case rotate(start: ImageLayer)
        case corner(index: Int, start: [CGPoint])
        case moveCorners(start: [CGPoint])
        case cropMove(start: CGRect)
        case cropResize(anchor: CGPoint)
        case cropNew(anchor: CGPoint)
    }

    // MARK: Selection

    var selectedIndex: Int? {
        guard let id = selectedID else { return nil }
        return doc?.layers.firstIndex { $0.id == id }
    }

    var selectedLayer: ImageLayer? {
        guard let i = selectedIndex else { return nil }
        return doc?.layers[i]
    }

    func select(_ id: UUID?) {
        selectedID = id
        if mode == .distort { ensureCorners() }
    }

    func updateSelected(_ change: (inout ImageLayer) -> Void) {
        guard let i = selectedIndex, doc != nil else { return }
        change(&doc!.layers[i])
    }

    // MARK: History

    func checkpoint() {
        guard let doc else { return }
        lastTextEditLayer = nil
        undoStack.append(doc)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack = []
    }

    func undo() {
        guard let previous = undoStack.popLast(), let current = doc else { return }
        redoStack.append(current)
        doc = previous
        if mode == .crop { refitCrop() }
        validateSelection()
    }

    func redo() {
        guard let next = redoStack.popLast(), let current = doc else { return }
        undoStack.append(current)
        doc = next
        if mode == .crop { refitCrop() }
        validateSelection()
    }

    private func validateSelection() {
        if selectedIndex == nil { selectedID = nil }
    }

    // MARK: Canvas

    func newCanvas(_ setup: CanvasSetup) {
        doc = setup.makeDocument()
        resetEditorState()
    }

    func closeCanvas() {
        doc = nil
        resetEditorState()
    }

    private func resetEditorState() {
        undoStack = []
        redoStack = []
        selectedID = nil
        mode = .move
        zoom = nil
    }

    func openImageAsCanvas(_ url: URL) {
        guard let loaded = ImageLoader.load(url: url) else {
            errorMessage = "“\(url.lastPathComponent)” isn't an image that can be opened."
            return
        }
        var newDoc = CanvasDocument(width: loaded.naturalSize.width, height: loaded.naturalSize.height,
                                    dpi: loaded.dpi ?? 72, isPhysical: false)
        newDoc.backgroundKind = .transparent
        let layer = ImageLayer(name: loaded.name, image: loaded.image, preview: loaded.preview,
                               center: CGPoint(x: newDoc.width / 2, y: newDoc.height / 2))
        newDoc.layers = [layer]
        doc = newDoc
        resetEditorState()
        selectedID = layer.id
    }

    func rotateCanvas(clockwise: Bool) {
        guard let current = doc else { return }
        checkpoint()
        let w = current.width, h = current.height
        func rotatePoint(_ p: CGPoint) -> CGPoint {
            clockwise ? CGPoint(x: h - p.y, y: p.x) : CGPoint(x: p.y, y: w - p.x)
        }
        doc!.width = h
        doc!.height = w
        for i in doc!.layers.indices {
            doc!.layers[i].center = rotatePoint(doc!.layers[i].center)
            doc!.layers[i].rotation = Self.normalize(doc!.layers[i].rotation + (clockwise ? 90 : -90))
            doc!.layers[i].corners = doc!.layers[i].corners?.map(rotatePoint)
        }
        if mode == .crop { refitCrop() }
    }

    var backgroundKindBinding: Binding<BackgroundKind> {
        Binding(get: { self.doc?.backgroundKind ?? .white },
                set: { value in self.checkpoint(); self.doc?.backgroundKind = value })
    }

    var backgroundColorBinding: Binding<Color> {
        Binding(get: { self.doc?.backgroundRGB.color ?? .white },
                set: { value in self.doc?.backgroundRGB = RGB(value) })
    }

    // MARK: Adding layers

    func presentAddImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf]
        panel.prompt = "Add"
        panel.message = "Choose images (PNG, JPEG, HEIC, TIFF, WebP…) or a PDF"
        if panel.runModal() == .OK { addImages(urls: panel.urls) }
    }

    func addImages(urls: [URL]) {
        let loaded = urls.filter(\.isFileURL).compactMap { ImageLoader.load(url: $0) }
        guard !loaded.isEmpty else {
            if !urls.isEmpty { errorMessage = "Those files aren't images that can be opened." }
            return
        }
        checkpoint()
        for item in loaded { insertLayer(from: item) }
    }

    func pasteImage() {
        guard let loaded = ImageLoader.fromPasteboard() else {
            errorMessage = "There's no image on the clipboard."
            return
        }
        checkpoint()
        insertLayer(from: loaded)
    }

    private func insertLayer(from loaded: ImageLoader.Loaded) {
        guard let current = doc else { return }
        let size = loaded.naturalSize
        // Shrink to fit (with a margin) if bigger than the canvas; never enlarge.
        let fit = min(current.width * 0.9 / max(1, size.width), current.height * 0.9 / max(1, size.height), 1)
        var layer = ImageLayer(name: loaded.name, image: loaded.image, preview: loaded.preview,
                               center: CGPoint(x: current.width / 2, y: current.height / 2))
        layer.scaleX = fit
        layer.scaleY = fit
        doc!.layers.append(layer)
        selectedID = layer.id
        if mode != .move { mode = .move }
    }

    func addText() {
        guard let current = doc else { return }
        var content = TextContent()
        content.fontSize = max(12, (current.height / 12).rounded())
        guard let image = CanvasTextRenderer.render(content) else { return }
        checkpoint()
        var layer = ImageLayer(name: "Text", image: image, preview: ImageLoader.makePreview(image),
                               center: CGPoint(x: current.width / 2, y: current.height / 2))
        layer.scaleX = 1 / TextContent.renderScale
        layer.scaleY = 1 / TextContent.renderScale
        layer.text = content
        doc!.layers.append(layer)
        selectedID = layer.id
        mode = .move
    }

    func updateText(_ change: (inout TextContent) -> Void) {
        guard let layer = selectedLayer, var content = layer.text else { return }
        change(&content)
        guard content != layer.text, let image = CanvasTextRenderer.render(content) else { return }
        let preview = ImageLoader.makePreview(image)
        updateSelected { l in
            l.text = content
            l.image = image
            l.preview = preview
            l.filteredPreview = nil
            l.name = content.string.split(separator: "\n").first.map(String.init) ?? "Text"
        }
        refreshPreview()
    }

    func textBinding<T>(_ keyPath: WritableKeyPath<TextContent, T>, default value: T) -> Binding<T> {
        Binding(get: { self.selectedLayer?.text?[keyPath: keyPath] ?? value },
                set: { newValue in
                    let isTyping = (keyPath as AnyKeyPath) == (\TextContent.string as AnyKeyPath)
                    if isTyping {
                        // One undo step per typing session on a layer.
                        if self.lastTextEditLayer != self.selectedID {
                            self.checkpoint()
                            self.lastTextEditLayer = self.selectedID
                        }
                    } else {
                        self.checkpoint()
                    }
                    self.updateText { $0[keyPath: keyPath] = newValue }
                })
    }

    // MARK: Layer commands

    func deleteSelected() {
        guard let i = selectedIndex else { return }
        checkpoint()
        doc!.layers.remove(at: i)
        selectedID = nil
    }

    func duplicateSelected() {
        guard let i = selectedIndex, let original = doc?.layers[i] else { return }
        checkpoint()
        var copy = ImageLayer(name: original.name + " copy", image: original.image, preview: original.preview,
                              center: original.center + CGPoint(x: 30, y: 30))
        copy.filteredPreview = original.filteredPreview
        copy.scaleX = original.scaleX
        copy.scaleY = original.scaleY
        copy.rotation = original.rotation
        copy.skewX = original.skewX
        copy.skewY = original.skewY
        copy.flipH = original.flipH
        copy.flipV = original.flipV
        copy.opacity = original.opacity
        copy.corners = original.corners?.map { $0 + CGPoint(x: 30, y: 30) }
        copy.adjustments = original.adjustments
        copy.text = original.text
        doc!.layers.insert(copy, at: i + 1)
        selectedID = copy.id
    }

    func moveSelected(by offset: Int) {
        guard let i = selectedIndex, let count = doc?.layers.count else { return }
        let j = i + offset
        guard j >= 0, j < count else { return }
        checkpoint()
        doc!.layers.swapAt(i, j)
    }

    func toggleHidden(_ id: UUID) {
        guard let i = doc?.layers.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        doc!.layers[i].isHidden.toggle()
    }

    func fitSelected(fill: Bool) {
        guard let current = doc, let layer = selectedLayer else { return }
        checkpoint()
        let w = layer.naturalSize.width, h = layer.naturalSize.height
        let rotated = abs(Int(layer.rotation.rounded())) % 180 == 90
        let bw = rotated ? h : w, bh = rotated ? w : h
        let sx = current.width / max(1, bw), sy = current.height / max(1, bh)
        let s = fill ? max(sx, sy) : min(sx, sy)
        updateSelected { l in
            l.corners = nil
            l.skewX = 0
            l.skewY = 0
            l.scaleX = s
            l.scaleY = s
            l.center = CGPoint(x: current.width / 2, y: current.height / 2)
        }
    }

    func centerSelected() {
        guard let current = doc, let layer = selectedLayer else { return }
        checkpoint()
        let offset = CGPoint(x: current.width / 2, y: current.height / 2) - Geometry.centroid(layer.quad)
        updateSelected { l in
            l.center = l.center + offset
            l.corners = l.corners?.map { $0 + offset }
        }
    }

    func resetSelectedTransform() {
        checkpoint()
        updateSelected { $0.resetTransform() }
    }

    func rotateSelected(by degrees: CGFloat) {
        checkpoint()
        updateSelected { $0.rotation = Self.normalize($0.rotation + degrees) }
    }

    func flipSelected(horizontal: Bool) {
        checkpoint()
        updateSelected { l in
            if horizontal { l.flipH.toggle() } else { l.flipV.toggle() }
        }
    }

    func removeDistortion() {
        checkpoint()
        updateSelected { $0.corners = nil }
        // Stay editable in Distort mode: start again from the plain outline.
        if mode == .distort { ensureCorners() }
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        guard selectedLayer != nil else { return }
        checkpoint()
        let delta = CGPoint(x: dx, y: dy)
        updateSelected { l in
            l.center = l.center + delta
            l.corners = l.corners?.map { $0 + delta }
        }
    }

    // MARK: Bindings for the inspector

    func layerBinding<T>(_ keyPath: WritableKeyPath<ImageLayer, T>, default value: T) -> Binding<T> {
        Binding(get: { self.selectedLayer?[keyPath: keyPath] ?? value },
                set: { newValue in self.updateSelected { $0[keyPath: keyPath] = newValue } })
    }

    /// Size slider works on a log scale (1.5 % … 800 %) so small and large sizes are both easy to set.
    var logScaleBinding: Binding<CGFloat> {
        Binding(get: { log2(max(0.0001, self.selectedLayer?.scaleX ?? 1)) },
                set: { value in
                    self.updateSelected { l in
                        let ratio = l.scaleY / max(0.0001, l.scaleX)
                        l.scaleX = pow(2, value)
                        l.scaleY = l.scaleX * ratio
                    }
                })
    }

    func percentBinding(_ keyPath: WritableKeyPath<ImageLayer, CGFloat>) -> Binding<CGFloat> {
        Binding(get: { (self.selectedLayer?[keyPath: keyPath] ?? 1) * 100 },
                set: { value in self.updateSelected { $0[keyPath: keyPath] = max(1, value) / 100 } })
    }

    func adjustmentBinding<T>(_ keyPath: WritableKeyPath<LayerAdjustments, T>, default value: T) -> Binding<T> {
        Binding(get: { self.selectedLayer?.adjustments[keyPath: keyPath] ?? value },
                set: { newValue in
                    self.updateSelected { $0.adjustments[keyPath: keyPath] = newValue }
                    self.refreshPreview()
                })
    }

    func resetAdjustments() {
        checkpoint()
        updateSelected { l in
            l.adjustments = LayerAdjustments()
            l.filteredPreview = nil
        }
    }

    /// Re-applies the selected layer's adjustments to its preview in the background.
    func refreshPreview() {
        guard let layer = selectedLayer else { return }
        let id = layer.id
        let adjustments = layer.adjustments
        let preview = layer.preview
        if adjustments.isIdentity {
            updateSelected { $0.filteredPreview = nil }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let filtered = ImageFilters.apply(adjustments, to: preview)
            DispatchQueue.main.async {
                guard let i = self.doc?.layers.firstIndex(where: { $0.id == id }),
                      self.doc?.layers[i].adjustments == adjustments else { return }
                self.doc!.layers[i].filteredPreview = filtered
            }
        }
    }

    // MARK: On-device AI

    func runAI(_ action: AIAction) {
        guard let layer = selectedLayer, busyMessage == nil else { return }
        let id = layer.id
        let source = layer.image
        busyMessage = action.busyText

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result: CGImage
                switch action {
                case .removeBackground: result = try ImageAI.removeBackground(source)
                case .straightenDocument: result = try ImageAI.straightenDocument(source)
                }
                let preview = ImageLoader.makePreview(result)
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    guard let i = self.doc?.layers.firstIndex(where: { $0.id == id }) else { return }
                    self.checkpoint()
                    let old = self.doc!.layers[i]
                    // Keep roughly the same on-canvas width.
                    let shownWidth = old.naturalSize.width * old.scaleX
                    let scale = shownWidth / max(1, CGFloat(result.width))
                    self.doc!.layers[i].image = result
                    self.doc!.layers[i].preview = preview
                    self.doc!.layers[i].filteredPreview = nil
                    self.doc!.layers[i].corners = nil
                    self.doc!.layers[i].skewX = 0
                    self.doc!.layers[i].skewY = 0
                    self.doc!.layers[i].scaleX = scale
                    self.doc!.layers[i].scaleY = scale
                    if action == .straightenDocument { self.doc!.layers[i].rotation = 0 }
                    self.refreshPreview()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busyMessage = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: Zoom

    func zoom(by factor: CGFloat) {
        zoom = min(8, max(0.05, displayZoom * factor))
    }

    // MARK: Modes & crop

    private func modeChanged(from oldMode: EditorMode) {
        if oldMode == .distort && mode != .distort { dropUnchangedCorners() }
        switch mode {
        case .crop:
            refitCrop()
        case .distort:
            ensureCorners()
        case .move:
            break
        }
    }

    /// Layers that entered Distort but were never actually distorted go back to normal transforms.
    private func dropUnchangedCorners() {
        guard doc != nil else { return }
        for i in doc!.layers.indices {
            guard let corners = doc!.layers[i].corners else { continue }
            let plain = doc!.layers[i].affineQuad
            let unchanged = zip(corners, plain).allSatisfy { $0.distance(to: $1) < 0.5 }
            if unchanged { doc!.layers[i].corners = nil }
        }
    }

    private func ensureCorners() {
        guard let layer = selectedLayer, layer.corners == nil else { return }
        let quad = layer.quad
        updateSelected { $0.corners = quad }
    }

    var cropRatio: CGFloat? {
        guard let doc else { return nil }
        return cropAspect.ratio(canvas: doc.size)
    }

    func refitCrop() {
        guard let doc else { return }
        let bounds = doc.bounds
        guard let ratio = cropRatio else {
            cropRect = bounds
            return
        }
        var w = bounds.width
        var h = w / ratio
        if h > bounds.height {
            h = bounds.height
            w = h * ratio
        }
        cropRect = CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    func applyCrop() {
        guard doc != nil else { return }
        let r = cropRect.standardized
        let rect = CGRect(x: r.minX.rounded(), y: r.minY.rounded(),
                          width: max(1, r.width.rounded()), height: max(1, r.height.rounded()))
        checkpoint()
        let origin = rect.origin
        doc!.width = rect.width
        doc!.height = rect.height
        for i in doc!.layers.indices {
            doc!.layers[i].center = doc!.layers[i].center - origin
            doc!.layers[i].corners = doc!.layers[i].corners?.map { $0 - origin }
        }
        mode = .move
    }

    // MARK: Mouse handling (points are in view coordinates relative to the canvas origin)

    func rotationHandle(for layer: ImageLayer, zoom: CGFloat) -> CGPoint {
        let q = layer.quad
        let center = Geometry.centroid(q)
        let top = (q[0] + q[1]) / 2
        var direction = top - center
        let length = hypot(direction.x, direction.y)
        direction = length > 0 ? direction / length : CGPoint(x: 0, y: -1)
        return top + direction * (28 / max(zoom, 0.01))
    }

    func dragChanged(start: CGPoint, current: CGPoint, zoom: CGFloat, snap: Bool) {
        guard doc != nil, zoom > 0 else { return }
        let p = start / zoom
        let q = current / zoom
        if drag == nil { drag = beginDrag(at: p, zoom: zoom) }
        guard let action = drag else { return }
        let delta = q - p
        if pendingCheckpoint, delta.x != 0 || delta.y != 0 {
            checkpoint()
            pendingCheckpoint = false
        }

        switch action {
        case .none:
            break
        case .move(let s):
            updateSelected { $0.center = s.center + delta }
        case .scale(let s):
            let d0 = s.center.distance(to: p)
            guard d0 > 0.5 else { return }
            let factor = s.center.distance(to: q) / d0
            updateSelected { l in
                l.scaleX = max(0.005, s.scaleX * factor)
                l.scaleY = max(0.005, s.scaleY * factor)
            }
        case .rotate(let s):
            let a0 = atan2(p.y - s.center.y, p.x - s.center.x)
            let a1 = atan2(q.y - s.center.y, q.x - s.center.x)
            var degrees = Self.normalize(s.rotation + (a1 - a0) * 180 / .pi)
            if snap { degrees = (degrees / 15).rounded() * 15 }
            updateSelected { $0.rotation = degrees }
        case .corner(let index, let s):
            var corners = s
            corners[index] = s[index] + delta
            updateSelected { $0.corners = corners }
        case .moveCorners(let s):
            updateSelected { $0.corners = s.map { $0 + delta } }
        case .cropMove(let r):
            cropRect = r.offsetBy(dx: delta.x, dy: delta.y)
        case .cropResize(let anchor), .cropNew(let anchor):
            cropRect = Geometry.rect(from: anchor, to: q, ratio: cropRatio)
        }
    }

    func dragEnded() {
        drag = nil
        pendingCheckpoint = false
        if mode == .crop, cropRect.width < 4 || cropRect.height < 4 {
            if let previous = cropBeforeDrag { cropRect = previous } else { refitCrop() }
        }
        cropBeforeDrag = nil
    }

    private func hitLayer(at p: CGPoint) -> UUID? {
        doc?.layers.reversed().first { !$0.isHidden && Geometry.contains($0.quad, p) }?.id
    }

    private func beginDrag(at p: CGPoint, zoom: CGFloat) -> DragAction {
        guard let current = doc else { return .none }
        let tolerance = 14 / zoom

        switch mode {
        case .crop:
            let r = cropRect
            cropBeforeDrag = r
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
            if let i = corners.firstIndex(where: { $0.distance(to: p) <= tolerance }) {
                return .cropResize(anchor: corners[(i + 2) % 4])
            }
            if r.contains(p) { return .cropMove(start: r) }
            return .cropNew(anchor: p)

        case .distort:
            if let i = selectedIndex, let c = current.layers[i].corners {
                if let k = c.firstIndex(where: { $0.distance(to: p) <= tolerance }) {
                    pendingCheckpoint = true
                    return .corner(index: k, start: c)
                }
                if Geometry.contains(c, p) {
                    pendingCheckpoint = true
                    return .moveCorners(start: c)
                }
            }
            if let hit = hitLayer(at: p) {
                select(hit)
                if let c = selectedLayer?.corners {
                    pendingCheckpoint = true
                    return .moveCorners(start: c)
                }
            }
            return .none

        case .move:
            if let i = selectedIndex {
                let layer = current.layers[i]
                if layer.corners == nil {
                    if rotationHandle(for: layer, zoom: zoom).distance(to: p) <= tolerance {
                        pendingCheckpoint = true
                        return .rotate(start: layer)
                    }
                    if layer.quad.contains(where: { $0.distance(to: p) <= tolerance }) {
                        pendingCheckpoint = true
                        return .scale(start: layer)
                    }
                }
                if Geometry.contains(layer.quad, p) {
                    pendingCheckpoint = true
                    return layer.corners.map { DragAction.moveCorners(start: $0) } ?? DragAction.move(start: layer)
                }
            }
            if let hit = hitLayer(at: p), let layer = current.layers.first(where: { $0.id == hit }) {
                selectedID = hit
                pendingCheckpoint = true
                return layer.corners.map { DragAction.moveCorners(start: $0) } ?? DragAction.move(start: layer)
            }
            selectedID = nil
            return .none
        }
    }

    static func normalize(_ degrees: CGFloat) -> CGFloat {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
