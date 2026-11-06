import AppKit
import SwiftUI

@main
struct GIFMakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system
    @State private var editor = Editor()

    init() { _ = Updater.shared }

    var body: some Scene {
        Window("GIF Maker", id: "main") {
            ContentView(editor: editor)
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { delegate.attach(editor) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { editor.openPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button(editor.isExporting ? "Cancel Download" : "Download \(editor.settings.format.action)") {
                    editor.isExporting ? editor.cancelExport() : editor.export()
                }
                .keyboardShortcut("s").disabled(editor.source == nil)
            }
            CommandMenu("Playback") {
                Button(editor.isPlaying ? "Pause" : "Play") { editor.togglePlay() }.disabled(editor.source == nil)
                Divider()
                Button("Start Here") { editor.startHere() }.keyboardShortcut("i", modifiers: []).disabled(editor.source == nil)
                Button("End Here") { editor.endHere() }.keyboardShortcut("o", modifiers: []).disabled(editor.source == nil)
            }
        }

        Settings { SettingsView(editor: editor) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var editor: Editor?
    private var pending: [URL] = []
    private var monitor: Any?

    @MainActor func attach(_ editor: Editor) {
        self.editor = editor
        if let url = pending.first { editor.open(url); pending = [] }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Space plays and pauses, unless a text field or a menu wants it
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  !(NSApp.keyWindow?.firstResponder is NSTextView) else { return event }
            guard let editor = MainActor.assumeIsolated({ self?.editor }), MainActor.assumeIsolated({ editor.source != nil }) else { return event }
            MainActor.assumeIsolated { editor.togglePlay() }
            return nil
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        let editor = MainActor.assumeIsolated { self.editor }
        if let editor { MainActor.assumeIsolated { editor.open(url) } } else { pending = [url] }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct SettingsView: View {
    let editor: Editor
    @AppStorage(AppAppearance.key) private var appearance: AppAppearance = .system
    @AppStorage("saveFolder") private var saveFolder = ""

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
            }
            LabeledContent("Save downloads to") {
                HStack {
                    Text(editor.saveFolder.lastPathComponent).lineLimit(1)
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
                        panel.directoryURL = editor.saveFolder
                        if panel.runModal() == .OK, let url = panel.url { saveFolder = url.path }
                    }
                }
            }
            UpdatePreferences()
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
