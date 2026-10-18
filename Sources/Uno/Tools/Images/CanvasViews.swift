import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CanvasEditorView: View {
    @ObservedObject var model: CanvasEditorModel

    var body: some View {
        VStack(spacing: 0) {
            EditorToolbar(model: model)
                .buttonStyle(.neu)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            Divider()
            HStack(spacing: 0) {
                CanvasStage(model: model)
                Divider()
                InspectorPanel(model: model)
                    .buttonStyle(.neu)
                    .frame(width: 300)
            }
        }
    }
}

// MARK: - Toolbar

struct EditorToolbar: View {
    @ObservedObject var model: CanvasEditorModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("Tool", selection: $model.mode) {
                ForEach(EditorMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)

            Divider().frame(height: 22)

            switch model.mode {
            case .move:
                Button { model.presentAddImages() } label: { Label("Add Image", systemImage: "photo.badge.plus") }
                    .help("Add PNG, JPEG, HEIC, TIFF, WebP or PDF")
                Button { model.addText() } label: { Label("Text", systemImage: "textformat") }
                Button { model.pasteImage() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .help("Paste an image from the clipboard")
            case .crop:
                Picker("Ratio", selection: $model.cropAspect) {
                    ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 200)
                Button("Apply Crop") { model.applyCrop() }
                    .buttonStyle(.neuProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Apply crop (⌘↩)")
                Button("Cancel") { model.mode = .move }
            case .distort:
                Text(model.selectedLayer == nil ? "Click an image, then drag its corners" : "Drag the four corners")
                    .foregroundStyle(.secondary)
                Button("Reset Corners") { model.removeDistortion(); model.mode = .distort }
                    .disabled(model.selectedLayer?.corners == nil)
            }

            Spacer()

            HStack(spacing: 6) {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo (⌘Z)")
                    .disabled(!model.canUndo)
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("Redo (⇧⌘Z)")
                    .disabled(!model.canRedo)
            }

            Divider().frame(height: 22)

            HStack(spacing: 6) {
                Button { model.zoom(by: 1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out (⌘-)")
                    .keyboardShortcut("-", modifiers: .command)
                Button("Fit") { model.zoom = nil }
                Button { model.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in (⌘+)")
                    .keyboardShortcut("=", modifiers: .command)
                Button {
                    if let doc = model.doc { CanvasRenderer.print(doc) }
                } label: { Image(systemName: "printer") }
                    .help("Print at exact physical size")
            }
        }
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Canvas

struct CanvasStage: View {
    @ObservedObject var model: CanvasEditorModel
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            if let doc = model.doc {
                StageContent(model: model, doc: doc, viewport: geo.size, onInteract: { focused = true })
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onDeleteCommand { model.deleteSelected() }
        .onMoveCommand { direction in
            let step: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 10 : 1
            switch direction {
            case .up: model.nudge(dx: 0, dy: -step)
            case .down: model.nudge(dx: 0, dy: step)
            case .left: model.nudge(dx: -step, dy: 0)
            case .right: model.nudge(dx: step, dy: 0)
            @unknown default: break
            }
        }
        .onPasteCommand(of: [UTType.image, UTType.fileURL]) { _ in model.pasteImage() }
        .onExitCommand {
            if model.mode != .move { model.mode = .move } else { model.select(nil) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            model.addImages(urls: files)
            return true
        }
    }
}

private struct StageContent: View {
    @ObservedObject var model: CanvasEditorModel
    let doc: CanvasDocument
    let viewport: CGSize
    let onInteract: () -> Void

    private static let checker: NSImage = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        NSColor(white: 0.86, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSRect(x: 8, y: 8, width: 8, height: 8).fill()
        return true
    }

    private var zoom: CGFloat {
        let fit = min((viewport.width - 80) / max(1, doc.width), (viewport.height - 80) / max(1, doc.height))
        return model.zoom ?? max(0.01, fit)
    }
    private var canvasSize: CGSize { CGSize(width: doc.width * zoom, height: doc.height * zoom) }
    private var contentSize: CGSize {
        CGSize(width: max(viewport.width, canvasSize.width + 80), height: max(viewport.height, canvasSize.height + 80))
    }
    private var origin: CGPoint {
        CGPoint(x: (contentSize.width - canvasSize.width) / 2, y: (contentSize.height - canvasSize.height) / 2)
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            stack
        }
        .background(Theme.background)
        .overlay(alignment: .bottomLeading) { infoBadge }
        .overlay { hints }
        .onAppear { model.displayZoom = zoom }
        .onChange(of: zoom) { _, newValue in model.displayZoom = newValue }
    }

    private var stack: some View {
        let z = zoom
        let o = origin
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: contentSize.width, height: contentSize.height)
            canvas(zoom: z)
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                .clipped()
                .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                .offset(x: o.x, y: o.y)
            overlay(zoom: z)
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                .offset(x: o.x, y: o.y)
                .allowsHitTesting(false)
        }
        .frame(width: contentSize.width, height: contentSize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onInteract()
                    model.displayZoom = z
                    model.dragChanged(start: value.startLocation - o,
                                      current: value.location - o,
                                      zoom: z,
                                      snap: NSEvent.modifierFlags.contains(.shift))
                }
                .onEnded { _ in model.dragEnded() }
        )
    }

    private var infoBadge: some View {
        Text("\(Int((zoom * 100).rounded()))%  ·  \(doc.sizeDescription)")
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(10)
    }

    @ViewBuilder
    private var hints: some View {
        if let message = model.busyMessage {
            VStack(spacing: 10) {
                ProgressView()
                Text(message)
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        } else if doc.layers.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.plus").font(.largeTitle)
                Text("Drop images here or click Add Image")
            }
            .foregroundStyle(.secondary)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
        }
    }

    private func canvas(zoom: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            background
                .frame(width: doc.width * zoom, height: doc.height * zoom)
            ForEach(doc.layers) { layer in
                if !layer.isHidden {
                    LayerImage(layer: layer, zoom: zoom)
                }
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if let color = doc.backgroundColor {
            Color(cgColor: color)
        } else {
            Image(nsImage: Self.checker).resizable(resizingMode: .tile)
        }
    }

    @ViewBuilder
    private func overlay(zoom: CGFloat) -> some View {
        switch model.mode {
        case .move:
            if let layer = model.selectedLayer {
                SelectionOverlay(points: layer.quad.map { $0 * zoom },
                                 rotateHandle: layer.corners == nil ? model.rotationHandle(for: layer, zoom: zoom) * zoom : nil,
                                 showCorners: layer.corners == nil)
            }
        case .distort:
            if let corners = model.selectedLayer?.corners {
                SelectionOverlay(points: corners.map { $0 * zoom }, rotateHandle: nil, showCorners: true, round: true)
            }
        case .crop:
            CropOverlay(rect: CGRect(x: model.cropRect.minX * zoom, y: model.cropRect.minY * zoom,
                                     width: model.cropRect.width * zoom, height: model.cropRect.height * zoom))
        }
    }
}

private struct LayerImage: View {
    let layer: ImageLayer
    let zoom: CGFloat

    var body: some View {
        Image(decorative: layer.displayImage, scale: 1)
            .resizable()
            .interpolation(.high)
            .frame(width: layer.naturalSize.width, height: layer.naturalSize.height)
            .projectionEffect(layer.projection(zoom: zoom))
            .opacity(layer.opacity)
    }
}

struct SelectionOverlay: View {
    let points: [CGPoint]
    let rotateHandle: CGPoint?
    var showCorners = true
    var round = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for p in points.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
            }
            .stroke(Theme.accentDeep, lineWidth: 1.5)

            if let handle = rotateHandle, points.count >= 2 {
                Path { path in
                    path.move(to: (points[0] + points[1]) / 2)
                    path.addLine(to: handle)
                }
                .stroke(Theme.accentDeep, lineWidth: 1)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Theme.accentDeep, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                    .position(handle)
            }

            if showCorners {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    Group {
                        if round {
                            Circle()
                                .fill(Color.white)
                                .overlay(Circle().stroke(Theme.accentDeep, lineWidth: 2))
                                .frame(width: 14, height: 14)
                        } else {
                            Rectangle()
                                .fill(Color.white)
                                .overlay(Rectangle().stroke(Theme.accentDeep, lineWidth: 1.5))
                                .frame(width: 10, height: 10)
                        }
                    }
                    .position(point)
                }
            }
        }
    }
}

