import XCTest
import PDFKit
import UniformTypeIdentifiers
@testable import Uno

final class PDFEngineTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = Fixtures.tempDir()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
    private func opener(_ url: URL, password: String? = nil) -> PDFOpener { PDFOpener(url: url, password: password) }
    private let noProgress: (Double) -> Void = { _ in }

    private func pageText(_ url: URL, _ index: Int) -> String {
        PDFDocument(url: url)?.page(at: index)?.string ?? ""
    }

    // MARK: Merge & images

    func testMergeCombinesPDFsAndImagesInOrder() throws {
        let a = Fixtures.makePDF(at: url("a.pdf"), pages: 2)
        let image = Fixtures.write(Fixtures.makeImage(width: 800, height: 600, color: Fixtures.red), to: url("photo.png"))
        let b = Fixtures.makePDF(at: url("b.pdf"), pages: 1)
        let output = url("merged.pdf")

        var lastProgress = 0.0
        let pages = try PDFEngine.combine([Fixtures.item(a), Fixtures.item(image), Fixtures.item(b)], to: output,
                                          options: CombineOptions(pageSize: .fitImage, quality: .high, ocr: false),
                                          progress: { lastProgress = $0 })
        XCTAssertEqual(pages, 4)
        XCTAssertEqual(PDFDocument(url: output)?.pageCount, 4)
        XCTAssertTrue(pageText(output, 0).contains("Page 1"))
        XCTAssertTrue(pageText(output, 1).contains("Page 2"))
        XCTAssertEqual(pageText(output, 2).trimmingCharacters(in: .whitespacesAndNewlines), "", "image page has no text")
        XCTAssertTrue(pageText(output, 3).contains("Page 1"))
        XCTAssertEqual(lastProgress, 1, accuracy: 0.001)
    }

    func testMergeRefusesLockedPDF() {
        let locked = Fixtures.makeLockedPDF(at: url("locked.pdf"), password: "secret")
        let item = InputItem(url: locked, kind: .pdf, pageCount: 2)
        XCTAssertThrowsError(try PDFEngine.combine([item], to: url("out.pdf"),
                                                   options: CombineOptions(pageSize: .fitImage, quality: .high, ocr: false),
                                                   progress: noProgress)) { error in
            XCTAssertTrue(error.localizedDescription.contains("password"))
        }
    }

    func testImagesToPDFUsesPaperSizeAndFlattensTransparency() throws {
        let image = Fixtures.write(Fixtures.makeImage(width: 600, height: 900, color: Fixtures.red, transparentEdges: true),
                                   to: url("logo.png"))
        let doc = try PDFEngine.imagePageDocument(for: Fixtures.item(image),
                                                  options: CombineOptions(pageSize: .a4, quality: .balanced, ocr: false))
        let page = try XCTUnwrap(doc.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 595.28, accuracy: 0.5)
        XCTAssertEqual(box.height, 841.89, accuracy: 0.5)

        let rendered = Fixtures.render(page: page)
        XCTAssertTrue(Fixtures.pixel(rendered, x: rendered.width / 2, y: rendered.height / 2).isReddish)
        XCTAssertTrue(Fixtures.pixel(rendered, x: 40, y: 60).isWhitish, "transparent areas become white")
    }

    func testImagesToSeparatePDFs() throws {
        let items = (1...3).map { i in
            Fixtures.item(Fixtures.write(Fixtures.makeImage(width: 200, height: 200, color: Fixtures.blue), to: url("img\(i).jpg"), type: .jpeg))
        }
        let out = Fixtures.tempDir()
        let urls = try PDFEngine.imagesToSeparatePDFs(items, options: CombineOptions(pageSize: .fitImage, quality: .small, ocr: false),
                                                      folder: out, progress: noProgress)
        XCTAssertEqual(urls.map(\.lastPathComponent).sorted(), ["img1.pdf", "img2.pdf", "img3.pdf"])
        XCTAssertTrue(urls.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 })
    }

    // MARK: Split, organize, extract

    func testSplitOnePagePerFile() throws {
        let src = Fixtures.makePDF(at: url("report.pdf"), pages: 3)
        let out = Fixtures.tempDir()
        let files = try PDFEngine.split(opener(src), pagesPerFile: 1, folder: out, progress: noProgress)
        XCTAssertEqual(files.map(\.lastPathComponent),
                       ["report - page 01.pdf", "report - page 02.pdf", "report - page 03.pdf"])
        XCTAssertTrue(pageText(files[2], 0).contains("Page 3"))
    }

    func testSplitIntoChunks() throws {
        let src = Fixtures.makePDF(at: url("report.pdf"), pages: 5)
        let files = try PDFEngine.split(opener(src), pagesPerFile: 2, folder: Fixtures.tempDir(), progress: noProgress)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.map { PDFDocument(url: $0)?.pageCount ?? 0 }, [2, 2, 1])
        XCTAssertEqual(files[0].lastPathComponent, "report - pages 01-02.pdf")
    }

    func testOrganizeReordersAndRotates() throws {
        let src = Fixtures.makePDF(at: url("doc.pdf"), pages: 3)
        let out = url("organized.pdf")
        let count = try PDFEngine.savePages(opener(src), pages: [
            PageSpec(index: 2, rotation: 90),
            PageSpec(index: 0, rotation: 0),
            PageSpec(index: 1, rotation: -90)
        ], to: out, progress: noProgress)
        XCTAssertEqual(count, 3)
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertTrue(doc.page(at: 0)!.string!.contains("Page 3"))
        XCTAssertTrue(doc.page(at: 1)!.string!.contains("Page 1"))
        XCTAssertEqual(doc.page(at: 0)!.rotation, 90)
        XCTAssertEqual(doc.page(at: 2)!.rotation, 270, "-90 is stored as 270")
    }

    func testDeletePagesKeepsOnlyChosenPages() throws {
        let src = Fixtures.makePDF(at: url("doc.pdf"), pages: 4)
        let out = url("edited.pdf")
        try PDFEngine.savePages(opener(src), pages: [PageSpec(index: 0, rotation: 0), PageSpec(index: 3, rotation: 0)],
                                to: out, progress: noProgress)
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 2)
        XCTAssertTrue(pageText(out, 1).contains("Page 4"))
    }

    func testSavingNoPagesFails() {
        let src = Fixtures.makePDF(at: url("doc.pdf"), pages: 1)
        XCTAssertThrowsError(try PDFEngine.savePages(opener(src), pages: [], to: url("empty.pdf"), progress: noProgress))
    }

    func testExtractSeparately() throws {
        let src = Fixtures.makePDF(at: url("doc.pdf"), pages: 5)
        let files = try PDFEngine.extractSeparately(opener(src), pages: [PageSpec(index: 1, rotation: 0), PageSpec(index: 4, rotation: 0)],
                                                    folder: Fixtures.tempDir(), progress: noProgress)
        XCTAssertEqual(files.map(\.lastPathComponent), ["doc - page 02.pdf", "doc - page 05.pdf"])
    }

    // MARK: Compress

    func testLightCompressionKeepsTextAndPages() throws {
        let src = Fixtures.makePDF(at: url("doc.pdf"), pages: 2)
        let out = url("small.pdf")
        let size = try PDFEngine.compress(opener(src), level: .light, ocr: false, to: out, progress: noProgress)
        XCTAssertGreaterThan(size, 0)
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 2)
        XCTAssertTrue(pageText(out, 0).contains("Page 1"))
    }

    func testStrongCompressionShrinksImageHeavyPDF() throws {
        // A merged PDF of a large, detailed photo-like image.
        let big = Fixtures.write(Fixtures.makeImage(width: 3000, height: 3000, color: Fixtures.blue, text: "Detail"), to: url("big.png"))
        let heavy = url("heavy.pdf")
        try PDFEngine.combine([Fixtures.item(big)], to: heavy, options: CombineOptions(pageSize: .a4, quality: .high, ocr: false),
                              progress: noProgress)
        let out = url("strong.pdf")
        let after = try PDFEngine.compress(opener(heavy), level: .strong, ocr: false, to: out, progress: noProgress)
        XCTAssertEqual(PDFDocument(url: out)?.pageCount, 1)
        XCTAssertLessThanOrEqual(after, Naming.fileSize(heavy))
    }

    // MARK: Passwords

    func testAddPasswordThenRemoveIt() throws {
        let src = Fixtures.makePDF(at: url("doc.pdf"), pages: 2)
        let protected = url("protected.pdf")
        try PDFEngine.protect(opener(src), password: "s3cret", to: protected)

        let locked = try XCTUnwrap(PDFDocument(url: protected))
        XCTAssertTrue(locked.isEncrypted)
        XCTAssertTrue(locked.isLocked)
        XCTAssertFalse(locked.unlock(withPassword: "wrong"))

        XCTAssertThrowsError(try opener(protected).open(), "opening without the password fails")
        XCTAssertNoThrow(try opener(protected, password: "s3cret").open())

        let unlocked = url("unlocked.pdf")
        try PDFEngine.removePassword(opener(protected, password: "s3cret"), to: unlocked)
        let plain = try XCTUnwrap(PDFDocument(url: unlocked))
        XCTAssertFalse(plain.isLocked)
        XCTAssertFalse(plain.isEncrypted)
        XCTAssertEqual(plain.pageCount, 2)
    }

    // MARK: PDF to images

    func testExportPagesAsImagesAtRequestedResolution() throws {
        let src = Fixtures.makePDF(at: url("doc.pdf"), pages: 2, size: CGSize(width: 72 * 4, height: 72 * 2))
        let out = Fixtures.tempDir()
        let png = try PDFEngine.exportImages(opener(src), format: .png, dpi: 150, folder: out, progress: noProgress)
        XCTAssertEqual(png.count, 2)
        let image = try XCTUnwrap(Fixtures.loadImage(png[0]))
        XCTAssertEqual(image.width, 600, "4 inches × 150 dpi")
        XCTAssertEqual(image.height, 300)
        XCTAssertEqual((Fixtures.properties(png[0])[kCGImagePropertyDPIWidth] as? Double) ?? 0, 150, accuracy: 0.5)

        let jpg = try PDFEngine.exportImages(opener(src), format: .jpeg, dpi: 72, folder: out, progress: noProgress)
        XCTAssertTrue(jpg.allSatisfy { $0.pathExtension == "jpg" })
    }

    // MARK: OCR

    func testMakeSearchableAddsTextToScannedPages() throws {
        let scan = Fixtures.makeScannedPDF(at: url("scan.pdf"), text: "INVOICE 4821")
        XCTAssertEqual(pageText(scan, 0).trimmingCharacters(in: .whitespacesAndNewlines), "")
        let out = url("searchable.pdf")
        let result = try PDFEngine.makeSearchable(opener(scan), to: out, progress: noProgress)
        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.recognised, 1)
        XCTAssertTrue(pageText(out, 0).uppercased().contains("INVOICE"), "recognised text: \(pageText(out, 0))")
    }

    func testMakeSearchableLeavesTextPagesAlone() throws {
        let src = Fixtures.makePDF(at: url("doc.pdf"), pages: 2)
        let result = try PDFEngine.makeSearchable(opener(src), to: url("same.pdf"), progress: noProgress)
        XCTAssertEqual(result.recognised, 0)
        XCTAssertEqual(result.total, 2)
    }

    // MARK: Sign

    func testSignatureIsDrawnWherePlaced() throws {
        let src = Fixtures.makePDF(at: url("contract.pdf"), pages: 2)
        let signature = Fixtures.makeImage(width: 300, height: 100, color: Fixtures.blue)
        let out = url("signed.pdf")
        try PDFEngine.sign(opener(src),
                           placements: [SignaturePlacement(page: 1, center: CGPoint(x: 0.5, y: 0.8), width: 0.3)],
                           signature: signature, to: out, progress: noProgress)
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 2)
        let rendered = Fixtures.render(page: doc.page(at: 1)!)
        let x = Int(Double(rendered.width) * 0.5), y = Int(Double(rendered.height) * 0.8)
        XCTAssertTrue(Fixtures.pixel(rendered, x: x, y: y).isBluish, "signature appears at 50% across, 80% down")
        XCTAssertTrue(Fixtures.pixel(rendered, x: x, y: Int(Double(rendered.height) * 0.5)).isWhitish)
        XCTAssertTrue(doc.string?.contains("Page 2") ?? false, "original text is kept")
        XCTAssertTrue(Fixtures.pixel(Fixtures.render(page: doc.page(at: 0)!), x: x, y: y).isWhitish, "other pages untouched")
    }

    // MARK: Files

    func testWritingOverAnInputFileIsSafe() throws {
        let src = Fixtures.makePDF(at: url("doc.pdf"), pages: 3)
        try PDFEngine.savePages(opener(src), pages: [PageSpec(index: 2, rotation: 0)], to: src, progress: noProgress)
        XCTAssertEqual(PDFDocument(url: src)?.pageCount, 1)
        XCTAssertTrue(pageText(src, 0).contains("Page 3"))
    }

    func testUniqueURLNeverOverwrites() throws {
        let existing = Fixtures.makePDF(at: url("name.pdf"), pages: 1)
        let next = PDFEngine.uniqueURL(existing)
        XCTAssertEqual(next.lastPathComponent, "name (2).pdf")
        Fixtures.makePDF(at: next, pages: 1)
        XCTAssertEqual(PDFEngine.uniqueURL(existing).lastPathComponent, "name (3).pdf")
        XCTAssertEqual(PDFEngine.uniqueURL(url("fresh.pdf")).lastPathComponent, "fresh.pdf")
    }

    func testPageDisplaySizeFollowsRotation() throws {
        let src = Fixtures.makePDF(at: url("wide.pdf"), pages: 1, size: CGSize(width: 800, height: 400))
        let doc = try XCTUnwrap(PDFDocument(url: src))
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertEqual(PDFEngine.displaySize(of: page.pageRef!), CGSize(width: 800, height: 400))

        // A page saved with a 90° rotation reports swapped width and height.
        let rotated = url("rotated.pdf")
        try PDFEngine.savePages(opener(src), pages: [PageSpec(index: 0, rotation: 90)], to: rotated, progress: noProgress)
        let rotatedPage = try XCTUnwrap(PDFDocument(url: rotated)?.page(at: 0))
        XCTAssertEqual(PDFEngine.displaySize(of: rotatedPage.pageRef!), CGSize(width: 400, height: 800))
    }
}
