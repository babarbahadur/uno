import SwiftUI
import ImageIO

/// Batch Resize and Batch Convert share this screen; they differ in defaults and which options lead.
struct BatchImageTool: View {
    enum Mode {
        case resize
        case convert
    }

    let mode: Mode
    @StateObject private var queue = FileQueue(accepts: [.image])
    @StateObject private var job = JobRunner()
    @State private var options: BatchOptions
    @State private var showFineTune = false
    @State private var previewImage: CGImage?
    @State private var previewLoading = false

    init(mode: Mode) {
        self.mode = mode
        _options = State(initialValue: mode == .resize ? .resizeDefaults : .convertDefaults)
    }

    private var tool: ToolID { mode == .resize ? .resizeImage : .convertImage }

    private var actionTitle: String {
        let count = queue.items.count
        let noun = count == 1 ? "Image" : "Images"
        let verb = mode == .resize ? "Resize" : "Convert"
        return count == 0 ? "\(verb) Images" : "\(verb) \(count) \(noun)"
    }

    private var formats: [OutputFormatOption] {
        mode == .resize ? [.original] + OutputFormatOption.available : OutputFormatOption.available
    }

    var body: some View {
        ToolScaffold(tool: tool, job: job, actionTitle: actionTitle,
                     actionEnabled: !queue.items.isEmpty, action: run) {
            HStack(spacing: 0) {
                FileQueueView(queue: queue,
                              emptyTitle: "Drop images here",
                              emptySubtitle: "JPG, PNG, HEIC, TIFF, WebP… or a whole folder")
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if mode == .resize {
                            resizeSection
                            Divider()
                            formatSection
                        } else {
                            enhanceSection
                            Divider()
                            formatSection
                            Divider()
                            resizeToggleSection
                        }
                        Divider()
                        sizeLimitSection
                        Divider()
                        saveSection
                    }
                    .padding(18)
                }
                .frame(width: 330)
            }
        }
    }

    // MARK: Sections

    private var resizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resize").font(.headline)
            Picker("Resize by", selection: Binding(
                get: { options.resize ?? .longestSide },
                set: { options.resize = $0 }
            )) {
                ForEach(ResizeMode.allCases) { Text($0.label).tag($0) }
            }
            resizeInputs
            previewLine
        }
    }

    /// In Batch Convert, resizing is optional.
    private var resizeToggleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Also resize", isOn: Binding(
                get: { options.resize != nil },
                set: { options.resize = $0 ? .longestSide : nil }
            ))
            .font(.headline)
            if options.resize != nil {
                Picker("Resize by", selection: Binding(
                    get: { options.resize ?? .longestSide },
                    set: { options.resize = $0 }
                )) {
                    ForEach(ResizeMode.allCases) { Text($0.label).tag($0) }
                }
                resizeInputs
            }
            previewLine
        }
    }

    @ViewBuilder
    private var resizeInputs: some View {
        switch options.resize ?? .longestSide {
        case .percent:
            HStack {
                Slider(value: $options.percent, in: 5...200, step: 5)
                Text("\(Int(options.percent))%")
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        case .longestSide, .width, .height:
            HStack {
                TextField("Pixels", value: $options.pixels, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Text("px")
                Spacer()
                Menu("Presets") {
                    ForEach([640, 1080, 1280, 1600, 1920, 2048, 3840], id: \.self) { value in
                        Button("\(value) px") { options.pixels = value }
                    }
                }
                .frame(width: 100)
            }
        case .fitBox, .exactFill:
            HStack {
                TextField("Width", value: $options.boxWidth, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                Text("×")
                TextField("Height", value: $options.boxHeight, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                Text("px")
                Spacer()
                Menu("Presets") {
                    Button("Full HD · 1920 × 1080") { setBox(1920, 1080) }
                    Button("4K · 3840 × 2160") { setBox(3840, 2160) }
                    Button("Square post · 1080 × 1080") { setBox(1080, 1080) }
                    Button("Portrait post · 1080 × 1350") { setBox(1080, 1350) }
                    Button("Story · 1080 × 1920") { setBox(1080, 1920) }
                    Button("Link preview · 1200 × 630") { setBox(1200, 630) }
                    Button("ID photo 35×45 mm @ 300 dpi · 413 × 531") { setBox(413, 531) }
                    Button("A4 @ 300 dpi · 2480 × 3508") { setBox(2480, 3508) }
                }
                .frame(width: 100)
            }
        }
        if options.resize == .percent {
            EmptyView()
        } else if options.resize != .exactFill {
            Toggle("Don't enlarge smaller images", isOn: $options.dontEnlarge)
        } else {
            Text("Images are scaled to cover the size and the edges are trimmed evenly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var previewLine: some View {
        if let first = queue.items.first(where: { $0.id == queue.selection }) ?? queue.items.first,
           let size = BatchImageEngine.orientedSize(of: first.url) {
            let result = BatchImageEngine.plan(for: size, options: options).canvas
            Label("\(first.name): \(Int(size.width)) × \(Int(size.height)) → \(Int(result.width)) × \(Int(result.height)) px",
                  systemImage: "eye")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(mode == .resize ? "Format" : "Convert to").font(.headline)
            Picker("Format", selection: $options.format) {
                ForEach(formats) { Text($0.label).tag($0) }
            }
            .labelsHidden()

            if options.format.lossy {
                HStack {
                    Text("Quality")
                    Slider(value: $options.quality, in: 0.3...1)
                    Text("\(Int((options.quality * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
            if !options.format.supportsAlpha {
                HStack {
                    Text("Fill transparent areas with")
                    Spacer()
                    ColorPicker("", selection: Binding(
                        get: { options.background.color },
                        set: { options.background = RGB($0) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                }
                .font(.callout)
            }
            if options.format.isPDF && mode == .convert {
                Toggle("Combine all into one PDF", isOn: $options.combinePDF)
                    .help("Pages follow the order of the list")
            }
            Toggle("Remove location & camera info", isOn: $options.stripMetadata)
                .help("Strips GPS location, camera model and other EXIF data, which is good for sharing online")
        }
    }

    private var sizeLimitSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Limit file size", isOn: $options.limitFileSize)
                .font(.headline)
                .disabled(options.format.isPDF)
            if options.limitFileSize && !options.format.isPDF {
                HStack {
                    Text("Max")
                    TextField("KB", value: $options.maxKilobytes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("KB")
                    Spacer()
                    Menu("Presets") {
                        ForEach([100, 200, 500, 1000, 2000], id: \.self) { kb in
                            Button(kb >= 1000 ? "\(kb / 1000) MB" : "\(kb) KB") { options.maxKilobytes = kb }
                        }
                    }
                    .frame(width: 100)
                }
                Text(options.format.lossy
                     ? "Lowers quality first, then pixel size, until each file fits. Handy for upload forms."
                     : "This format is lossless, so only the pixel size can be reduced. JPEG or HEIC get much smaller.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save").font(.headline)
            Toggle("Save next to the originals", isOn: $options.saveNextToOriginals)
            HStack {
                Text("Add to names")
                TextField("e.g. -small", text: $options.suffix)
                    .textFieldStyle(.roundedBorder)
            }
            Text("Originals are never changed or overwritten. A clashing name gets “(2)” added.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Enhance (Batch Convert)

    private struct PreviewKey: Equatable {
        let url: URL?
        let straighten: Bool
        let adjustments: LayerAdjustments
    }

    private var previewItem: InputItem? {
        queue.items.first(where: { $0.id == queue.selection }) ?? queue.items.first
    }

    private var enhanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Enhance").font(.headline)
                Spacer()
                Menu("Quick setup") {
                    Button("Phone photos → clean scans (one PDF)") { applyScanPreset(color: false, pdf: true) }
                    Button("Phone photos → clean colour scans (one PDF)") { applyScanPreset(color: true, pdf: true) }
                    Button("Phone photos → clean scans (JPEG)") { applyScanPreset(color: false, pdf: false) }
                    Divider()
                    Button("Clear enhancements") {
                        options.straightenDocuments = false
                        options.adjustments = LayerAdjustments()
                    }
                }
                .fixedSize()
            }

            Toggle("Straighten documents (on-device AI)", isOn: $options.straightenDocuments)
            Text("Finds the paper in each photo, flattens the perspective and crops to it. Photos without a clear document are saved as they are.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Filter", selection: $options.adjustments.filter) {
                ForEach(FilterPreset.allCases) { Text($0.label).tag($0) }
            }

            DisclosureGroup("Fine-tune", isExpanded: $showFineTune) {
                VStack(alignment: .leading, spacing: 8) {
                    adjustSlider("Brightness", value: $options.adjustments.brightness, range: -0.5...0.5,
                                 text: "\(Int((options.adjustments.brightness * 200).rounded()))")
                    adjustSlider("Contrast", value: $options.adjustments.contrast, range: 0.5...2,
                                 text: "\(Int((options.adjustments.contrast * 100).rounded()))%")
                    adjustSlider("Saturation", value: $options.adjustments.saturation, range: 0...2,
                                 text: "\(Int((options.adjustments.saturation * 100).rounded()))%")
                    adjustSlider("Sharpness", value: $options.adjustments.sharpness, range: 0...2,
                                 text: "\(Int((options.adjustments.sharpness * 50).rounded()))")
                    Button("Reset") {
                        let filter = options.adjustments.filter
                        options.adjustments = LayerAdjustments()
                        options.adjustments.filter = filter
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }

            if options.hasEnhancements {
                enhancePreview
            }
        }
        .task(id: PreviewKey(url: previewItem?.url, straighten: options.straightenDocuments,
                             adjustments: options.adjustments)) {
            await refreshPreview()
        }
    }

    @ViewBuilder
    private var enhancePreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
            if let previewImage {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(6)
            } else if previewItem == nil {
                Text("Add images to see a preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if previewLoading {
                ProgressView().controlSize(.small)
            }
        }
        .frame(height: 180)
        Text("Preview of \(previewItem?.name ?? "the selected image")")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func adjustSlider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(text).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private func applyScanPreset(color: Bool, pdf: Bool) {
        options.straightenDocuments = true
        options.adjustments = LayerAdjustments()
        options.adjustments.filter = color ? .scanColor : .scanBW
        if pdf {
            options.format = .pdf
            options.combinePDF = true
            options.quality = 0.8
        } else {
            options.format = .jpeg
            options.quality = 0.85
        }
        if options.resize == nil {
            options.resize = .longestSide
            options.pixels = 2480   // about A4 at 300 dpi
            options.dontEnlarge = true
        }
    }

    /// Builds a small preview of the selected image with the current enhancements, off the main thread.
    @MainActor
    private func refreshPreview() async {
        guard options.hasEnhancements, let url = previewItem?.url else {
            previewImage = nil
            previewLoading = false
            return
        }
        previewLoading = true
        let straighten = options.straightenDocuments
        let adjustments = options.adjustments
        let result: CGImage? = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  var image = ImageLoader.thumbnail(source, maxPixels: straighten ? 1600 : 700) else { return nil }
            if straighten, let flattened = try? ImageAI.straightenDocument(image) {
                image = flattened
            }
            return ImageFilters.apply(adjustments, to: image)
        }.value
        previewLoading = false
        guard !Task.isCancelled else { return }
        previewImage = result
    }

    // MARK: Actions

    private func setBox(_ width: Int, _ height: Int) {
        options.boxWidth = width
        options.boxHeight = height
    }

    private func run() {
        let items = queue.items
        guard !items.isEmpty else { return }
        let options = self.options
        var folder: URL?
        if !options.saveNextToOriginals {
            guard let chosen = Panels.chooseFolder(message: "Choose where to save the \(items.count) images",
                                                   near: items.first?.url.deletingLastPathComponent()) else { return }
            folder = chosen
        }
        let target = folder
        job.run(mode == .resize ? "Resizing \(items.count) images…" : "Converting \(items.count) images…") { progress in
            let summary = BatchImageEngine.run(items, options: options, folder: target, progress: progress)
            guard !summary.outputs.isEmpty else { throw BatchError.allFailed(summary.failures) }
            let combined = options.combinePDF && options.format.isPDF && items.count > 1
            let headline = combined
                ? "Combined \(items.count - summary.failures.count) images into one PDF"
                : "Saved \(summary.outputs.count) of \(items.count)"
            let sizes = "\(Naming.sizeString(summary.bytesIn)) → \(Naming.sizeString(summary.bytesOut))"
            var message = headline + " · " + sizes
            if !summary.failures.isEmpty {
                let names = summary.failures.prefix(3).joined(separator: ", ")
                message += " · skipped: \(names)\(summary.failures.count > 3 ? "…" : "")"
            }
            if !summary.notStraightened.isEmpty {
                message += " · no document found in \(summary.notStraightened.count) (saved as is)"
            }
            return JobRunner.Outcome(urls: summary.outputs, message: message)
        }
    }
}
