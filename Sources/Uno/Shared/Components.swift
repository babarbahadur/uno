import SwiftUI
import AppKit
import PDFKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Routes a tool to its screen. New tools are added here.
struct ToolView: View {
    let tool: ToolID

    var body: some View {
        switch tool {
        case .canvasEditor: CanvasEditorTool()
        case .merge: FileCombineTool(mode: .merge)
        case .imagesToPDF: FileCombineTool(mode: .images)
        case .split: SplitTool()
        case .organize: PageTool(mode: .organize)
        case .deletePages: PageTool(mode: .delete)
        case .extract: PageTool(mode: .extract)
        case .compress: CompressTool()
        case .sign: SignTool()
        case .addPassword: AddPasswordTool()
        case .removePassword: RemovePasswordTool()
        case .pdfToImages: PDFToImagesTool()
        case .makeSearchable: SearchableTool()
        case .resizeImage: BatchImageTool(mode: .resize)
        case .convertImage: BatchImageTool(mode: .convert)
        default: ComingSoonView(tool: tool)
        }
    }
}

// MARK: - Background jobs

final class JobRunner: ObservableObject {
    struct Outcome {
        let urls: [URL]
        let message: String
    }

    @Published var isBusy = false
    @Published var progress: Double = 0
    @Published var status = ""
    @Published var resultURLs: [URL] = []
    @Published var errorMessage: String?

    func run(_ title: String,
             work: @escaping (_ progress: @escaping (Double) -> Void) throws -> Outcome) {
        guard !isBusy else { return }
        isBusy = true
        progress = 0
        status = title
        resultURLs = []

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outcome = try work { value in
                    DispatchQueue.main.async { self.progress = value }
                }
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.progress = 1
                    self.status = outcome.message
                    self.resultURLs = outcome.urls
                    let openWhenDone = UserDefaults.standard.object(forKey: "openWhenDone") as? Bool ?? true
                    if openWhenDone { Self.present(outcome.urls) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.status = ""
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    static func present(_ urls: [URL]) {
        if urls.count == 1, urls[0].pathExtension.lowercased() == "pdf" {
            NSWorkspace.shared.open(urls[0])
        } else if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}

// MARK: - Tool layout

struct ToolScaffold<Content: View>: View {
    let tool: ToolID
    @ObservedObject var job: JobRunner
    let actionTitle: String
    let actionEnabled: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(tool: tool)
                .padding(.horizontal, 26)
                .padding(.top, 16)
                .padding(.bottom, 16)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .neuRaised(radius: 24, depth: 9)
                .padding(.horizontal, 22)
            ActionBar(job: job, title: actionTitle, enabled: actionEnabled, action: action)
                .padding(.horizontal, 22)
                .padding(.top, 18)
                .padding(.bottom, 18)
        }
        .background(Theme.background)
        .navigationTitle(tool.title)
        .alert("Something went wrong", isPresented: Binding(
            get: { job.errorMessage != nil },
            set: { if !$0 { job.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(job.errorMessage ?? "")
        }
    }
}

struct ToolHeader: View {
    let tool: ToolID

    var body: some View {
        HStack(spacing: 16) {
            ToolIcon(tool: tool, size: 50)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                Text(tool.detail)
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(2)
            }
            Spacer()
            if let category = tool.categories.first {
                Label(category.title, systemImage: category.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(category.tint)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .neuInset(radius: 10, depth: 2)
            }
        }
    }
}

struct ActionBar: View {
    @ObservedObject var job: JobRunner
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if job.isBusy {
                NeuProgressBar(value: job.progress)
                    .frame(width: 220)
                Text(job.status)
                    .font(.callout)
                    .foregroundStyle(Theme.inkSoft)
                    .lineLimit(1)
            } else if !job.resultURLs.isEmpty {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.success))
                Text(job.status)
                    .font(.callout)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(job.resultURLs)
                }
                .buttonStyle(.neu)
            } else {
                Label("Files stay on this Mac", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            Button {
                // Finish any text field edit first, so typed values are used.
                NSApp.keyWindow?.makeFirstResponder(nil)
                DispatchQueue.main.async { action() }
            } label: {
                Text(title).frame(minWidth: 130)
            }
            .buttonStyle(.neuProminent)
            .disabled(!enabled || job.isBusy)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .neuRaised(radius: 22, depth: 7)
    }
}

/// Centered column for a tool's settings.
struct OptionsForm<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content()
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }
}

struct DropZone: View {
    let symbol: String
    let title: String
    let subtitle: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accentDeep)
                .frame(width: 92, height: 92)
                .neuRaised(radius: 46, depth: 8)
                .padding(.bottom, 6)
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text(subtitle)
                .foregroundStyle(Theme.inkSoft)
            Button(buttonTitle, action: action)
                .buttonStyle(.neu)
                .padding(.top, 4)
            Label("Files never leave this Mac", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clicking anywhere in the drop area also opens the file picker.
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .background(
            Color.clear
                .neuInset(radius: 22, depth: 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
                )
                .padding(22)
        )
    }
}

