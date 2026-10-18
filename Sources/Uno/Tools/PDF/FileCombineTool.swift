import SwiftUI

/// Merge PDFs (PDFs + images) and Images to PDF share this screen.
struct FileCombineTool: View {
    enum Mode {
        case merge
        case images
    }

    let mode: Mode
    @EnvironmentObject var app: AppState
    @StateObject private var queue: FileQueue
    @StateObject private var job = JobRunner()
    @State private var pageSize: PageSizeOption = .fitImage
    @State private var quality: ImageQuality = .high
    @State private var ocr = false
    @State private var separate = false

    init(mode: Mode) {
        self.mode = mode
        _queue = StateObject(wrappedValue: FileQueue(accepts: mode == .merge ? [.pdf, .image] : [.image]))
    }

    private var tool: ToolID { mode == .merge ? .merge : .imagesToPDF }
    private var hasImages: Bool { queue.items.contains { $0.kind == .image } }

    private var actionTitle: String {
        switch mode {
        case .merge: return "Merge PDFs"
        case .images: return separate ? "Create PDFs" : "Create PDF"
        }
    }

    var body: some View {
        ToolScaffold(tool: tool, job: job, actionTitle: actionTitle,
                     actionEnabled: !queue.items.isEmpty, action: run) {
            HStack(spacing: 0) {
                FileQueueView(queue: queue,
                              emptyTitle: mode == .merge ? "Drop PDFs here" : "Drop images here",
                              emptySubtitle: mode == .merge
                                ? "Images work too. They become pages."
                                : "JPG, PNG, HEIC, TIFF, or a whole folder")
                Divider()
                options
                    .frame(width: 290)
            }
        }
        .onReceive(app.$pendingURLs) { urls in
            guard mode == .merge, !urls.isEmpty else { return }
            DispatchQueue.main.async {
                queue.add(urls: urls)
                app.pendingURLs = []
            }
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Options").font(.headline)
            if mode == .images || hasImages {
                Picker("Image pages", selection: $pageSize) {
                    ForEach(PageSizeOption.allCases) { Text($0.label).tag($0) }
                }
                Picker("Image quality", selection: $quality) {
                    ForEach(ImageQuality.allCases) { Text($0.label).tag($0) }
                }
            }
            Toggle("Make text searchable (OCR)", isOn: $ocr)
                .help("Recognises text in images and scanned pages with Apple's on-device Vision AI.")
            if mode == .images {
                Toggle("One PDF per image", isOn: $separate)
            }
            Spacer()
            Text("Pages are added in list order. Drag rows to change it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func run() {
        let items = queue.items
        guard !items.isEmpty else { return }
        let options = CombineOptions(pageSize: pageSize, quality: quality, ocr: ocr)
        let folder = items.first?.url.deletingLastPathComponent()

        if mode == .images && separate {
            guard let target = Panels.chooseFolder(message: "Choose where to save the PDFs", near: folder) else { return }
            job.run("Creating PDFs…") { progress in
                let urls = try PDFEngine.imagesToSeparatePDFs(items, options: options, folder: target, progress: progress)
                return JobRunner.Outcome(urls: urls, message: "Saved \(urls.count) PDFs")
            }
        } else {
            let suggested: String
            if items.count == 1 {
                suggested = Naming.base(items[0].url) + ".pdf"
            } else {
                suggested = mode == .merge ? "Merged.pdf" : "Images.pdf"
            }
            guard let output = Panels.savePDF(suggested: suggested, near: folder) else { return }
            job.run(ocr ? "Creating PDF and recognising text…" : "Creating PDF…") { progress in
                let pages = try PDFEngine.combine(items, to: output, options: options, progress: progress)
                return JobRunner.Outcome(urls: [output],
                                         message: "Saved \(output.lastPathComponent) · \(Naming.pages(pages))")
            }
        }
    }
}
