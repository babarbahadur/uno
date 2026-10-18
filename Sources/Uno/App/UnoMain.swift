import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Finder "Open With → Uno" or files dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppState.shared.openFiles(urls)
    }
}

@main
struct UnoMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app = AppState.shared

    var body: some Scene {
        Window("Uno", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 980, minHeight: 660)
        }
        .commands { AppCommands(app: app) }

        Settings {
            SettingsView()
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack(path: $app.path) {
            HomeView()
                .navigationDestination(for: ToolID.self) { tool in
                    ToolView(tool: tool)
                        .id(tool)
                }
        }
        .tint(Theme.accentBottom)
        .foregroundStyle(Theme.ink)
        .background(Theme.background)
        .toolbarBackground(Theme.background, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
    }
}

/// Menu bar: one menu per tool category, so new tools appear automatically.
struct AppCommands: Commands {
    let app: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("All Tools") { app.goHome() }
                .keyboardShortcut("0", modifiers: .command)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { app.undo() }
                .keyboardShortcut("z", modifiers: .command)
            Button("Redo") { app.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("Images") { menuItems(for: .images) }
        CommandMenu("PDF") { menuItems(for: .pdf) }
        CommandMenu("On-device AI") { menuItems(for: .ai) }
    }

    @ViewBuilder
    private func menuItems(for category: ToolCategory) -> some View {
        ForEach(ToolID.tools(in: category).filter(\.isAvailable)) { tool in
            Button(tool.title) { app.open(tool) }
                .keyboardShortcut(tool.categories.first == category ? tool.shortcut : nil)
        }
        let upcoming = ToolID.tools(in: category).filter { !$0.isAvailable }
        if !upcoming.isEmpty {
            Divider()
            ForEach(upcoming) { tool in
                Button("\(tool.title) (coming soon)") {}
                    .disabled(true)
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("openWhenDone") private var openWhenDone = true
    @State private var hasSignature = SignatureStore.load() != nil

    var body: some View {
        Form {
            Toggle("Open results when finished", isOn: $openWhenDone)
            LabeledContent("Saved signature") {
                Button("Delete") {
                    SignatureStore.clear()
                    hasSignature = false
                }
                .disabled(!hasSignature)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .tint(Theme.accentBottom)
        .frame(width: 440)
        .padding(.vertical, 10)
        .background(Theme.background)
    }
}
