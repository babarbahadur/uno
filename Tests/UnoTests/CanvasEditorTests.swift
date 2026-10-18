import XCTest
import PDFKit
import UniformTypeIdentifiers
@testable import Uno

final class CanvasGeometryTests: XCTestCase {

    func testHomographyMapsUnitSquareCornersToQuad() {
        let quad = [CGPoint(x: 10, y: 20), CGPoint(x: 210, y: 0), CGPoint(x: 230, y: 180), CGPoint(x: 0, y: 160)]
        let h = Homography.unitSquare(to: quad)
        func map(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            let w = h.g * u + h.h * v + 1
            return CGPoint(x: (h.a * u + h.b * v + h.c) / w, y: (h.d * u + h.e * v + h.f) / w)
        }
        for (corner, expected) in zip([(0, 0), (1, 0), (1, 1), (0, 1)] as [(CGFloat, CGFloat)], quad) {
            let p = map(corner.0, corner.1)
            XCTAssertEqual(p.x, expected.x, accuracy: 0.001)
            XCTAssertEqual(p.y, expected.y, accuracy: 0.001)
        }
    }

    func testPolygonContainsAndCentroid() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        XCTAssertTrue(Geometry.contains(square, CGPoint(x: 5, y: 5)))
        XCTAssertFalse(Geometry.contains(square, CGPoint(x: 15, y: 5)))
        XCTAssertEqual(Geometry.centroid(square), CGPoint(x: 5, y: 5))
    }

    func testRectWithAspectRatio() {
        let r = Geometry.rect(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 10), ratio: 2)
        XCTAssertEqual(r.width / r.height, 2, accuracy: 0.001)
        let free = Geometry.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 10, y: 20), ratio: nil)
        XCTAssertEqual(free, CGRect(x: 10, y: 20, width: 40, height: 30))
    }

    func testLayerOutlineFollowsTransform() {
        let image = Fixtures.makeImage(width: 100, height: 50, color: Fixtures.red)
        var layer = ImageLayer(name: "t", image: image, preview: image, center: CGPoint(x: 200, y: 200))
        XCTAssertEqual(layer.quad[0].x, 150, accuracy: 0.01)
        XCTAssertEqual(layer.quad[0].y, 175, accuracy: 0.01)
        layer.rotation = 90
        let q = layer.quad
        XCTAssertEqual(q[0].x, 225, accuracy: 0.01, "top-left swings to the right after 90° clockwise")
        XCTAssertEqual(q[0].y, 150, accuracy: 0.01)
        layer.scaleX = 2; layer.scaleY = 2; layer.rotation = 0
        XCTAssertEqual(layer.quad[1].x - layer.quad[0].x, 200, accuracy: 0.01)
    }

    func testCanvasPresetPixelSizes() {
        var setup = CanvasSetup()
        setup.presetID = "a4"; setup.dpi = 300
        XCTAssertEqual(setup.pixelSize, CGSize(width: 2480, height: 3508))
        setup.rotated = true
        XCTAssertEqual(setup.pixelSize, CGSize(width: 3508, height: 2480))
        setup.rotated = false
        setup.presetID = "idphoto"
        XCTAssertEqual(setup.pixelSize, CGSize(width: 413, height: 531))
        setup.presetID = "idcard"
        XCTAssertEqual(setup.pixelSize, CGSize(width: 1011, height: 638))
        setup.presetID = "fullhd"
        XCTAssertEqual(setup.pixelSize, CGSize(width: 1920, height: 1080), "pixel presets ignore dpi")
        setup.presetID = "custom"; setup.customUnit = .inch; setup.customWidth = 2; setup.customHeight = 3; setup.dpi = 150
        XCTAssertEqual(setup.pixelSize, CGSize(width: 300, height: 450))
        XCTAssertTrue(setup.makeDocument().isPhysical)
    }

    func testCropAspectRatios() {
        XCTAssertNil(CropAspect.free.ratio(canvas: CGSize(width: 10, height: 10)))
        XCTAssertEqual(CropAspect.original.ratio(canvas: CGSize(width: 300, height: 100)), 3)
        XCTAssertEqual(CropAspect.idPhoto.ratio(canvas: .zero)!, 35.0 / 45.0, accuracy: 0.0001)
    }
}

final class CanvasEditorModelTests: XCTestCase {
    private var dir: URL!
    private var model: CanvasEditorModel!

