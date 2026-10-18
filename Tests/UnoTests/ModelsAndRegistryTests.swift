import XCTest
import CoreGraphics
@testable import Uno

final class ModelsTests: XCTestCase {

    func testPageSizeFitImageKeepsAspectAndCapsLongSide() {
        let size = PageSizeOption.fitImage.pageSize(for: CGSize(width: 4000, height: 3000))
        XCTAssertEqual(max(size.width, size.height), 842, accuracy: 1)
        XCTAssertEqual(size.width / size.height, 4.0 / 3.0, accuracy: 0.01)
    }

    func testPageSizeFitImageDoesNotEnlargeSmallImages() {
        XCTAssertEqual(PageSizeOption.fitImage.pageSize(for: CGSize(width: 300, height: 200)), CGSize(width: 300, height: 200))
    }

    func testPaperSizesRotateForLandscapeImages() {
        XCTAssertEqual(PageSizeOption.a4.pageSize(for: CGSize(width: 100, height: 200)).width, 595.28, accuracy: 0.01)
        XCTAssertEqual(PageSizeOption.a4.pageSize(for: CGSize(width: 200, height: 100)).width, 841.89, accuracy: 0.01)
        XCTAssertEqual(PageSizeOption.letter.pageSize(for: CGSize(width: 10, height: 20)), CGSize(width: 612, height: 792))
        XCTAssertEqual(PageSizeOption.fitImage.margin, 0)
        XCTAssertGreaterThan(PageSizeOption.a4.margin, 0)
    }

    func testImageQualityLevelsAreOrdered() {
        XCTAssertGreaterThan(ImageQuality.high.maxPixelSize, ImageQuality.balanced.maxPixelSize)
        XCTAssertGreaterThan(ImageQuality.balanced.maxPixelSize, ImageQuality.small.maxPixelSize)
        XCTAssertGreaterThan(ImageQuality.high.jpegQuality, ImageQuality.small.jpegQuality)
    }

    func testCompressionLevels() {
        XCTAssertFalse(CompressionLevel.light.rasterizes)
        XCTAssertTrue(CompressionLevel.balanced.rasterizes)
        XCTAssertGreaterThan(CompressionLevel.balanced.dpi, CompressionLevel.strong.dpi)
    }

    func testNamingHelpers() {
        XCTAssertEqual(Naming.base(URL(fileURLWithPath: "/tmp/My File.v2.pdf")), "My File.v2")
        XCTAssertEqual(Naming.pages(1), "1 page")
        XCTAssertEqual(Naming.pages(3), "3 pages")
        XCTAssertEqual(Naming.fileSize(URL(fileURLWithPath: "/definitely/missing.pdf")), 0)
        XCTAssertFalse(Naming.sizeString(2_000_000).isEmpty)
    }

    func testInputItemRecognisesPDFsImagesAndRejectsOthers() throws {
        let dir = Fixtures.tempDir()
        let pdf = Fixtures.makePDF(at: dir.appendingPathComponent("a.pdf"), pages: 3)
        let png = Fixtures.write(Fixtures.makeImage(width: 40, height: 30, color: Fixtures.red), to: dir.appendingPathComponent("b.png"))
        let txt = dir.appendingPathComponent("c.txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)

        let pdfItem = try XCTUnwrap(InputItem.make(from: pdf))
        XCTAssertEqual(pdfItem.kind, .pdf)
        XCTAssertEqual(pdfItem.pageCount, 3)
        XCTAssertEqual(pdfItem.subtitle, "PDF · 3 pages")

        let imageItem = try XCTUnwrap(InputItem.make(from: png))
        XCTAssertEqual(imageItem.kind, .image)
        XCTAssertEqual(imageItem.pageCount, 1)

        XCTAssertNil(InputItem.make(from: txt))
        XCTAssertNil(InputItem.make(from: dir.appendingPathComponent("missing.png")))
    }

    func testPageRangeParsing() {
        XCTAssertEqual(PageTool.parseRange("1-3, 5", count: 10), [0, 1, 2, 4])
        XCTAssertEqual(PageTool.parseRange("8-", count: 10), [7, 8, 9])
        XCTAssertEqual(PageTool.parseRange("-2", count: 10), [0, 1])
        XCTAssertEqual(PageTool.parseRange("3–1", count: 10), [0, 1, 2], "en dash and reversed range")
        XCTAssertEqual(PageTool.parseRange("0, 11, abc, 4", count: 10), [3], "out of range and junk are ignored")
        XCTAssertEqual(PageTool.parseRange("", count: 10), [])
        XCTAssertEqual(PageTool.parseRange("1-5", count: 0), [])
    }
}

final class RegistryTests: XCTestCase {
    private var savedRecent: [String]?

