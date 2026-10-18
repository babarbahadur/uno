import SwiftUI
import AppKit
import PDFKit

// MARK: - Page model

struct PageItem: Identifiable {
    let id = UUID()
    let index: Int        // page index in the original PDF
    var rotation = 0      // extra rotation, degrees
}

final class PagesModel: ObservableObject {
    @Published var pages: [PageItem] = []
    @Published var thumbnails: [Int: NSImage] = [:]
    @Published var selected: Set<UUID> = []
    private var generation = 0

    var selectedCount: Int { selected.count }

    func clear() {
        generation += 1
        pages = []
        thumbnails = [:]
        selected = []
    }

    func load(from opener: PDFOpener, pageCount: Int, selectAll: Bool) {
        generation += 1
        let current = generation
        pages = (0..<pageCount).map { PageItem(index: $0) }
        selected = selectAll ? Set(pages.map(\.id)) : []
        thumbnails = [:]

        DispatchQueue.global(qos: .userInitiated).async {
            guard let doc = try? opener.open() else { return }
            for index in 0..<doc.pageCount {
                guard let cgPage = doc.page(at: index)?.pageRef else { continue }
                let size = PDFEngine.displaySize(of: cgPage)
                let scale = 360 / max(1, max(size.width, size.height))
                guard let cgImage = PDFEngine.render(cgPage, size: size, scale: scale) else { continue }
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                DispatchQueue.main.async {
                    guard current == self.generation else { return }
                    self.thumbnails[index] = image
                }
            }
        }
    }

    func specs(onlySelected: Bool) -> [PageSpec] {
        pages
            .filter { !onlySelected || selected.contains($0.id) }
            .map { PageSpec(index: $0.index, rotation: $0.rotation) }
    }

    func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func selectOnly(_ id: UUID) { selected = [id] }
    func selectAll() { selected = Set(pages.map(\.id)) }
    func selectNone() { selected = [] }
    func invert() { selected = Set(pages.map(\.id)).subtracting(selected) }

    func select(indices: Set<Int>) {
        selected = Set(pages.filter { indices.contains($0.index) }.map(\.id))
    }

    func rotate(by degrees: Int) {
        let targets = selected.isEmpty ? Set(pages.map(\.id)) : selected
        for i in pages.indices where targets.contains(pages[i].id) {
            pages[i].rotation = ((pages[i].rotation + degrees) % 360 + 360) % 360
        }
    }

    func deleteSelected() {
        pages.removeAll { selected.contains($0.id) }
        selected = []
    }

    /// Moves a dragged page onto another page's position.
    func move(_ idString: String, onto target: UUID) {
        guard let id = UUID(uuidString: idString), id != target,
              let from = pages.firstIndex(where: { $0.id == id }),
              let targetIndex = pages.firstIndex(where: { $0.id == target }) else { return }
        let item = pages.remove(at: from)
        pages.insert(item, at: min(targetIndex, pages.count))
    }
}

// MARK: - Organize / Delete Pages / Extract Pages

struct PageTool: View {
    enum Mode {
        case organize
        case delete
        case extract
    }

    let mode: Mode
    @StateObject private var source = PDFSource()
    @StateObject private var job = JobRunner()
    @StateObject private var model = PagesModel()
    @State private var rangeText = ""
    @State private var separateFiles = false

    private var tool: ToolID {
        switch mode {
        case .organize: return .organize
        case .delete: return .deletePages
        case .extract: return .extract
        }
    }

    private var total: Int { model.pages.count }

    private var actionTitle: String {
        switch mode {
        case .organize:
            return "Save PDF"
        case .delete:
            let removed = total - model.selectedCount
            return removed > 0 ? "Delete \(Naming.pages(removed))" : "Delete Pages"
        case .extract:
            return model.selectedCount > 0 ? "Extract \(Naming.pages(model.selectedCount))" : "Extract Pages"
        }
    }

    private var canRun: Bool {
        guard source.isReady else { return false }
        switch mode {
        case .organize: return total > 0
        case .delete: return model.selectedCount > 0 && model.selectedCount < total
        case .extract: return model.selectedCount > 0
        }
    }

    var body: some View {
        ToolScaffold(tool: tool, job: job, actionTitle: actionTitle, actionEnabled: canRun, action: run) {
            PDFToolBody(source: source) {
                VStack(spacing: 0) {
                    toolbar
                        .buttonStyle(.neu)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    Divider()
                    PageGrid(model: model, style: mode == .organize ? .selection : .checkbox, onTap: tap)
                }
            }
        }
        .onChange(of: source.loadID) { _, _ in reload() }
    }