    override func setUp() {
        dir = Fixtures.tempDir()
        model = CanvasEditorModel()
        var setup = CanvasSetup()
        setup.presetID = "custom"; setup.customUnit = .px; setup.customWidth = 1000; setup.customHeight = 800
        model.newCanvas(setup)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func addImage(width: Int = 400, height: Int = 200, color: CGColor = Fixtures.red) -> ImageLayer {
        let url = Fixtures.write(Fixtures.makeImage(width: width, height: height, color: color),
                                 to: dir.appendingPathComponent("\(UUID().uuidString).png"))
        model.addImages(urls: [url])
        return model.selectedLayer!
    }

    private func drag(from a: CGPoint, to b: CGPoint, snap: Bool = false) {
        model.dragChanged(start: a, current: a, zoom: 1, snap: snap)
        model.dragChanged(start: a, current: b, zoom: 1, snap: snap)
        model.dragEnded()
    }

    func testNewCanvasStartsEmpty() {
        XCTAssertEqual(model.doc?.size, CGSize(width: 1000, height: 800))
        XCTAssertEqual(model.doc?.layers.count, 0)
        XCTAssertFalse(model.canUndo)
    }

    func testAddingImagesCentresAndShrinksToFit() {
        let small = addImage()
        XCTAssertEqual(small.center, CGPoint(x: 500, y: 400))
        XCTAssertEqual(small.scaleX, 1, "small images keep their size")
        let big = addImage(width: 4000, height: 2000)
        XCTAssertLessThan(big.scaleX, 1, "large images shrink to fit")
        XCTAssertEqual(model.doc?.layers.count, 2)
        XCTAssertEqual(model.selectedID, big.id)
    }

    func testUnreadableImageShowsError() throws {
        let bad = dir.appendingPathComponent("bad.png")
        try Data("nope".utf8).write(to: bad)
        model.addImages(urls: [bad])
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.doc?.layers.count, 0)
    }

