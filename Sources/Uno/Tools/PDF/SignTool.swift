import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Saved signature

enum SignatureStore {
    static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent("Uno", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("signature.png")
    }

    static func load() -> CGImage? {
        loadImage(at: url)
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func save(_ image: CGImage) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Sign PDF

struct SignTool: View {
    @StateObject private var source = PDFSource()
    @StateObject private var job = JobRunner()
    @State private var signature: CGImage? = SignatureStore.load()
    @State private var placements: [SignaturePlacement] = []
    @State private var selectedID: UUID?
    @State private var currentPage = 0
    @State private var pageImage: CGImage?
    @State private var pageSize = CGSize(width: 612, height: 792)
    @State private var dragOrigin: CGPoint?
    @State private var showPad = false

    var body: some View {
        ToolScaffold(tool: .sign, job: job, actionTitle: "Save Signed PDF",
                     actionEnabled: source.isReady && signature != nil && !placements.isEmpty, action: run) {
            PDFToolBody(source: source) {
                HStack(spacing: 0) {
                    pageArea
                    Divider()
                    sidePanel
                        .frame(width: 270)
                }
            }
        }
        .sheet(isPresented: $showPad) {
            SignaturePad { image in
                SignatureStore.save(image)
                signature = image
            }
        }
        .onChange(of: source.loadID) { _, _ in
            placements = []
            selectedID = nil
            currentPage = 0
            renderPage()
        }
        .onChange(of: currentPage) { _, _ in renderPage() }
    }

    // MARK: Page with signatures

    private var pageArea: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { currentPage -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(currentPage == 0)
                Text("Page \(currentPage + 1) of \(source.pageCount)")
                    .monospacedDigit()
                Button { currentPage += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(currentPage >= source.pageCount - 1)
                Spacer()
                Text("Drag a signature to move it")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Divider()

            GeometryReader { geo in
                let fitted = PDFEngine.aspectFit(pageSize, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 24, dy: 24))
                ZStack(alignment: .topLeading) {
                    Color.clear
                    if let pageImage {
                        Image(decorative: pageImage, scale: 1)
                            .resizable()
                            .frame(width: fitted.width, height: fitted.height)
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                            .onTapGesture { selectedID = nil }
                            .position(x: fitted.midX, y: fitted.midY)
                    }
                    if let signature {
                        ForEach(placements.filter { $0.page == currentPage }) { placement in
                            placementView(placement, signature: signature, fitted: fitted)
                        }
                    }
                }
            }
            .background(Theme.background)
        }
    }

    private func placementView(_ placement: SignaturePlacement, signature: CGImage, fitted: CGRect) -> some View {
        let width = max(1, placement.width * fitted.width)
        let height = width * CGFloat(signature.height) / CGFloat(max(1, signature.width))
        let isSelected = selectedID == placement.id

        return Image(decorative: signature, scale: 1)
            .resizable()
            .frame(width: width, height: height)
            .padding(4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.accentDeep, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .opacity(isSelected ? 1 : 0)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        selectedID = placement.id
                        guard let i = placements.firstIndex(where: { $0.id == placement.id }),
                              fitted.width > 0, fitted.height > 0 else { return }
                        let origin = dragOrigin ?? placements[i].center
                        if dragOrigin == nil { dragOrigin = origin }
                        let x = origin.x + value.translation.width / fitted.width
                        let y = origin.y + value.translation.height / fitted.height
                        placements[i].center = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .position(x: fitted.minX + placement.center.x * fitted.width,
                      y: fitted.minY + placement.center.y * fitted.height)
    }

    // MARK: Side panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your signature").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white)
                if let signature {
                    Image(decorative: signature, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .padding(12)
                } else {
                    Text("No signature yet")
                        .foregroundStyle(Color.gray)
                }
            }
            .frame(height: 110)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))

            HStack {
                Button("Draw…") { showPad = true }
                Button("Use Image…") { importSignature() }
            }

            Divider()

