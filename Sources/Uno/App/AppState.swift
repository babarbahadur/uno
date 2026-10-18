import SwiftUI
import AppKit

final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var path: [ToolID] = []
    /// Files opened from Finder / the Dock, picked up by the Merge tool.
    @Published var pendingURLs: [URL] = []
    /// Most recently opened tools, newest first.
    @Published private(set) var recent: [ToolID] =
        (UserDefaults.standard.stringArray(forKey: "recentTools") ?? []).compactMap(ToolID.init(rawValue:))
    /// The canvas editor registers itself here so ⌘Z / ⇧⌘Z reach it.
    weak var activeEditor: CanvasEditorModel?

    func open(_ tool: ToolID) {
        guard tool.isAvailable else { return }
        path = [tool]
        remember(tool)
    }

    private func remember(_ tool: ToolID) {
        var list = recent.filter { $0 != tool }
        list.insert(tool, at: 0)
        recent = Array(list.prefix(4))
        UserDefaults.standard.set(recent.map(\.rawValue), forKey: "recentTools")
    }

    func goHome() {
        path = []
    }

    func openFiles(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        pendingURLs.append(contentsOf: files)
        path = [.merge]
    }

    private var isEditingText: Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    func undo() {
        if let editor = activeEditor, !isEditingText {
            editor.undo()
        } else {
            NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        }
    }

    func redo() {
        if let editor = activeEditor, !isEditingText {
            editor.redo()
        } else {
            NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        }
    }
}

// MARK: - Tool registry

enum ToolCategory: String, CaseIterable, Identifiable {
    case pdf
    case images
    case ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: return "PDF"
        case .images: return "Images"
        case .ai: return "On-device AI"
        }
    }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .images: return "photo"
        case .ai: return "sparkles"
        }
    }

    var blurb: String {
        switch self {
        case .pdf: return "Merge, split, sign and protect documents"
        case .images: return "Edit, resize and convert pictures"
        case .ai: return "Smart tools that run on this Mac's chip"
        }
    }

    var tint: Color {
        switch self {
        // Muted, earthy tones that sit with the logo's porcelain and taupe.
        case .pdf: return Color(light: 0xB67A66, dark: 0xD49C88)
        case .images: return Color(light: 0x6F8E78, dark: 0x9DB8A3)
        case .ai: return Color(light: 0x8A80A8, dark: 0xADA4CC)
        }
    }
}

/// Every tool in the app. Add a case here (and a view in ToolView) to add a tool;
/// the home grid, search and menus pick it up automatically.
enum ToolID: String, CaseIterable, Identifiable, Hashable {
    // Images
    case canvasEditor
    // Images (batch) are declared below with the others
    // PDF
    case merge, split, organize, deletePages, extract, compress, sign
    case addPassword, removePassword, imagesToPDF, pdfToImages
    // On-device AI
    case makeSearchable
    case resizeImage, convertImage

    var id: String { rawValue }

    /// Set to false for a tool that is listed as "coming soon".
    var isAvailable: Bool { true }

    var categories: [ToolCategory] {
        switch self {
        case .canvasEditor: return [.images, .ai]
        case .makeSearchable: return [.ai, .pdf]
        case .resizeImage, .convertImage: return [.images]
        default: return [.pdf]
        }
    }

    var tint: Color { categories.first?.tint ?? .accentColor }

    var title: String {
        switch self {
        case .canvasEditor: return "Image Editor"
        case .merge: return "Merge PDFs"
        case .split: return "Split PDF"
        case .organize: return "Organize PDF"
        case .deletePages: return "Delete Pages"
        case .extract: return "Extract Pages"
        case .compress: return "Compress PDF"
        case .sign: return "Sign PDF"
        case .addPassword: return "Add Password"
        case .removePassword: return "Remove Password"
        case .imagesToPDF: return "Images to PDF"
        case .pdfToImages: return "PDF to Images"
        case .makeSearchable: return "Make PDF Searchable"
        case .resizeImage: return "Batch Resize"
        case .convertImage: return "Batch Convert"
        }
    }