    func testDragMovesSelectedLayerAndUndoRestores() {
        _ = addImage()
        drag(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 600, y: 450))
        XCTAssertEqual(model.selectedLayer?.center, CGPoint(x: 600, y: 450))
        model.undo()
        XCTAssertEqual(model.selectedLayer?.center, CGPoint(x: 500, y: 400))
        model.redo()
        XCTAssertEqual(model.selectedLayer?.center, CGPoint(x: 600, y: 450))
    }

    func testClickWithoutMovingDoesNotCreateUndoStep() {
        _ = addImage()
        model.undo() // remove the "add image" step
        _ = addImage()
        let undoBefore = model.canUndo
        drag(from: CGPoint(x: 500, y: 400), to: CGPoint(x: 500, y: 400))
        XCTAssertEqual(model.canUndo, undoBefore)
    }

    func testClickingEmptySpaceDeselects() {
        _ = addImage()
        drag(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 20, y: 20))
        XCTAssertNil(model.selectedID)
    }

    func testCornerHandleScales() {
        let layer = addImage()
        let corner = layer.quad[2] // bottom-right at (700, 500)
        let target = CGPoint(x: 500 + (corner.x - 500) * 2, y: 400 + (corner.y - 400) * 2)
        drag(from: corner, to: target)
        XCTAssertEqual(model.selectedLayer?.scaleX ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(model.selectedLayer?.scaleY ?? 0, 2, accuracy: 0.01)
    }

    func testRotationHandleRotatesAndSnaps() {
        let layer = addImage()
        let handle = model.rotationHandle(for: layer, zoom: 1)
        // Drag the handle from straight above the centre to straight right of it: +90°.
        let right = CGPoint(x: 500 + (400 - handle.y), y: 400)
        drag(from: handle, to: CGPoint(x: right.x, y: right.y + 3), snap: true)
        XCTAssertEqual(model.selectedLayer?.rotation ?? 0, 90, accuracy: 0.001)
    }

    func testCropMovesLayersAndResizesCanvas() {
        _ = addImage()
        model.mode = .crop
        XCTAssertEqual(model.cropRect, CGRect(x: 0, y: 0, width: 1000, height: 800))
        model.cropRect = CGRect(x: 100, y: 50, width: 600, height: 400)
        model.applyCrop()
        XCTAssertEqual(model.doc?.size, CGSize(width: 600, height: 400))
        XCTAssertEqual(model.selectedLayer?.center, CGPoint(x: 400, y: 350))
        XCTAssertEqual(model.mode, .move)
        model.undo()
        XCTAssertEqual(model.doc?.size, CGSize(width: 1000, height: 800))
    }

    func testCropAspectRefitsBox() {
        model.mode = .crop
        model.cropAspect = .square
        XCTAssertEqual(model.cropRect.width, model.cropRect.height, accuracy: 0.001)
        XCTAssertEqual(model.cropRect.height, 800, accuracy: 0.001)
    }

    func testRotateCanvasSwapsSizeAndTurnsLayers() {
        _ = addImage()
        model.rotateCanvas(clockwise: true)
        XCTAssertEqual(model.doc?.size, CGSize(width: 800, height: 1000))
        XCTAssertEqual(model.selectedLayer?.rotation, 90)
        XCTAssertEqual(model.selectedLayer?.center, CGPoint(x: 400, y: 500))
    }

    func testDistortModeOnlyKeepsCornersThatWereMoved() {
        _ = addImage()
        model.mode = .distort
        XCTAssertNotNil(model.selectedLayer?.corners)
        model.mode = .move
        XCTAssertNil(model.selectedLayer?.corners, "untouched corners are dropped")

        model.mode = .distort
        let corner = model.selectedLayer!.corners![0]
        drag(from: corner, to: CGPoint(x: corner.x - 40, y: corner.y - 30))
        model.mode = .move
        XCTAssertNotNil(model.selectedLayer?.corners, "real distortion is kept")
        model.removeDistortion()
        XCTAssertNil(model.selectedLayer?.corners)
    }

    func testLayerCommands() {
        let first = addImage(color: Fixtures.red)
        let second = addImage(color: Fixtures.blue)
        model.duplicateSelected()
        XCTAssertEqual(model.doc?.layers.count, 3)
        XCTAssertEqual(model.selectedLayer?.name, second.name + " copy")

        model.moveSelected(by: -1)
        XCTAssertEqual(model.doc?.layers[1].id, model.selectedID)

        model.toggleHidden(first.id)
        XCTAssertEqual(model.doc?.layers.first?.isHidden, true)

        model.deleteSelected()
        XCTAssertEqual(model.doc?.layers.count, 2)
        XCTAssertNil(model.selectedID)
    }

    func testFitFillCentreResetFlipNudge() {
        _ = addImage(width: 400, height: 200)
        model.fitSelected(fill: false)
        XCTAssertEqual(model.selectedLayer?.scaleX ?? 0, 2.5, accuracy: 0.001, "1000/400")
        model.fitSelected(fill: true)
        XCTAssertEqual(model.selectedLayer?.scaleX ?? 0, 4, accuracy: 0.001, "800/200")
        model.nudge(dx: 10, dy: -5)
        XCTAssertEqual(model.selectedLayer?.center, CGPoint(x: 510, y: 395))
        model.centerSelected()
        XCTAssertEqual(model.selectedLayer?.center, CGPoint(x: 500, y: 400))
        model.flipSelected(horizontal: true)
        XCTAssertEqual(model.selectedLayer?.flipH, true)
        model.rotateSelected(by: 270)
        XCTAssertEqual(model.selectedLayer?.rotation, -90)
        model.resetSelectedTransform()
        XCTAssertEqual(model.selectedLayer?.scaleX, 1)
        XCTAssertEqual(model.selectedLayer?.flipH, false)
    }

    func testTextLayersRenderAndUpdate() {
        model.addText()
        let layer = model.selectedLayer!
        XCTAssertNotNil(layer.text)
        let firstWidth = layer.image.width
        model.updateText { $0.string = "A much longer line of text" }
        XCTAssertGreaterThan(model.selectedLayer!.image.width, firstWidth)
        XCTAssertEqual(model.selectedLayer?.name, "A much longer line of text")
    }

    func testOpenImageAsCanvasUsesImageSize() {
        let url = Fixtures.write(Fixtures.makeImage(width: 640, height: 480, color: Fixtures.red), to: dir.appendingPathComponent("p.png"))
        model.openImageAsCanvas(url)
        XCTAssertEqual(model.doc?.size, CGSize(width: 640, height: 480))
        XCTAssertEqual(model.doc?.layers.count, 1)
        XCTAssertEqual(model.doc?.backgroundKind, .transparent)
    }
}

final class CanvasRenderTests: XCTestCase {

    private func document(width: CGFloat = 200, height: CGFloat = 100) -> CanvasDocument {
        CanvasDocument(width: width, height: height, dpi: 300, isPhysical: true)
    }

