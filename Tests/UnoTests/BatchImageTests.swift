import XCTest
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import Uno

final class BatchImageTests: XCTestCase {
    private var dir: URL!
    private var out: URL!

    override func setUp() {
        dir = Fixtures.tempDir()
        out = Fixtures.tempDir()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: out)
    }

    private func photo(_ name: String, width: Int = 2000, height: Int = 1000, type: UTType = .jpeg,
                       properties: [CFString: Any] = [:]) -> InputItem {
        let url = Fixtures.write(Fixtures.makeImage(width: width, height: height, color: Fixtures.red, text: "Sample"),
                                 to: dir.appendingPathComponent(name), type: type, properties: properties)
        return Fixtures.item(url)
    }

    private func run(_ items: [InputItem], _ options: BatchOptions) -> BatchImageEngine.Summary {
        BatchImageEngine.run(items, options: options, folder: out, progress: { _ in })
    }

    // MARK: Resize plans

    func testResizePlans() {
        let size = CGSize(width: 4000, height: 3000)
        var o = BatchOptions()

        o.resize = .percent; o.percent = 25
        XCTAssertEqual(BatchImageEngine.plan(for: size, options: o).canvas, CGSize(width: 1000, height: 750))

        o.resize = .longestSide; o.pixels = 1600
        XCTAssertEqual(BatchImageEngine.plan(for: size, options: o).canvas, CGSize(width: 1600, height: 1200))

        o.resize = .width; o.pixels = 800
        XCTAssertEqual(BatchImageEngine.plan(for: size, options: o).canvas, CGSize(width: 800, height: 600))

        o.resize = .height; o.pixels = 300
        XCTAssertEqual(BatchImageEngine.plan(for: size, options: o).canvas, CGSize(width: 400, height: 300))

        o.resize = .fitBox; o.boxWidth = 1000; o.boxHeight = 1000
        XCTAssertEqual(BatchImageEngine.plan(for: size, options: o).canvas, CGSize(width: 1000, height: 750))

        o.resize = .exactFill; o.boxWidth = 500; o.boxHeight = 500
        let fill = BatchImageEngine.plan(for: size, options: o)
        XCTAssertEqual(fill.canvas, CGSize(width: 500, height: 500))
        XCTAssertGreaterThanOrEqual(fill.content.width, 499.999, "crop-to-fill covers the whole box")
        XCTAssertGreaterThanOrEqual(fill.content.height, 499.999)

        o.resize = nil
        XCTAssertEqual(BatchImageEngine.plan(for: size, options: o).canvas, size)
    }

    func testDontEnlargeExceptForPercentage() {
        var o = BatchOptions()
        o.resize = .longestSide; o.pixels = 5000; o.dontEnlarge = true
        XCTAssertEqual(BatchImageEngine.plan(for: CGSize(width: 1000, height: 500), options: o).canvas, CGSize(width: 1000, height: 500))
        o.dontEnlarge = false
        XCTAssertEqual(BatchImageEngine.plan(for: CGSize(width: 1000, height: 500), options: o).canvas, CGSize(width: 5000, height: 2500))
        o.resize = .percent; o.percent = 150; o.dontEnlarge = true
        XCTAssertEqual(BatchImageEngine.plan(for: CGSize(width: 100, height: 100), options: o).canvas, CGSize(width: 150, height: 150))
    }

    func testOrientedSizeHonoursRotationFlag() {
        let url = Fixtures.write(Fixtures.makeImage(width: 400, height: 200, color: Fixtures.red),
                                 to: dir.appendingPathComponent("rotated.jpg"), type: .jpeg,
                                 properties: [kCGImagePropertyOrientation: 6])
        XCTAssertEqual(BatchImageEngine.orientedSize(of: url), CGSize(width: 200, height: 400))
    }

    // MARK: Running

    func testResizeWritesSmallerFilesWithSuffix() throws {
        var o = BatchOptions.resizeDefaults
        o.pixels = 500
        let summary = run([photo("a.jpg"), photo("b.jpg")], o)
        XCTAssertEqual(summary.failures, [])
        XCTAssertEqual(summary.outputs.map(\.lastPathComponent), ["a-resized.jpg", "b-resized.jpg"])
        let image = try XCTUnwrap(Fixtures.loadImage(summary.outputs[0]))
        XCTAssertEqual(max(image.width, image.height), 500)
        XCTAssertLessThan(summary.bytesOut, summary.bytesIn)
    }

    func testConvertToEachWritableFormat() throws {
        let item = photo("source.png", width: 300, height: 200, type: .png)
        for format in OutputFormatOption.available where !format.isPDF {
            var o = BatchOptions.convertDefaults
            o.format = format
            let summary = run([item], o)
            if summary.outputs.isEmpty && format.id == UTType.heic.identifier {
                continue // Macs without a hardware HEIC encoder can't save HEIC
            }
            XCTAssertEqual(summary.outputs.count, 1, "\(format.label) failed: \(summary.failures)")
            guard let output = summary.outputs.first else { continue }
            XCTAssertEqual(output.pathExtension, format.fileExtension)
            XCTAssertNotNil(Fixtures.loadImage(output), "\(format.label) output can be opened")
        }
    }

    func testOriginalFormatIsKept() {
        var o = BatchOptions.resizeDefaults
        o.format = .original
        let summary = run([photo("pic.png", type: .png)], o)
        XCTAssertEqual(summary.outputs.first?.pathExtension, "png")
    }

    func testJPEGFillsTransparencyWithChosenColour() throws {
        let url = Fixtures.write(Fixtures.makeImage(width: 200, height: 200, color: Fixtures.red, transparentEdges: true),
                                 to: dir.appendingPathComponent("logo.png"))
        var o = BatchOptions.convertDefaults
        o.background = RGB(r: 0, g: 0, b: 1)
        let summary = run([Fixtures.item(url)], o)
        let image = try XCTUnwrap(summary.outputs.first.flatMap(Fixtures.loadImage))
        XCTAssertTrue(Fixtures.pixel(image, x: 5, y: 5).isBluish)
        XCTAssertTrue(Fixtures.pixel(image, x: 100, y: 100).isReddish)
    }

    func testFileSizeLimitIsRespected() throws {
        var o = BatchOptions.convertDefaults
        o.limitFileSize = true
        o.maxKilobytes = 60
        let summary = run([photo("large.jpg", width: 3000, height: 3000)], o)
        let output = try XCTUnwrap(summary.outputs.first)
        XCTAssertLessThanOrEqual(Naming.fileSize(output), 60 * 1024)
    }

    func testRemovingLocationData() throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 47.5, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 19.0, kCGImagePropertyGPSLongitudeRef: "E"]
        let item = photo("trip.jpg", properties: [kCGImagePropertyGPSDictionary: gps])
        XCTAssertNotNil(Fixtures.properties(item.url)[kCGImagePropertyGPSDictionary])

        var keep = BatchOptions.convertDefaults
        keep.suffix = "-keep"
        let kept = try XCTUnwrap(run([item], keep).outputs.first)
        XCTAssertNotNil(Fixtures.properties(kept)[kCGImagePropertyGPSDictionary], "location kept by default")

        var strip = BatchOptions.convertDefaults
        strip.stripMetadata = true
        strip.suffix = "-clean"
        let cleaned = try XCTUnwrap(run([item], strip).outputs.first)
        XCTAssertNil(Fixtures.properties(cleaned)[kCGImagePropertyGPSDictionary], "location removed")
    }

    func testNeverOverwritesExistingFiles() throws {
        let item = photo("same.jpg")
        var o = BatchOptions.convertDefaults
        o.suffix = ""
        let first = try XCTUnwrap(run([item], o).outputs.first)
        let second = try XCTUnwrap(run([item], o).outputs.first)
        XCTAssertEqual(first.lastPathComponent, "same.jpg")
        XCTAssertEqual(second.lastPathComponent, "same (2).jpg")
    }

    func testSaveNextToOriginalsLeavesOriginalUntouched() throws {
        let item = photo("orig.jpg")
        let before = Naming.fileSize(item.url)
        var o = BatchOptions.resizeDefaults
        o.saveNextToOriginals = true
        let summary = BatchImageEngine.run([item], options: o, folder: nil, progress: { _ in })
        XCTAssertEqual(summary.outputs.first?.deletingLastPathComponent().standardizedFileURL.path,
                       item.url.deletingLastPathComponent().standardizedFileURL.path)
        XCTAssertEqual(Naming.fileSize(item.url), before)
    }

    func testCombinedPDFKeepsListOrder() throws {
        let items = ["c.jpg", "a.jpg", "b.jpg"].map { photo($0, width: 400, height: 300) }
        var o = BatchOptions.convertDefaults
        o.format = .pdf
        o.combinePDF = true
        let summary = run(items, o)
        XCTAssertEqual(summary.outputs.count, 1)
        XCTAssertEqual(summary.outputs.first?.lastPathComponent, "c combined.pdf")
        XCTAssertEqual(PDFDocument(url: summary.outputs[0])?.pageCount, 3)
    }

    func testUnreadableFilesAreReportedNotFatal() throws {
        let broken = dir.appendingPathComponent("broken.jpg")
        try Data("not an image".utf8).write(to: broken)
        let good = photo("good.jpg")
        let summary = run([InputItem(url: broken, kind: .image, pageCount: 1), good], BatchOptions.convertDefaults)
        XCTAssertEqual(summary.outputs.count, 1)
        XCTAssertEqual(summary.failures, ["broken.jpg"])
    }

    func testFiltersAreAppliedInBatch() throws {
        var o = BatchOptions.convertDefaults
        o.adjustments.filter = .mono
        o.format = .png
        let summary = run([photo("colour.jpg", width: 300, height: 300)], o)
        let image = try XCTUnwrap(summary.outputs.first.flatMap(Fixtures.loadImage))
        let p = Fixtures.pixel(image, x: 10, y: 10)
        XCTAssertLessThan(abs(Int(p.r) - Int(p.b)), 12, "black & white filter removes colour")
    }

    func testStraightenFallsBackWhenNoDocumentFound() throws {
        var o = BatchOptions.convertDefaults
        o.straightenDocuments = true
        let summary = run([photo("plain.jpg", width: 600, height: 400)], o)
        XCTAssertEqual(summary.outputs.count, 1, "image is still saved")
    }

    func testAvailableFormatsAlwaysIncludeJPEGPNGAndPDF() {
        let ids = OutputFormatOption.available.map(\.id)
        XCTAssertTrue(ids.contains(UTType.jpeg.identifier))
        XCTAssertTrue(ids.contains(UTType.png.identifier))
        XCTAssertTrue(ids.contains(UTType.pdf.identifier))
    }
}