    @ViewBuilder
    private var toolbar: some View {
        switch mode {
        case .organize:
            HStack(spacing: 10) {
                Button { model.rotate(by: -90) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                Button { model.rotate(by: 90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                Button { withAnimation { model.deleteSelected() } } label: { Label("Delete", systemImage: "trash") }
                    .disabled(model.selected.isEmpty)
                Spacer()
                Text(model.selected.isEmpty
                     ? "Click to select · ⌘-click for more · drag to reorder"
                     : "\(model.selectedCount) selected · rotate applies to selection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reset") { reload() }
            }
        case .delete:
            HStack(spacing: 10) {
                Text("Keeping \(model.selectedCount) of \(Naming.pages(total)). Click a page to remove or keep it.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Keep All") { model.selectAll() }
                Button("Invert") { model.invert() }
            }
        case .extract:
            HStack(spacing: 10) {
                TextField("Pages, e.g. 1-3, 7", text: $rangeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(applyRange)
                Button("Select", action: applyRange)
                Button("All") { model.selectAll() }
                Button("None") { model.selectNone() }
                Spacer()
                Picker("", selection: $separateFiles) {
                    Text("One PDF").tag(false)
                    Text("Separate files").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
        }
    }

    private func reload() {
        guard source.isReady, let opener = source.opener else {
            model.clear()
            return
        }
        model.load(from: opener, pageCount: source.pageCount, selectAll: mode == .delete)
    }

    private func tap(_ item: PageItem) {
        switch mode {
        case .organize:
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                model.toggle(item.id)
            } else if model.selected == [item.id] {
                model.selectNone()
            } else {
                model.selectOnly(item.id)
            }
        case .delete, .extract:
            model.toggle(item.id)
        }
    }

    private func applyRange() {
        model.select(indices: Self.parseRange(rangeText, count: source.pageCount))
    }

    private func run() {
        guard let opener = source.opener else { return }
        let base = source.baseName

        switch mode {
        case .organize, .delete:
            let specs = model.specs(onlySelected: mode == .delete)
            let suffix = mode == .organize ? "organized" : "edited"
            guard let output = Panels.savePDF(suggested: "\(base) (\(suffix)).pdf", near: source.folder) else { return }
            job.run("Saving…") { progress in
                let pages = try PDFEngine.savePages(opener, pages: specs, to: output, progress: progress)
                return JobRunner.Outcome(urls: [output], message: "Saved \(output.lastPathComponent) · \(Naming.pages(pages))")
            }
        case .extract:
            let specs = model.specs(onlySelected: true)
            if separateFiles {
                guard let folder = Panels.chooseFolder(message: "Choose where to save the pages", near: source.folder) else { return }
                job.run("Extracting…") { progress in
                    let urls = try PDFEngine.extractSeparately(opener, pages: specs, folder: folder, progress: progress)
                    return JobRunner.Outcome(urls: urls, message: "Saved \(urls.count) files")
                }
            } else {
                guard let output = Panels.savePDF(suggested: "\(base) (extract).pdf", near: source.folder) else { return }
                job.run("Extracting…") { progress in
                    let pages = try PDFEngine.savePages(opener, pages: specs, to: output, progress: progress)
                    return JobRunner.Outcome(urls: [output], message: "Saved \(output.lastPathComponent) · \(Naming.pages(pages))")
                }
            }
        }
    }

    /// Parses "1-3, 5, 8-" into zero-based page indices.
    static func parseRange(_ text: String, count: Int) -> Set<Int> {
        var result = Set<Int>()
        guard count > 0 else { return result }
        for part in text.split(separator: ",") {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.isEmpty { continue }
            if let dash = token.firstIndex(where: { $0 == "-" || $0 == "–" }) {
                let low = Int(token[..<dash].trimmingCharacters(in: .whitespaces)) ?? 1
                let high = Int(token[token.index(after: dash)...].trimmingCharacters(in: .whitespaces)) ?? count
                let a = max(1, min(low, high))
                let b = min(count, max(low, high))
                if a <= b {
                    for page in a...b { result.insert(page - 1) }
                }
            } else if let page = Int(token), page >= 1, page <= count {
                result.insert(page - 1)
            }
        }
        return result
    }
}

// MARK: - Grid

enum PageCellStyle {
    case selection
    case checkbox
}

struct PageGrid: View {
    @ObservedObject var model: PagesModel
    let style: PageCellStyle
    let onTap: (PageItem) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)], spacing: 22) {
                ForEach(model.pages) { item in
                    PageCell(image: model.thumbnails[item.index],
                             number: item.index + 1,
                             rotation: item.rotation,
                             isOn: model.selected.contains(item.id),
                             style: style)
                        .onTapGesture { onTap(item) }
                        .draggable(item.id.uuidString)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let first = ids.first, UUID(uuidString: first) != nil else { return false }
                            withAnimation { model.move(first, onto: item.id) }
                            return true
                        }
                }
            }
            .padding(24)
        }
        .background(Theme.background)
    }
}

struct PageCell: View {
    let image: NSImage?
    let number: Int
    let rotation: Int
    let isOn: Bool
    let style: PageCellStyle

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .background(Color.white)
                            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white)
                            .frame(width: 120, height: 160)
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .rotationEffect(.degrees(Double(rotation)))
                .scaleEffect(rotation % 180 == 0 ? 1 : 0.75)
                .animation(.easeInOut(duration: 0.2), value: rotation)
                .frame(width: 150, height: 180)
                .opacity(style == .checkbox && !isOn ? 0.35 : 1)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(style == .selection && isOn ? Theme.accentDeep.opacity(0.15) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.accentDeep, lineWidth: style == .selection && isOn ? 2.5 : 0)
                )

                if style == .checkbox {
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(isOn ? Theme.accentDeep : Color.secondary)
                        .background(Circle().fill(Theme.surface))
                        .padding(6)
                }
            }
            Text("\(number)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}