    private func layer(_ image: CGImage, at center: CGPoint) -> ImageLayer {
        ImageLayer(name: "l", image: image, preview: image, center: center)
    }

    func testRenderPlacesLayerCorrectly() throws {
        var doc = document()
        doc.layers = [layer(Fixtures.makeImage(width: 40, height: 40, color: Fixtures.red), at: CGPoint(x: 50, y: 50))]
        let image = try XCTUnwrap(CanvasRenderer.render(doc, scale: 1, opaque: true))
        XCTAssertEqual(image.width, 200)
        XCTAssertTrue(Fixtures.pixel(image, x: 50, y: 50).isReddish)
        XCTAssertTrue(Fixtures.pixel(image, x: 150, y: 50).isWhitish, "white background")
    }

    func testRenderKeepsLeftRightOrientationAndFlips() throws {
        var doc = document()
        var l = layer(Fixtures.makeSplitImage(width: 200, height: 100), at: CGPoint(x: 100, y: 50))
        doc.layers = [l]
        var image = try XCTUnwrap(CanvasRenderer.render(doc, scale: 1, opaque: true))
        XCTAssertTrue(Fixtures.pixel(image, x: 20, y: 50).isReddish)
        XCTAssertTrue(Fixtures.pixel(image, x: 180, y: 50).isBluish)
        l.flipH = true
        doc.layers = [l]
        image = try XCTUnwrap(CanvasRenderer.render(doc, scale: 1, opaque: true))
        XCTAssertTrue(Fixtures.pixel(image, x: 20, y: 50).isBluish, "flipped horizontally")
    }

    func testRenderScalesAndHidesLayers() throws {
        var doc = document()
        var l = layer(Fixtures.makeImage(width: 40, height: 40, color: Fixtures.red), at: CGPoint(x: 100, y: 50))
        doc.layers = [l]
        let double = try XCTUnwrap(CanvasRenderer.render(doc, scale: 2, opaque: true))
        XCTAssertEqual(double.width, 400)
        XCTAssertTrue(Fixtures.pixel(double, x: 200, y: 100).isReddish)
        l.isHidden = true
        doc.layers = [l]
        let hidden = try XCTUnwrap(CanvasRenderer.render(doc, scale: 1, opaque: true))
        XCTAssertTrue(Fixtures.pixel(hidden, x: 100, y: 50).isWhitish)
    }

    func testTransparentBackgroundStaysTransparentInPNG() throws {
        var doc = document()
        doc.backgroundKind = .transparent
        let image = try XCTUnwrap(CanvasRenderer.render(doc, scale: 1, opaque: false))
        XCTAssertEqual(Fixtures.pixel(image, x: 10, y: 10).a, 0)
    }

    func testDistortedLayerIsWarped() throws {
        var doc = document()
        var l = layer(Fixtures.makeImage(width: 100, height: 100, color: Fixtures.red), at: CGPoint(x: 100, y: 50))
        l.corners = [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10), CGPoint(x: 60, y: 90), CGPoint(x: 10, y: 90)]
        doc.layers = [l]
        let image = try XCTUnwrap(CanvasRenderer.render(doc, scale: 1, opaque: true))
        XCTAssertTrue(Fixtures.pixel(image, x: 35, y: 50).isReddish, "inside the new corners")
        XCTAssertTrue(Fixtures.pixel(image, x: 150, y: 50).isWhitish, "outside the new corners")
    }

    func testExportFormatsAndResolution() throws {
        let dir = Fixtures.tempDir()
        var doc = document(width: 413, height: 531) // 35 × 45 mm at 300 dpi
        doc.layers = [layer(Fixtures.makeImage(width: 100, height: 100, color: Fixtures.blue), at: CGPoint(x: 200, y: 260))]
        let resolutions = CanvasRenderer.resolutions(for: doc)
        XCTAssertEqual(CanvasRenderer.defaultResolution(for: doc).dpi, 300)

        let low = try XCTUnwrap(resolutions.first { $0.dpi == 150 })
        let png = dir.appendingPathComponent("photo.png")
        try CanvasRenderer.export(doc, format: .png, resolution: low, quality: 0.9, to: png)
        let image = try XCTUnwrap(Fixtures.loadImage(png))
        XCTAssertEqual(image.width, 207, accuracy: 1)
        XCTAssertEqual((Fixtures.properties(png)[kCGImagePropertyDPIWidth] as? Double) ?? 0, 150, accuracy: 0.5)

        let jpg = dir.appendingPathComponent("photo.jpg")
        try CanvasRenderer.export(doc, format: .jpeg, resolution: CanvasRenderer.defaultResolution(for: doc), quality: 0.8, to: jpg)
        XCTAssertNotNil(Fixtures.loadImage(jpg))

        let pdf = dir.appendingPathComponent("photo.pdf")
        try CanvasRenderer.export(doc, format: .pdf, resolution: CanvasRenderer.defaultResolution(for: doc), quality: 0.9, to: pdf)
        let box = try XCTUnwrap(PDFDocument(url: pdf)?.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.width / 72 * 25.4, 35, accuracy: 0.3, "PDF keeps the real 35 mm width")
        XCTAssertEqual(box.height / 72 * 25.4, 45, accuracy: 0.3)
    }

    func testPixelResolutionsForScreenCanvases() {
        let doc = CanvasDocument(width: 1080, height: 1080, dpi: 72, isPhysical: false)
        let ids = CanvasRenderer.resolutions(for: doc).map(\.id)
        XCTAssertEqual(ids, ["scale25", "scale50", "scale100", "scale200"])
        XCTAssertEqual(CanvasRenderer.pixelSize(doc, scale: 0.5), CGSize(width: 540, height: 540))
    }
}