    override func setUp() {
        savedRecent = UserDefaults.standard.stringArray(forKey: "recentTools")
    }

    override func tearDown() {
        UserDefaults.standard.set(savedRecent, forKey: "recentTools")
    }

    func testEveryToolIsFullyDescribed() {
        for tool in ToolID.allCases {
            XCTAssertFalse(tool.title.isEmpty, "\(tool) title")
            XCTAssertFalse(tool.subtitle.isEmpty, "\(tool) subtitle")
            XCTAssertFalse(tool.detail.isEmpty, "\(tool) detail")
            XCTAssertFalse(tool.symbol.isEmpty, "\(tool) symbol")
            XCTAssertFalse(tool.categories.isEmpty, "\(tool) needs a category")
            XCTAssertTrue(tool.isAvailable, "\(tool) should be available")
        }
    }

    func testTitlesAndShortcutsAreUnique() {
        let titles = ToolID.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count)
        let keys = ToolID.allCases.compactMap { $0.shortcut?.key.character }
        XCTAssertEqual(Set(keys).count, keys.count, "two tools share a keyboard shortcut")
    }

    func testNoOtherCompanyNamesInUserFacingText() {
        let banned = ["photopea", "photoshop", "apple", "iphone", "adobe", "google", "microsoft"]
        for tool in ToolID.allCases {
            let text = "\(tool.title) \(tool.subtitle) \(tool.detail) \(tool.keywords)".lowercased()
            for word in banned {
                XCTAssertFalse(text.contains(word), "\(tool) mentions \(word)")
            }
        }
    }

    func testCategoriesListTools() {
        XCTAssertEqual(ToolID.availableCount, ToolID.allCases.count)
        for category in ToolCategory.allCases {
            XCTAssertFalse(ToolID.tools(in: category).isEmpty, "\(category) is empty")
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.blurb.isEmpty)
        }
        XCTAssertTrue(ToolID.tools(in: .pdf).contains(.merge))
        XCTAssertTrue(ToolID.tools(in: .images).contains(.canvasEditor))
        XCTAssertTrue(ToolID.tools(in: .ai).contains(.makeSearchable))
    }

    func testOpeningToolsNavigatesAndRemembersRecentOnes() {
        let app = AppState()
        app.goHome()
        app.open(.split)
        XCTAssertEqual(app.path, [.split])
        for tool in [ToolID.merge, .compress, .sign, .organize, .split] { app.open(tool) }
        XCTAssertEqual(app.recent.first, .split)
        XCTAssertEqual(app.recent.count, 4, "only the last four tools are kept")
        XCTAssertEqual(Set(app.recent).count, app.recent.count, "no duplicates")
        app.goHome()
        XCTAssertTrue(app.path.isEmpty)
    }

    func testOpeningFilesGoesToMerge() {
        let app = AppState()
        app.openFiles([URL(fileURLWithPath: "/tmp/a.pdf"), URL(string: "https://example.com/b.pdf")!])
        XCTAssertEqual(app.path, [.merge])
        XCTAssertEqual(app.pendingURLs.count, 1, "web links are ignored")
    }
}
