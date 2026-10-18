import SwiftUI

// MARK: - Split PDF

struct SplitTool: View {
    @StateObject private var source = PDFSource()
    @StateObject private var job = JobRunner()
    @State private var pagesPerFile = 1

    private var fileCount: Int {
        let count = source.pageCount
        return count == 0 ? 0 : (count + pagesPerFile - 1) / pagesPerFile
    }

    var body: some View {
        ToolScaffold(tool: .split, job: job, actionTitle: "Split PDF",
                     actionEnabled: source.isReady && source.pageCount > 1, action: run) {
            PDFToolBody(source: source) {
                OptionsForm {
                    Text("How to split").font(.headline)
                    Stepper(value: $pagesPerFile, in: 1...max(1, source.pageCount - 1)) {
                        Text(pagesPerFile == 1 ? "One page per file" : "\(pagesPerFile) pages per file")
                    }
                    Text("This creates \(fileCount) file\(fileCount == 1 ? "" : "s") in the folder you choose.")
                        .foregroundStyle(.secondary)
                    Text("Need specific pages instead? Use Extract Pages.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onChange(of: source.loadID) { _, _ in pagesPerFile = 1 }
    }

    private func run() {
        guard let opener = source.opener,
              let folder = Panels.chooseFolder(message: "Choose where to save the \(fileCount) files", near: source.folder) else { return }
        let chunk = pagesPerFile
        job.run("Splitting…") { progress in
            let urls = try PDFEngine.split(opener, pagesPerFile: chunk, folder: folder, progress: progress)
            return JobRunner.Outcome(urls: urls, message: "Saved \(urls.count) files")
        }
    }
}

// MARK: - Compress PDF

struct CompressTool: View {
    @StateObject private var source = PDFSource()
    @StateObject private var job = JobRunner()
    @State private var level: CompressionLevel = .balanced
    @State private var ocr = true

    var body: some View {
        ToolScaffold(tool: .compress, job: job, actionTitle: "Compress PDF",
                     actionEnabled: source.isReady, action: run) {
            PDFToolBody(source: source) {
                OptionsForm {
                    Text("Compression").font(.headline)
                    Picker("Compression", selection: $level) {
                        ForEach(CompressionLevel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(level.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if level.rasterizes {
                        Toggle("Keep text searchable (on-device OCR)", isOn: $ocr)
                        Text("Pages become images, so the original text layer is replaced. OCR adds searchable text back. It's slower, but recommended.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func run() {
        guard let opener = source.opener,
              let output = Panels.savePDF(suggested: "\(source.baseName) (compressed).pdf", near: source.folder) else { return }
        let before = Naming.fileSize(source.url)
        let level = self.level
        let ocr = self.ocr
        job.run("Compressing…") { progress in
            let after = try PDFEngine.compress(opener, level: level, ocr: ocr, to: output, progress: progress)
            let message: String
            if after > 0 && after < before {
                let saved = Int((1 - Double(after) / Double(max(1, before))) * 100)
                message = "\(Naming.sizeString(before)) → \(Naming.sizeString(after)) · \(saved)% smaller"
            } else {
                message = "Saved, but this PDF was already compact (\(Naming.sizeString(after))). Try a stronger level."
            }
            return JobRunner.Outcome(urls: [output], message: message)
        }
    }
}

// MARK: - Add Password

struct AddPasswordTool: View {
    @StateObject private var source = PDFSource()
    @StateObject private var job = JobRunner()
    @State private var password = ""
    @State private var confirm = ""

    private var valid: Bool { !password.isEmpty && password == confirm }

    var body: some View {
        ToolScaffold(tool: .addPassword, job: job, actionTitle: "Protect PDF",
                     actionEnabled: source.isReady && valid, action: run) {
            PDFToolBody(source: source) {
                OptionsForm {
                    Text("Choose a password").font(.headline)
                    SecureField("New password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    SecureField("Repeat password", text: $confirm)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 320)
                    if !confirm.isEmpty && password != confirm {
                        Text("The passwords don't match.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Label("Anyone opening the PDF will need this password. It can't be recovered if you forget it.",
                          systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func run() {
        guard valid, let opener = source.opener,
              let output = Panels.savePDF(suggested: "\(source.baseName) (protected).pdf", near: source.folder) else { return }
        let password = self.password
        job.run("Encrypting…") { _ in
            try PDFEngine.protect(opener, password: password, to: output)
            return JobRunner.Outcome(urls: [output], message: "Saved \(output.lastPathComponent) with a password")
        }
    }
}

// MARK: - Remove Password

struct RemovePasswordTool: View {
    @StateObject private var source = PDFSource()
    @StateObject private var job = JobRunner()

    var body: some View {
        ToolScaffold(tool: .removePassword, job: job, actionTitle: "Save Unlocked Copy",
                     actionEnabled: source.isReady && source.isEncrypted, action: run) {
            PDFToolBody(source: source) {
                OptionsForm {
                    if source.isEncrypted {
                        Label("Unlocked. Save a copy that opens without a password.", systemImage: "lock.open.fill")
                            .font(.headline)
                    } else {
                        Label("This PDF isn't password-protected.", systemImage: "checkmark.shield")
                            .font(.headline)
                    }
                    Text("Only remove passwords from PDFs you own or have permission to unlock. The original file isn't changed.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func run() {
        guard let opener = source.opener,
              let output = Panels.savePDF(suggested: "\(source.baseName) (unlocked).pdf", near: source.folder) else { return }
        job.run("Unlocking…") { _ in
            try PDFEngine.removePassword(opener, to: output)
            return JobRunner.Outcome(urls: [output], message: "Saved \(output.lastPathComponent) without a password")
        }
    }
}

// MARK: - PDF to Images

struct PDFToImagesTool: View {
    @StateObject private var source = PDFSource()
    @StateObject private var job = JobRunner()
    @State private var format: ImageFormat = .png
    @State private var dpi: Int = 150

    var body: some View {
        ToolScaffold(tool: .pdfToImages, job: job, actionTitle: "Export Images",
                     actionEnabled: source.isReady, action: run) {
            PDFToolBody(source: source) {
                OptionsForm {
                    Text("Format").font(.headline)
                    Picker("Format", selection: $format) {
                        ForEach(ImageFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)

                    Text("Resolution").font(.headline)
                    Picker("Resolution", selection: $dpi) {
                        Text("Screen · 72 dpi").tag(72)
                        Text("Standard · 150 dpi").tag(150)
                        Text("Print · 300 dpi").tag(300)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    Text("Each page becomes its own image file in the folder you choose.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func run() {
        guard let opener = source.opener,
              let folder = Panels.chooseFolder(message: "Choose where to save the images", near: source.folder) else { return }
        let format = self.format
        let dpi = CGFloat(self.dpi)
        job.run("Exporting pages…") { progress in
            let urls = try PDFEngine.exportImages(opener, format: format, dpi: dpi, folder: folder, progress: progress)
            return JobRunner.Outcome(urls: urls, message: "Saved \(urls.count) images")
        }
    }
}

// MARK: - Make PDF Searchable (On-device AI)

struct SearchableTool: View {
    @StateObject private var source = PDFSource()
    @StateObject private var job = JobRunner()

    var body: some View {
        ToolScaffold(tool: .makeSearchable, job: job, actionTitle: "Recognise Text",
                     actionEnabled: source.isReady, action: run) {
            PDFToolBody(source: source) {
                OptionsForm {
                    Label("Runs entirely on this Mac with built-in on-device AI.", systemImage: "cpu")
                        .font(.headline)
                    Text("Scanned pages get an invisible text layer, so you can search, select and copy their text. Pages that already contain text are left unchanged.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Tip: Merge PDFs and Images to PDF have the same option built in.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func run() {
        guard let opener = source.opener,
              let output = Panels.savePDF(suggested: "\(source.baseName) (searchable).pdf", near: source.folder) else { return }
        job.run("Recognising text…") { progress in
            let result = try PDFEngine.makeSearchable(opener, to: output, progress: progress)
            let message = result.recognised == 0
                ? "No scanned pages found. Saved an unchanged copy."
                : "Recognised text on \(result.recognised) of \(Naming.pages(result.total))"
            return JobRunner.Outcome(urls: [output], message: message)
        }
    }
}
