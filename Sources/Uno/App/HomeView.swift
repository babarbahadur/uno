import SwiftUI
import AppKit

struct HomeView: View {
    @EnvironmentObject var app: AppState
    @State private var query = ""
    @State private var category: ToolCategory?

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var searchResults: [ToolID] {
        ToolID.allCases.filter { tool in
            let inCategory = category.map { tool.categories.contains($0) } ?? true
            let text = "\(tool.title) \(tool.subtitle) \(tool.keywords)".lowercased()
            return inCategory && (trimmedQuery.isEmpty || text.contains(trimmedQuery))
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            HomeSidebar(query: $query, category: $category)
                .frame(width: 250)
                .padding(18)

            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if trimmedQuery.isEmpty && category == nil {
                        if !app.recent.isEmpty { recentSection }
                        ForEach(ToolCategory.allCases) { cat in
                            categorySection(cat)
                        }
                    } else if searchResults.isEmpty {
                        emptyState
                    } else {
                        toolGrid(searchResults)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 28)
            }
        }
        .background(Theme.background)
        .navigationTitle("Uno")
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            app.openFiles(files)
            return true
        }
    }

    // MARK: Sections

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(trimmedQuery.isEmpty ? greeting : "Results for “\(query)”")
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.inkSoft)
            Text(category?.title ?? "What are we working on?")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.ink)
            if let category {
                Text(category.blurb)
                    .foregroundStyle(Theme.inkSoft)
            }
        }
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Jump back in", symbol: "clock.arrow.circlepath")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(app.recent) { tool in
                        RecentChip(tool: tool)
                    }
                }
                .padding(14)
            }
            .padding(-14)
        }
    }

    private func categorySection(_ category: ToolCategory) -> some View {
        // Each tool appears once, under its main category.
        let tools = ToolID.allCases.filter { $0.categories.first == category }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(category.title, symbol: category.symbol, tint: category.tint)
                Text(category.blurb)
                    .font(.callout)
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Button("See all") { self.category = category }
                    .buttonStyle(.plain)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.accentDeep)
            }
            toolGrid(tools)
        }
    }

    private func toolGrid(_ tools: [ToolID]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 22)],
                  alignment: .leading, spacing: 22) {
            ForEach(tools) { tool in
                ToolTile(tool: tool)
            }
        }
        .padding(6)
    }

    private func sectionTitle(_ title: String, symbol: String, tint: Color = Theme.accentDeep) -> some View {
        Label {
            Text(title)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(Theme.ink)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent)
                .frame(width: 80, height: 80)
                .neuInset(radius: 40, depth: 4)
            Text("Nothing matches “\(query)”")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Button("Clear search") { query = "" }
                .buttonStyle(.neu)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - Sidebar

private struct HomeSidebar: View {
    @Binding var query: String
    @Binding var category: ToolCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 46, height: 46)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Uno")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                    Text("Private file studio")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }

            NeuSearchField(text: $query, placeholder: "Find a tool")

            VStack(spacing: 8) {
                CategoryRow(title: "Everything", symbol: "square.grid.2x2", tint: Theme.accentDeep,
                            count: ToolID.availableCount, selected: category == nil) { category = nil }
                ForEach(ToolCategory.allCases) { cat in
                    CategoryRow(title: cat.title, symbol: cat.symbol, tint: cat.tint,
                                count: ToolID.tools(in: cat).count, selected: category == cat) { category = cat }
                }
            }

            Spacer(minLength: 10)

            VStack(alignment: .leading, spacing: 4) {
                Label("Nothing leaves this Mac", systemImage: "lock.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("Every tool runs offline. Drop files anywhere to merge them.")
                    .font(.caption2)
                    .foregroundStyle(Theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .neuInset(radius: 14, depth: 3)

            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.neu)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .neuRaised(radius: 26, depth: 9)
    }
}

private struct CategoryRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .neuRaised(radius: 9, depth: selected ? 2 : 3)
                Text(title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkSoft)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                if selected {
                    Color.clear.neuInset(radius: 12, depth: 3)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.shadowDark.opacity(0.12))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Tiles

private struct ToolTile: View {
    @EnvironmentObject var app: AppState
    let tool: ToolID
    @State private var hovering = false

    var body: some View {
        Button { app.open(tool) } label: {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    ToolIcon(tool: tool, size: 48)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.accentDeep)
                        .frame(width: 26, height: 26)
                        .neuInset(radius: 13, depth: 2)
                        .opacity(hovering ? 1 : 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.title)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(Theme.ink)
                    Text(tool.subtitle)
                        .font(.callout)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
            .neuRaised(radius: 22, depth: hovering ? 11 : 7)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .animation(.easeOut(duration: 0.18), value: hovering)
        }
        .buttonStyle(TilePressStyle())
        .onHover { hovering = $0 }
        .help(tool.detail)
    }
}

private struct RecentChip: View {
    @EnvironmentObject var app: AppState
    let tool: ToolID

    var body: some View {
        Button { app.open(tool) } label: {
            HStack(spacing: 10) {
                ToolIcon(tool: tool, size: 30)
                Text(tool.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.leading, 10)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .neuRaised(radius: 18, depth: 5)
        }
        .buttonStyle(TilePressStyle())
    }
}