struct ComingSoonView: View {
    let tool: ToolID

    var body: some View {
        VStack(spacing: 0) {
            ToolHeader(tool: tool)
            Divider()
            VStack(spacing: 10) {
                Image(systemName: "hammer")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Coming soon").font(.title3.weight(.semibold))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .navigationTitle(tool.title)
    }
}

// MARK: - File drops

/// Collects dropped file URLs in order. A class so the async callbacks can share it safely.
private final class DropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(Int, URL)] = []

    func add(_ url: URL, at index: Int) {
        lock.lock()
        items.append((index, url))
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return items.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

extension View {
    /// Accepts files dragged in from Finder.
    /// Uses `onDrop` rather than `dropDestination`, which on macOS can stop clicks
    /// from reaching buttons inside the drop area.
    func onFileDrop(perform action: @escaping ([URL]) -> Void) -> some View {
        onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            let group = DispatchGroup()
            let collector = DropCollector()
            for (index, provider) in providers.enumerated() {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL { collector.add(url, at: index) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let urls = collector.urls
                if !urls.isEmpty { action(urls) }
            }
            return !providers.isEmpty
        }
    }
}

// MARK: - Panels

enum Panels {
    static func savePDF(suggested: String, near folder: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggested
        if let folder { panel.directoryURL = folder }
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder(message: String, near folder: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"
        panel.message = message
        if let folder { panel.directoryURL = folder }
        return panel.runModal() == .OK ? panel.url : nil
    }
}

// MARK: - Single PDF input

final class PDFSource: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var document: PDFDocument?
    @Published private(set) var password: String?
    @Published private(set) var loadID = UUID()
    @Published var errorMessage: String?

    var isLocked: Bool { document?.isLocked ?? false }
    var isReady: Bool { document != nil && !isLocked }
    var isEncrypted: Bool { document?.isEncrypted ?? false }
    var pageCount: Int { isReady ? (document?.pageCount ?? 0) : 0 }
    var name: String { url?.lastPathComponent ?? "" }
    var baseName: String { url.map(Naming.base) ?? "Document" }
    var folder: URL? { url?.deletingLastPathComponent() }
    var opener: PDFOpener? { url.map { PDFOpener(url: $0, password: password) } }

    func load(_ url: URL) {
        guard url.isFileURL, let doc = PDFDocument(url: url) else {
            errorMessage = "“\(url.lastPathComponent)” isn't a PDF that can be opened."
            return
        }
        self.url = url
        document = doc
        password = nil
        loadID = UUID()
    }

    func unlock(_ candidate: String) -> Bool {
        guard let doc = document, doc.unlock(withPassword: candidate) else { return false }
        password = candidate
        loadID = UUID()
        return true
    }

    func presentOpenPanel() {
        // Open on the next run-loop pass so the click that triggered it has fully finished.
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.prompt = "Open"
            panel.message = "Choose a PDF"
            if panel.runModal() == .OK, let url = panel.url { self.load(url) }
        }
    }
}

/// Shows a drop zone until a PDF is loaded (and unlocked), then the tool's content.
struct PDFToolBody<Content: View>: View {
    @ObservedObject var source: PDFSource
    @ViewBuilder let content: () -> Content
    @State private var password = ""
    @State private var wrongPassword = false