            Button { addPlacement() } label: {
                Label("Add to This Page", systemImage: "signature")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(signature == nil)

            if let id = selectedID, placements.contains(where: { $0.id == id }) {
                Text("Size").font(.subheadline)
                Slider(value: widthBinding(id), in: 0.06...0.7)
                Button(role: .destructive) {
                    placements.removeAll { $0.id == id }
                    selectedID = nil
                } label: {
                    Label("Remove Signature", systemImage: "trash")
                }
            }

            Spacer()

            Text("\(placements.count) signature\(placements.count == 1 ? "" : "s") placed. Your signature is saved on this Mac only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .buttonStyle(.neu)
    }

    private func widthBinding(_ id: UUID) -> Binding<CGFloat> {
        Binding(
            get: { placements.first(where: { $0.id == id })?.width ?? 0.28 },
            set: { value in
                if let i = placements.firstIndex(where: { $0.id == id }) { placements[i].width = value }
            }
        )
    }

    // MARK: Actions

    private func renderPage() {
        guard source.isReady,
              let cgPage = source.document?.page(at: currentPage)?.pageRef else {
            pageImage = nil
            return
        }
        let size = PDFEngine.displaySize(of: cgPage)
        pageSize = size
        let scale = min(2.5, 2400 / max(1, max(size.width, size.height)))
        pageImage = PDFEngine.render(cgPage, size: size, scale: scale)
    }

    private func addPlacement() {
        let placement = SignaturePlacement(page: currentPage, center: CGPoint(x: 0.7, y: 0.85), width: 0.28)
        placements.append(placement)
        selectedID = placement.id
    }

    private func importSignature() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an image of your signature (a PNG with a transparent background works best)"
        guard panel.runModal() == .OK, let url = panel.url,
              let image = SignatureStore.loadImage(at: url) else { return }
        SignatureStore.save(image)
        signature = image
    }

    private func run() {
        guard let opener = source.opener, let signature,
              let output = Panels.savePDF(suggested: "\(source.baseName) (signed).pdf", near: source.folder) else { return }
        let placements = self.placements
        job.run("Signing…") { progress in
            try PDFEngine.sign(opener, placements: placements, signature: signature, to: output, progress: progress)
            return JobRunner.Outcome(urls: [output], message: "Saved \(output.lastPathComponent)")
        }
    }
}

// MARK: - Signature drawing pad

struct SignaturePad: View {
    let onSave: (CGImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var blueInk = false

    private let canvasSize = CGSize(width: 540, height: 210)
    private var inkColor: Color { blueInk ? Color(red: 0.05, green: 0.15, blue: 0.55) : .black }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Draw your signature").font(.title3.weight(.semibold))
            Text("Use your trackpad or mouse.").foregroundStyle(.secondary)

            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 10).fill(Color.white)
                Rectangle()
                    .fill(Color.gray.opacity(0.35))
                    .frame(height: 1)
                    .padding(.horizontal, 30)
                    .padding(.bottom, 50)
                Canvas { context, _ in
                    for stroke in strokes + [current] where stroke.count > 1 {
                        var path = Path()
                        path.addLines(stroke)
                        context.stroke(path, with: .color(inkColor),
                                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.15)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in current.append(value.location) }
                    .onEnded { _ in
                        if current.count > 1 { strokes.append(current) }
                        current = []
                    }
            )

            HStack {
                Picker("Ink", selection: $blueInk) {
                    Text("Black").tag(false)
                    Text("Blue").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                Button("Clear") {
                    strokes = []
                    current = []
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save Signature") {
                    if let image = renderSignature() {
                        onSave(image)
                        dismiss()
                    }
                }
                .buttonStyle(.neuProminent)
                .disabled(strokes.isEmpty)
            }
        }
        .padding(24)
        .background(Theme.background)
        .tint(Theme.accentBottom)
    }

    /// Renders the strokes to a transparent, tightly cropped image at 3× resolution.
    private func renderSignature() -> CGImage? {
        let points = strokes.flatMap { $0 }
        guard !points.isEmpty else { return nil }
        let scale: CGFloat = 3
        let width = Int(canvasSize.width * scale)
        let height = Int(canvasSize.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Flip so we can draw in the canvas' top-left coordinates.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let color = blueInk
            ? CGColor(srgbRed: 0.05, green: 0.15, blue: 0.55, alpha: 1)
            : CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(3)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for stroke in strokes where stroke.count > 1 {
            ctx.beginPath()
            ctx.addLines(between: stroke)
            ctx.strokePath()
        }
        guard let full = ctx.makeImage() else { return nil }

        let xs = points.map(\.x), ys = points.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -8, dy: -8)
            .intersection(CGRect(origin: .zero, size: canvasSize))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return full }
        let crop = CGRect(x: bounds.minX * scale, y: bounds.minY * scale,
                          width: bounds.width * scale, height: bounds.height * scale)
        return full.cropping(to: crop) ?? full
    }
}
