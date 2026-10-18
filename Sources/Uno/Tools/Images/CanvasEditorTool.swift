import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CanvasEditorTool: View {
    @StateObject private var model = CanvasEditorModel()
    @StateObject private var job = JobRunner()
    @State private var setup = CanvasSetup()
    @State private var showExport = false

    var body: some View {
        ToolScaffold(tool: .canvasEditor, job: job,
                     actionTitle: model.doc == nil ? "Create Canvas" : "Export…",
                     actionEnabled: true, action: primaryAction) {
            if model.doc == nil {
                NewCanvasView(model: model, setup: $setup)
            } else {
                CanvasEditorView(model: model)
            }
        }
        .sheet(isPresented: $showExport) {
            if let doc = model.doc {
                ExportSheet(doc: doc) { format, resolution, quality in
                    export(doc, format: format, resolution: resolution, quality: quality)
                }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { AppState.shared.activeEditor = model }
        .onDisappear {
            if AppState.shared.activeEditor === model { AppState.shared.activeEditor = nil }
        }
    }

    private func primaryAction() {
        if model.doc == nil {
            model.newCanvas(setup)
        } else {
            if model.mode == .crop { model.applyCrop() }
            showExport = true
        }
    }

    private func export(_ doc: CanvasDocument, format: CanvasExportFormat, resolution: ExportResolution, quality: CGFloat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(doc.layers.first?.name ?? "Canvas") edited.\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        showExport = false
        let pixels = CanvasRenderer.pixelSize(doc, scale: resolution.scale)
        job.run("Exporting…") { progress in
            progress(0.3)
            try CanvasRenderer.export(doc, format: format, resolution: resolution, quality: quality, to: url)
            return JobRunner.Outcome(urls: [url],
                                     message: "Saved \(url.lastPathComponent) · \(Int(pixels.width)) × \(Int(pixels.height)) px")
        }
    }
}

// MARK: - New canvas

struct NewCanvasView: View {
    @ObservedObject var model: CanvasEditorModel
    @Binding var setup: CanvasSetup

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(CanvasPreset.groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group).font(.headline)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                            ForEach(CanvasPreset.all.filter { $0.group == group }) { preset in
                                presetCard(id: preset.id, name: preset.name, detail: preset.sizeText,
                                           aspect: preset.width / preset.height)
                            }
                            if group == CanvasPreset.groups.last {
                                presetCard(id: "custom", name: "Custom size", detail: "Any size",
                                           aspect: setup.customWidth / max(0.1, setup.customHeight))
                            }
                        }
                    }
                }

                if setup.preset == nil {
                    HStack(spacing: 10) {
                        TextField("Width", value: $setup.customWidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("×")
                        TextField("Height", value: $setup.customHeight, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Picker("Unit", selection: $setup.customUnit) {
                            ForEach(LengthUnit.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }

                Divider()

                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Orientation").font(.subheadline.weight(.semibold))
                        Button {
                            setup.rotated.toggle()
                        } label: {
                            Label(setup.physicalSize.width >= setup.physicalSize.height ? "Landscape" : "Portrait",
                                  systemImage: "rotate.right")
                        }
                    }
                    if setup.unit != .px {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Resolution").font(.subheadline.weight(.semibold))
                            Picker("Resolution", selection: $setup.dpi) {
                                Text("150 dpi").tag(150.0)
                                Text("300 dpi").tag(300.0)
                                Text("600 dpi").tag(600.0)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 240)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Background").font(.subheadline.weight(.semibold))
                        HStack {
                            Picker("Background", selection: $setup.background) {
                                ForEach(BackgroundKind.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 130)
                            if setup.background == .color {
                                ColorPicker("Colour", selection: Binding(
                                    get: { setup.backgroundRGB.color },
                                    set: { setup.backgroundRGB = RGB($0) }
                                ), supportsOpacity: false)
                                .labelsHidden()
                            }
                        }
                    }
                }

                let pixels = setup.pixelSize
                Text("New canvas: \(CanvasPreset.format(setup.physicalSize.width)) × \(CanvasPreset.format(setup.physicalSize.height)) \(setup.unit.label) · \(Int(pixels.width)) × \(Int(pixels.height)) px")
                    .foregroundStyle(.secondary)

                Divider()

                HStack(spacing: 12) {
                    Button {
                        openImage()
                    } label: {
                        Label("Open an Image Instead…", systemImage: "photo")
                    }
                    Text("Start from a photo at its own size. Good for quick crops, straightening and filters. You can also drop an image here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
        }
        .onFileDrop { urls in
            if let url = urls.first { model.openImageAsCanvas(url) }
        }
    }

    private func presetCard(id: String, name: String, detail: String, aspect: Double) -> some View {
        let selected = setup.presetID == id
        let shown = setup.rotated && id == setup.presetID ? 1 / max(0.01, aspect) : aspect
        let boxW: CGFloat = shown >= 1 ? 54 : 54 * CGFloat(shown)
        let boxH: CGFloat = shown >= 1 ? 54 / CGFloat(shown) : 54
        return Button {
            setup.presetID = id
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white)
                        .frame(width: max(12, boxW), height: max(12, boxH))
                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                }
                .frame(height: 60)
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background {
                if selected {
                    Color.clear.neuInset(radius: 16, depth: 4)
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.accent.opacity(0.6), lineWidth: 1.5))
                } else {
                    Color.clear.neuRaised(radius: 16, depth: 6)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(TilePressStyle())
    }

    private func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.openImageAsCanvas(url)
        }
    }
}

// MARK: - Export sheet

struct ExportSheet: View {
    let doc: CanvasDocument
    let onExport: (CanvasExportFormat, ExportResolution, CGFloat) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var format: CanvasExportFormat = .png
    @State private var resolutionID: String
    @State private var quality: CGFloat = 0.9

    init(doc: CanvasDocument, onExport: @escaping (CanvasExportFormat, ExportResolution, CGFloat) -> Void) {
        self.doc = doc
        self.onExport = onExport
        _resolutionID = State(initialValue: CanvasRenderer.defaultResolution(for: doc).id)
    }

    private var resolutions: [ExportResolution] { CanvasRenderer.resolutions(for: doc) }

    private var note: String {
        switch format {
        case .png: return doc.backgroundKind == .transparent
            ? "PNG keeps the transparent background. Best quality, larger file."
            : "PNG is lossless: best quality, larger file."
        case .jpeg: return "JPEG makes small files. Transparent areas become white."
        case .pdf: return doc.isPhysical
            ? "PDF keeps the exact physical size, ready to print."
            : "PDF, sized from the image's resolution."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.weight(.semibold))

            Picker("Format", selection: $format) {
                ForEach(CanvasExportFormat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Resolution").font(.headline)
            Picker("Resolution", selection: $resolutionID) {
                ForEach(resolutions) { resolution in
                    let pixels = CanvasRenderer.pixelSize(doc, scale: resolution.scale)
                    Text("\(resolution.label) · \(Int(pixels.width)) × \(Int(pixels.height)) px")
                        .tag(resolution.id)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if format != .png {
                HStack {
                    Text("Quality")
                    Slider(value: $quality, in: 0.3...1)
                    Text("\(Int(quality * 100))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }

            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    if let resolution = resolutions.first(where: { $0.id == resolutionID }) {
                        onExport(format, resolution, quality)
                    }
                }
                .buttonStyle(.neuProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.background)
        .tint(Theme.accentBottom)
    }
}
