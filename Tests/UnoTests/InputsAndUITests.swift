import XCTest
import AppKit
import SwiftUI
@testable import Uno

final class FileQueueTests: XCTestCase {
    private var dir: URL!

    override func setUp() { dir = Fixtures.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testMergeQueueAcceptsPDFsAndImagesAndSkipsOthers() throws {
        let queue = FileQueue(accepts: [.pdf, .image])
        let pdf = Fixtures.makePDF(at: dir.appendingPathComponent("b.pdf"), pages: 2)
        let png = Fixtures.write(Fixtures.makeImage(width: 10, height: 10, color: Fixtures.red), to: dir.appendingPathComponent("a.png"))
        let txt = dir.appendingPathComponent("notes.txt")
        try "x".write(to: txt, atomically: true, encoding: .utf8)

        queue.add(urls: [pdf, png, txt])
        XCTAssertEqual(queue.items.map(\.name), ["b.pdf", "a.png"])
        XCTAssertEqual(queue.totalPages, 3)
        XCTAssertTrue(queue.errorMessage?.contains("notes.txt") ?? false)
        XCTAssertEqual(queue.selection, queue.items.first?.id)
    }

    func testImageQueueRejectsPDFs() {
        let queue = FileQueue(accepts: [.image])
        queue.add(urls: [Fixtures.makePDF(at: dir.appendingPathComponent("doc.pdf"), pages: 1)])
        XCTAssertTrue(queue.items.isEmpty)
        XCTAssertNotNil(queue.errorMessage)
    }

    func testFoldersAreAddedSortedAndQuietly() throws {
        let folder = dir.appendingPathComponent("scans", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["page10.png", "page2.png", "page1.png"] {
            Fixtures.write(Fixtures.makeImage(width: 10, height: 10, color: Fixtures.red), to: folder.appendingPathComponent(name))
        }
        try "ignore me".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        let queue = FileQueue(accepts: [.image])
        queue.add(urls: [folder])
        XCTAssertEqual(queue.items.map(\.name), ["page1.png", "page2.png", "page10.png"], "natural sort order")
        XCTAssertNil(queue.errorMessage, "other files inside folders are skipped quietly")
    }

    func testReorderSortRemoveClear() {
        let queue = FileQueue(accepts: [.image])
        let urls = ["c.png", "a.png", "b.png"].map {
            Fixtures.write(Fixtures.makeImage(width: 10, height: 10, color: Fixtures.red), to: dir.appendingPathComponent($0))
        }
        queue.add(urls: urls)
        queue.move(queue.items[0], by: 1)
        XCTAssertEqual(queue.items.map(\.name), ["a.png", "c.png", "b.png"])
        queue.move(queue.items[0], by: -1)
        XCTAssertEqual(queue.items.map(\.name), ["a.png", "c.png", "b.png"], "can't move past the top")
        queue.sortByName()
        XCTAssertEqual(queue.items.map(\.name), ["a.png", "b.png", "c.png"])
        queue.selection = queue.items[1].id
        queue.removeSelected()
        XCTAssertEqual(queue.items.map(\.name), ["a.png", "c.png"])
        XCTAssertNil(queue.selection)
        queue.clear()
        XCTAssertTrue(queue.items.isEmpty)
    }
}

final class PDFSourceTests: XCTestCase {
    private var dir: URL!

    override func setUp() { dir = Fixtures.tempDir() }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testLoadingAPDF() {
        let source = PDFSource()
        XCTAssertFalse(source.isReady)
        let pdf = Fixtures.makePDF(at: dir.appendingPathComponent("Report.pdf"), pages: 4)
        source.load(pdf)
        XCTAssertTrue(source.isReady)
        XCTAssertEqual(source.pageCount, 4)
        XCTAssertEqual(source.baseName, "Report")
        XCTAssertFalse(source.isEncrypted)
        XCTAssertNotNil(source.opener)
    }

    func testLockedPDFNeedsThePassword() {
        let source = PDFSource()
        source.load(Fixtures.makeLockedPDF(at: dir.appendingPathComponent("locked.pdf"), password: "pw"))
        XCTAssertTrue(source.isLocked)
        XCTAssertFalse(source.isReady)
        XCTAssertEqual(source.pageCount, 0)
        XCTAssertFalse(source.unlock("wrong"))
        XCTAssertTrue(source.unlock("pw"))
        XCTAssertTrue(source.isReady)
        XCTAssertTrue(source.isEncrypted)
        XCTAssertNoThrow(try source.opener!.open(), "background jobs reopen with the saved password")
    }

    func testNonPDFShowsAnError() throws {
        let source = PDFSource()
        let png = Fixtures.write(Fixtures.makeImage(width: 10, height: 10, color: Fixtures.red), to: dir.appendingPathComponent("x.png"))
        source.load(png)
        XCTAssertFalse(source.isReady)
        XCTAssertNotNil(source.errorMessage)
    }
}

/// Renders every screen off-screen to catch crashes and layout problems.
/// Clicking buttons needs a person (see TESTING.md); this checks every screen can be built and laid out.
final class UISmokeTests: XCTestCase {

    override func setUp() {
        _ = NSApplication.shared
    }

    @MainActor
    private func render<V: View>(_ view: V, size: CGSize = CGSize(width: 1180, height: 780)) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.environmentObject(AppState()).frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.display()
        return host
    }

    @MainActor
    func testHomeScreenRenders() {
        let host = render(HomeView())
        XCTAssertGreaterThan(host.subviews.count + 1, 0)
    }

    @MainActor
    func testEveryToolScreenRenders() {
        for tool in ToolID.allCases {
            let host = render(NavigationStack { ToolView(tool: tool) })
            XCTAssertEqual(host.frame.width, 1180, "\(tool.title) screen")
        }
    }

    @MainActor
    func testScreensRenderInDarkMode() {
        for tool in [ToolID.merge, .canvasEditor, .convertImage] {
            _ = render(NavigationStack { ToolView(tool: tool) }.preferredColorScheme(.dark))
        }
        _ = render(HomeView().preferredColorScheme(.dark))
    }

    @MainActor
    func testCanvasEditorWithContentRenders() {
        let model = CanvasEditorModel()
        model.newCanvas(CanvasSetup())
        let image = Fixtures.makeImage(width: 300, height: 200, color: Fixtures.red)
        model.doc?.layers.append(ImageLayer(name: "photo", image: image, preview: image, center: CGPoint(x: 500, y: 500)))
        model.selectedID = model.doc?.layers.first?.id
        for mode in EditorMode.allCases {
            model.mode = mode
            _ = render(CanvasEditorView(model: model))
        }
    }

    @MainActor
    func testSettingsAndSheetsRender() {
        _ = render(SettingsView(), size: CGSize(width: 440, height: 200))
        _ = render(SignaturePad { _ in }, size: CGSize(width: 600, height: 360))
        let doc = CanvasDocument(width: 2480, height: 3508, dpi: 300, isPhysical: true)
        _ = render(ExportSheet(doc: doc) { _, _, _ in }, size: CGSize(width: 480, height: 420))
    }

    @MainActor
    func testThemedButtonStylesRender() {
        let button = Button("Choose PDF…") {}.buttonStyle(.neu)
        _ = render(button, size: CGSize(width: 200, height: 60))
        let prominent = Button("Create PDF") {}.buttonStyle(.neuProminent)
        _ = render(prominent, size: CGSize(width: 200, height: 60))
    }
}