final class FilterTests: XCTestCase {

    func testIdentityReturnsSameImage() {
        let image = Fixtures.makeImage(width: 50, height: 50, color: Fixtures.red)
        XCTAssertTrue(ImageFilters.apply(LayerAdjustments(), to: image) === image)
    }

    func testEveryFilterKeepsSizeAndProducesAnImage() {
        let image = Fixtures.makeImage(width: 320, height: 240, color: Fixtures.red, text: "Scan me")
        for preset in FilterPreset.allCases {
            var adjustments = LayerAdjustments()
            adjustments.filter = preset
            let output = ImageFilters.apply(adjustments, to: image)
            XCTAssertEqual(output.width, 320, "\(preset)")
            XCTAssertEqual(output.height, 240, "\(preset)")
        }
    }

    func testScanFilterTurnsGreyPaperWhite() {
        let grey = Fixtures.makeImage(width: 400, height: 400, color: CGColor(srgbRed: 0.7, green: 0.7, blue: 0.68, alpha: 1))
        var adjustments = LayerAdjustments()
        adjustments.filter = .scanBW
        let output = ImageFilters.apply(adjustments, to: grey)
        XCTAssertTrue(Fixtures.pixel(output, x: 200, y: 200).isWhitish)
    }

    func testBrightnessAndSaturationSliders() {
        let image = Fixtures.makeImage(width: 60, height: 60, color: CGColor(srgbRed: 0.5, green: 0.2, blue: 0.2, alpha: 1))
        var brighter = LayerAdjustments()
        brighter.brightness = 0.3
        XCTAssertGreaterThan(Fixtures.pixel(ImageFilters.apply(brighter, to: image), x: 30, y: 30).g,
                             Fixtures.pixel(image, x: 30, y: 30).g)
        var grey = LayerAdjustments()
        grey.saturation = 0
        let p = Fixtures.pixel(ImageFilters.apply(grey, to: image), x: 30, y: 30)
        XCTAssertLessThan(abs(Int(p.r) - Int(p.g)), 6)
    }

    func testTextRenderer() throws {
        var content = TextContent()
        content.string = "Hello"
        let image = try XCTUnwrap(CanvasTextRenderer.render(content))
        XCTAssertGreaterThan(image.width, image.height)
        content.string = "Hello\nSecond line"
        let twoLines = try XCTUnwrap(CanvasTextRenderer.render(content))
        XCTAssertGreaterThan(twoLines.height, image.height)
    }

    func testStraightenDocumentFindsThePaper() throws {
        let photo = Fixtures.makeDocumentPhoto()
        do {
            let flat = try ImageAI.straightenDocument(photo)
            XCTAssertTrue(flat.width < photo.width || flat.height < photo.height, "cropped to the paper")
            XCTAssertFalse(Fixtures.pixel(flat, x: flat.width / 20, y: flat.height / 2).isDark, "the left margin is light paper")
        } catch CanvasError.noDocument {
            throw XCTSkip("Vision did not detect the synthetic document on this Mac")
        }
    }
}