struct CropOverlay: View {
    let rect: CGRect

    var body: some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(CGRect(x: -20000, y: -20000, width: 40000, height: 40000))
                path.addRect(rect)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

            Path { path in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: rect.minY))
                    path.addLine(to: CGPoint(x: x, y: rect.maxY))
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    path.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.6), lineWidth: 0.75)

            Path { path in path.addRect(rect) }
                .stroke(Color.white, lineWidth: 1.5)

            ForEach(Array([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)].enumerated()),
                    id: \.offset) { _, point in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(radius: 1)
                    .position(point)
            }
        }
    }
}

// MARK: - Inspector

struct InspectorPanel: View {
    @ObservedObject var model: CanvasEditorModel
    @State private var showTransform = true
    @State private var showAdjust = true
    @State private var showAI = true
    @State private var confirmNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                canvasSection
                Divider()
                if let layer = model.selectedLayer {
                    layerSection(layer)
                    Divider()
                }
                layersSection
            }
            .padding(16)
        }
        .confirmationDialog("Start a new canvas?", isPresented: $confirmNew) {
            Button("Discard and Start Over", role: .destructive) { model.closeCanvas() }
        } message: {
            Text("The current canvas will be closed. Export it first if you want to keep it.")
        }
    }

    // MARK: Canvas

    private var canvasSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Canvas").font(.headline)
                Spacer()
                Button("New…") {
                    if model.doc?.layers.isEmpty ?? true { model.closeCanvas() } else { confirmNew = true }
                }
                .controlSize(.small)
            }
            if let doc = model.doc {
                Text(doc.sizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Picker("Background", selection: model.backgroundKindBinding) {
                    ForEach(BackgroundKind.allCases) { Text($0.label).tag($0) }
                }
                if model.doc?.backgroundKind == .color {
                    ColorPicker("", selection: model.backgroundColorBinding, supportsOpacity: false)
                        .labelsHidden()
                }
            }
            HStack {
                Button { model.rotateCanvas(clockwise: false) } label: { Label("Rotate", systemImage: "rotate.left") }
                Button { model.rotateCanvas(clockwise: true) } label: { Label("Rotate", systemImage: "rotate.right") }
                Button { model.mode = .crop } label: { Label("Crop", systemImage: "crop") }
            }
            .controlSize(.small)
        }
    }

    // MARK: Selected layer

    @ViewBuilder
    private func layerSection(_ layer: ImageLayer) -> some View {
        Text(layer.text == nil ? "Selected image" : "Selected text").font(.headline)

        if layer.text != nil {
            textControls
        }

        DisclosureGroup("Transform", isExpanded: $showTransform) {
            VStack(alignment: .leading, spacing: 10) {
                if layer.corners != nil {
                    Text("This layer is distorted. Size, rotation and skew are locked until you remove the distortion.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Remove Distortion") { model.removeDistortion() }
                }
                Group {
                    slider("Size", value: model.logScaleBinding, range: -6...3,
                           text: "\(Int((layer.scaleX * 100).rounded()))%")
                    Toggle("Keep proportions", isOn: $model.keepProportions)
                    if !model.keepProportions {
                        slider("Width", value: model.percentBinding(\.scaleX), range: 1...400,
                               text: "\(Int((layer.scaleX * 100).rounded()))%")
                        slider("Height", value: model.percentBinding(\.scaleY), range: 1...400,
                               text: "\(Int((layer.scaleY * 100).rounded()))%")
                    }
                    slider("Rotate", value: model.layerBinding(\.rotation, default: 0), range: -180...180,
                           text: "\(Int(layer.rotation.rounded()))°")
                    HStack {
                        iconButton("rotate.left", help: "Rotate 90° left") { model.rotateSelected(by: -90) }
                        iconButton("rotate.right", help: "Rotate 90° right") { model.rotateSelected(by: 90) }
                        iconButton("arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip horizontally") {
                            model.flipSelected(horizontal: true)
                        }
                        iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip vertically") {
                            model.flipSelected(horizontal: false)
                        }
                    }
                    slider("Skew horizontal", value: model.layerBinding(\.skewX, default: 0), range: -60...60,
                           text: "\(Int(layer.skewX.rounded()))°")
                    slider("Skew vertical", value: model.layerBinding(\.skewY, default: 0), range: -60...60,
                           text: "\(Int(layer.skewY.rounded()))°")
                }
                .disabled(layer.corners != nil)

                slider("Opacity", value: model.percentBinding(\.opacity), range: 1...100,
                       text: "\(Int((layer.opacity * 100).rounded()))%")

                HStack {
                    Button("Fit") { model.fitSelected(fill: false) }
                        .help("Fit inside the canvas")
                    Button("Fill") { model.fitSelected(fill: true) }
                        .help("Cover the whole canvas")
                    Button("Center") { model.centerSelected() }
                    Button("Reset") { model.resetSelectedTransform() }
                }
                .controlSize(.small)
            }
            .padding(.top, 6)
        }

        DisclosureGroup("Adjust & Filters", isExpanded: $showAdjust) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Filter", selection: Binding(
                    get: { layer.adjustments.filter },
                    set: { value in
                        model.checkpoint()
                        model.adjustmentBinding(\.filter, default: FilterPreset.none).wrappedValue = value
                    }
                )) {
                    ForEach(FilterPreset.allCases) { Text($0.label).tag($0) }
                }
                slider("Brightness", value: model.adjustmentBinding(\.brightness, default: 0), range: -0.5...0.5,
                       text: "\(Int((layer.adjustments.brightness * 200).rounded()))")
                slider("Contrast", value: model.adjustmentBinding(\.contrast, default: 1), range: 0.5...2,
                       text: "\(Int((layer.adjustments.contrast * 100).rounded()))%")
                slider("Saturation", value: model.adjustmentBinding(\.saturation, default: 1), range: 0...2,
                       text: "\(Int((layer.adjustments.saturation * 100).rounded()))%")
                slider("Sharpness", value: model.adjustmentBinding(\.sharpness, default: 0), range: 0...2,
                       text: "\(Int((layer.adjustments.sharpness * 50).rounded()))")
                Button("Reset Adjustments") { model.resetAdjustments() }
                    .controlSize(.small)
                    .disabled(layer.adjustments.isIdentity)
            }
            .padding(.top, 6)
        }

        if layer.text == nil {
            DisclosureGroup("On-device AI", isExpanded: $showAI) {
                VStack(alignment: .leading, spacing: 8) {
                    Button { model.runAI(.straightenDocument) } label: {
                        Label("Straighten Document", systemImage: "doc.viewfinder")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help("Finds the paper in a photo, flattens the perspective and crops to it")
                    Button { model.runAI(.removeBackground) } label: {
                        Label("Remove Background", systemImage: "person.crop.rectangle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help("Cuts out the person or object. Set the canvas background to white for ID photos.")
                    Text("Tip: Straighten Document, then the Scanned document filter, turns a phone photo into a clean scan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(model.busyMessage != nil)
                .padding(.top, 6)
            }
        }

        HStack {
            Button { model.duplicateSelected() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Spacer()
            Button(role: .destructive) { model.deleteSelected() } label: { Label("Delete", systemImage: "trash") }
        }
        .controlSize(.small)
    }

    private var textControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Text", text: model.textBinding(\.string, default: ""), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            HStack {
                Picker("Font", selection: model.textBinding(\.fontName, default: "Helvetica Neue")) {
                    ForEach(TextContent.fonts, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Toggle("Bold", isOn: model.textBinding(\.bold, default: false))
                    .toggleStyle(.button)
                ColorPicker("", selection: Binding(
                    get: { model.selectedLayer?.text?.color.color ?? .black },
                    set: { value in model.updateText { $0.color = RGB(value) } }
                ), supportsOpacity: false)
                .labelsHidden()
            }
            HStack {
                Text("Font size").font(.caption)
                Stepper(value: model.textBinding(\.fontSize, default: 60), in: 4...2000, step: 2) {
                    Text("\(Int(model.selectedLayer?.text?.fontSize ?? 60)) px").font(.caption.monospacedDigit())
                }
            }
        }
    }

    // MARK: Layers

    private var layersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layers").font(.headline)
                Spacer()
                iconButton("chevron.up", help: "Bring forward") { model.moveSelected(by: 1) }
                    .disabled(model.selectedLayer == nil)
                iconButton("chevron.down", help: "Send backward") { model.moveSelected(by: -1) }
                    .disabled(model.selectedLayer == nil)
                iconButton("plus", help: "Add image") { model.presentAddImages() }
            }
            if let layers = model.doc?.layers, !layers.isEmpty {
                ForEach(Array(layers.reversed())) { layer in
                    LayerRow(layer: layer,
                             selected: layer.id == model.selectedID,
                             toggleHidden: { model.toggleHidden(layer.id) })
                        .onTapGesture { model.select(layer.id) }
                }
            } else {
                Text("No layers yet. Add an image or text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(text)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, onEditingChanged: { began in
                if began { model.checkpoint() }
            })
            .controlSize(.small)
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .help(help)
            .buttonStyle(.borderless)
    }
}

struct LayerRow: View {
    let layer: ImageLayer
    let selected: Bool
    let toggleHidden: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(decorative: layer.displayImage, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .background(Color.gray.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name).lineLimit(1).truncationMode(.middle)
                Text(layer.text != nil ? "Text" : "\(layer.image.width) × \(layer.image.height) px")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: toggleHidden) {
                Image(systemName: layer.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(layer.isHidden ? Color.secondary : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(layer.isHidden ? "Show layer" : "Hide layer")
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accentDeep.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
    }
}