    var body: some View {
        VStack(spacing: 0) {
            if source.isReady {
                PDFFileBar(source: source)
                Divider()
                content()
            } else if source.isLocked {
                lockedView
            } else {
                DropZone(symbol: "doc.badge.plus",
                         title: "Drop a PDF here",
                         subtitle: "or choose one from your Mac",
                         buttonTitle: "Choose PDF…") { source.presentOpenPanel() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onFileDrop { urls in
            if let url = urls.first { source.load(url) }
        }
        .alert("Can't open file", isPresented: Binding(
            get: { source.errorMessage != nil },
            set: { if !$0 { source.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(source.errorMessage ?? "")
        }
    }

    private var lockedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("“\(source.name)” is password-protected")
                .font(.headline)
            HStack {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(tryUnlock)
                Button("Unlock", action: tryUnlock)
                    .buttonStyle(.neuProminent)
            }
            if wrongPassword {
                Text("That password didn't work.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Button("Choose another file…") { source.presentOpenPanel() }
                .buttonStyle(.neu)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tryUnlock() {
        wrongPassword = !source.unlock(password)
        if !wrongPassword { password = "" }
    }
}

struct PDFFileBar: View {
    @ObservedObject var source: PDFSource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.richtext.fill")
                .font(.title2)
                .foregroundStyle(ToolCategory.pdf.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).font(.headline).lineLimit(1).truncationMode(.middle)
                Text("\(Naming.pages(source.pageCount)) · \(Naming.sizeString(Naming.fileSize(source.url)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose Another…") { source.presentOpenPanel() }
                .buttonStyle(.neu)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

// MARK: - Multiple file input

final class FileQueue: ObservableObject {
    let accepts: Set<ItemKind>
    @Published var items: [InputItem] = []
    @Published var selection: InputItem.ID?
    @Published var errorMessage: String?

    init(accepts: Set<ItemKind>) {
        self.accepts = accepts
    }

    var totalPages: Int { items.reduce(0) { $0 + $1.pageCount } }

    func add(urls: [URL]) {
        var skipped: [String] = []
        let newItems = collect(urls: urls.filter(\.isFileURL), skipped: &skipped, insideFolder: false)
        items.append(contentsOf: newItems)
        if selection == nil { selection = newItems.first?.id }
        if !skipped.isEmpty {
            let kinds = accepts.contains(.pdf) ? "PDFs or images" : "images"
            errorMessage = "These files aren't \(kinds), so they were skipped:\n" + skipped.joined(separator: "\n")
        }
    }

    private func collect(urls: [URL], skipped: inout [String], insideFolder: Bool) -> [InputItem] {
        var result: [InputItem] = []
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let contents = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles])) ?? []
                let sorted = contents.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }
                result += collect(urls: sorted, skipped: &skipped, insideFolder: true)
            } else if let item = InputItem.make(from: url), accepts.contains(item.kind) {
                result.append(item)
            } else if !insideFolder {
                skipped.append(url.lastPathComponent)
            }
        }
        return result
    }

    func presentOpenPanel() {
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowedContentTypes = self.accepts.contains(.pdf) ? [.pdf, .image] : [.image]
            panel.prompt = "Add"
            if panel.runModal() == .OK { self.add(urls: panel.urls) }
        }
    }

    func move(_ item: InputItem, by offset: Int) {
        guard let i = items.firstIndex(of: item) else { return }
        let j = i + offset
        guard items.indices.contains(j) else { return }
        items.swapAt(i, j)
    }

    func remove(_ item: InputItem) {
        items.removeAll { $0.id == item.id }
        if selection == item.id { selection = nil }
    }

    func removeSelected() {
        if let id = selection, let item = items.first(where: { $0.id == id }) { remove(item) }
    }

    func sortByName() {
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func clear() {
        items.removeAll()
        selection = nil
    }
}

struct FileQueueView: View {
    @ObservedObject var queue: FileQueue
    let emptyTitle: String
    let emptySubtitle: String

    var body: some View {
        Group {
            if queue.items.isEmpty {
                DropZone(symbol: "square.and.arrow.down.on.square",
                         title: emptyTitle,
                         subtitle: emptySubtitle,
                         buttonTitle: "Choose Files…") { queue.presentOpenPanel() }
                    .onFileDrop { urls in queue.add(urls: urls) }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text("\(queue.items.count) file\(queue.items.count == 1 ? "" : "s") · \(Naming.pages(queue.totalPages)) · drag to reorder")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button { queue.presentOpenPanel() } label: { Label("Add", systemImage: "plus") }
                        Button { queue.sortByName() } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                        Button { queue.clear() } label: { Label("Clear", systemImage: "xmark") }
                    }
                    .buttonStyle(.neu)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    // No List selection binding: the system highlight is a strong blue.
                    // Rows draw their own soft selection instead.
                    List {
                        ForEach(queue.items) { item in
                            ItemRow(item: item, selected: queue.selection == item.id) {
                                queue.remove(item)
                            }
                                .contentShape(Rectangle())
                                .onTapGesture { queue.selection = item.id }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .contextMenu {
                                    Button("Move Up") { queue.move(item, by: -1) }
                                    Button("Move Down") { queue.move(item, by: 1) }
                                    Divider()
                                    Button("Show in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                    }
                                    Button("Remove from List") { queue.remove(item) }
                                }
                        }
                        .onMove { from, to in
                            queue.items.move(fromOffsets: from, toOffset: to)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .onDeleteCommand { queue.removeSelected() }
                    .onFileDrop { urls in queue.add(urls: urls) }
                }
            }
        }
        .alert("Some files were skipped", isPresented: Binding(
            get: { queue.errorMessage != nil },
            set: { if !$0 { queue.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(queue.errorMessage ?? "")
        }
    }
}

struct ItemRow: View {
    let item: InputItem
    var selected = false
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Thumbnail(url: item.url)
                .frame(width: 34, height: 42)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .shadow(color: Theme.shadowDark, radius: 2, x: 1, y: 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            Spacer()
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.inkSoft)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.surface))
                }
                .buttonStyle(.plain)
                .opacity(hovering || selected ? 1 : 0)
                .help("Remove from list")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Theme.selection : (hovering ? Theme.shadowDark.opacity(0.10) : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(selected ? Theme.selectionEdge : Color.clear, lineWidth: 1)
                )
        )
        .onHover { hovering = $0 }
    }
}

struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url,
                                                       size: CGSize(width: 68, height: 84),
                                                       scale: 2,
                                                       representationTypes: .thumbnail)
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = representation.nsImage
            }
        }
    }
}