    var subtitle: String {
        switch self {
        case .canvasEditor: return "Crop, skew, filters, ID photos"
        case .merge: return "Many documents, one file"
        case .split: return "One file per page"
        case .organize: return "Reorder, rotate, remove"
        case .deletePages: return "Uncheck the pages to keep"
        case .extract: return "Pull out just what you need"
        case .compress: return "Shrink the file size"
        case .sign: return "Draw once, sign anywhere"
        case .addPassword: return "Lock it down"
        case .removePassword: return "Unlock a PDF you own"
        case .imagesToPDF: return "Photos into a document"
        case .pdfToImages: return "Every page as a picture"
        case .makeSearchable: return "Recognise text in scans"
        case .resizeImage: return "Many images at once"
        case .convertImage: return "JPG, PNG, HEIC, WebP, PDF"
        }
    }

    var detail: String {
        switch self {
        case .canvasEditor: return "An all-in-one editor on a single screen. Create an A4, ID card or photo canvas, add images, crop, transform, filter and export."
        case .merge: return "Combine PDFs and images into a single PDF, in the order you choose."
        case .split: return "Break a PDF into single pages or chunks of pages."
        case .organize: return "Drag pages into a new order, rotate them or remove them."
        case .deletePages: return "Every page starts checked. Uncheck the ones you don't want."
        case .extract: return "Pick pages by clicking or typing ranges like 1-3, 7."
        case .compress: return "Make PDFs smaller for email and upload."
        case .sign: return "Draw your signature once and place it on any page."
        case .addPassword: return "Protect a PDF so it needs a password to open."
        case .removePassword: return "Save a copy without the password. Only for PDFs you're allowed to unlock."
        case .imagesToPDF: return "Turn photos and scans into a PDF, with optional text recognition."
        case .pdfToImages: return "Save every page as a PNG or JPEG."
        case .makeSearchable: return "On-device AI adds selectable, searchable text to scanned pages."
        case .resizeImage: return "Resize many images at once by percentage, longest side, width, height or an exact size."
        case .convertImage: return "Convert many images between JPEG, PNG, HEIC, WebP, TIFF and PDF. Set the quality, cap the file size, remove location data."
        }
    }

    var keywords: String {
        switch self {
        case .canvasEditor: return "editor canvas crop skew rotate perspective distort transform layer text filter scan scanner id card passport photo a4 background remove enhance print"
        case .merge: return "combine join append"
        case .split: return "separate break"
        case .organize: return "rotate reorder sort arrange move"
        case .deletePages: return "remove"
        case .extract: return "select range copy"
        case .compress: return "reduce smaller optimize size"
        case .sign: return "signature"
        case .addPassword: return "encrypt protect lock security"
        case .removePassword: return "decrypt unlock"
        case .imagesToPDF: return "jpg png heic photo scan convert"
        case .pdfToImages: return "jpg png export convert"
        case .makeSearchable: return "ocr text recognition scan ai"
        case .resizeImage: return "batch bulk scale shrink smaller dimensions pixels thumbnail compress"
        case .convertImage: return "batch bulk format jpg jpeg png heic webp tiff gif bmp pdf compress exif metadata"
        }
    }

    var symbol: String {
        switch self {
        case .canvasEditor: return "photo.artframe"
        case .merge: return "doc.on.doc"
        case .split: return "scissors"
        case .organize: return "square.grid.2x2"
        case .deletePages: return "trash"
        case .extract: return "arrow.up.doc"
        case .compress: return "arrow.down.right.and.arrow.up.left"
        case .sign: return "signature"
        case .addPassword: return "lock.doc"
        case .removePassword: return "lock.open"
        case .imagesToPDF: return "photo.on.rectangle"
        case .pdfToImages: return "photo.stack"
        case .makeSearchable: return "text.viewfinder"
        case .resizeImage: return "arrow.up.left.and.arrow.down.right"
        case .convertImage: return "arrow.triangle.2.circlepath"
        }
    }

    var shortcut: KeyboardShortcut? {
        let keyChar: Character?
        switch self {
        case .canvasEditor: keyChar = "n"
        case .merge: keyChar = "1"
        case .split: keyChar = "2"
        case .organize: keyChar = "3"
        case .deletePages: keyChar = "4"
        case .extract: keyChar = "5"
        case .compress: keyChar = "6"
        case .sign: keyChar = "7"
        case .imagesToPDF: keyChar = "8"
        case .pdfToImages: keyChar = "9"
        default: keyChar = nil
        }
        guard let key = keyChar else { return nil }
        return KeyboardShortcut(KeyEquivalent(key), modifiers: .command)
    }

    static func tools(in category: ToolCategory) -> [ToolID] {
        allCases.filter { $0.categories.contains(category) }
    }

    static var availableCount: Int { allCases.filter(\.isAvailable).count }
}
