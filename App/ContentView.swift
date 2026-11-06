import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var editor: Editor
    @AppStorage("sideWidth") private var sideWidth = 360.0
    @State private var dragWidth: Double?
    @State private var dropping = false

    var body: some View {
        ZStack {
            Theme.paper.ignoresSafeArea()
            if editor.source == nil { startPage } else { editorPage.ignoresSafeArea(.container, edges: .top) }
            WindowChrome().frame(width: 0, height: 0)
            if dropping {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.ink, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(12).allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in editor.open(url) } }
            }
            return true
        }
    }

    private var startPage: some View {
        VStack(spacing: 0) {
            StartArt().frame(width: 44, height: 44).padding(.bottom, 18)
            Text("gif maker.").font(.system(size: 28, weight: .bold)).tracking(-0.7).foregroundStyle(Theme.ink)
            Text("drop a video, GIF or photo. crop, trim, tone, done.")
                .font(.body).foregroundStyle(.secondary).padding(.top, 4)
            Pill(title: "Open a file") { editor.openPanel() }.padding(.top, 22)
            if case .failed(let why) = editor.status {
                Text(why).font(.callout).foregroundStyle(Theme.warn).padding(.top, 14)
            }
            if case .working(let what, let f) = editor.status {
                Text(f.map { "\(what) \(Int($0 * 100))%" } ?? what).font(.callout).monospacedDigit().foregroundStyle(.secondary).padding(.top, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var editorPage: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        ForEach(ViewMode.allCases) { m in Chip(title: m.label, selected: editor.mode == m) { editor.mode = m } }
                        Spacer()
                        Text(editor.mode.hint).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Stage(editor: editor)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
                    TimelineBar(editor: editor)
                }
                .padding(.leading, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity)

                resizer
                SidePanel(editor: editor).frame(width: dragWidth ?? sideWidth)
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { editor.close() } label: {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(editor.isExporting).help("Close this file").accessibilityLabel("Close this file")
            Text(editor.baseName).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle).foregroundStyle(Theme.ink)
            statusView
            Spacer(minLength: 8)
            Picker("Format", selection: $editor.settings.format) {
                ForEach(ExportFormat.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize().disabled(editor.isExporting)
            if editor.isExporting {
                if case .working(_, let f?) = editor.status {
                    Pill(title: "Cancel · \(Int(f * 100))%") { editor.cancelExport() }
                } else {
                    Pill(title: "Cancel") { editor.cancelExport() }
                }
            } else {
                Pill(title: "Download \(editor.settings.format.action)") { editor.export() }
            }
        }
        .padding(.leading, 78).padding(.trailing, 10).frame(height: WindowChrome.barHeight)
        .overlay(alignment: .bottom) {
            if case .working(_, let f?) = editor.status {
                GeometryReader { g in Rectangle().fill(Theme.ink).frame(width: g.size.width * f, height: 2) }.frame(height: 2)
            } else { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    @ViewBuilder private var statusView: some View {
        switch editor.status {
        case .idle: EmptyView()
        case .working(let s, let f):
            Text(f.map { "\(s) \(Int($0 * 100))%" } ?? s).font(.caption).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        case .done(let s, let url):
            HStack(spacing: 6) {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Show in Finder") { editor.reveal(url.path) }.buttonStyle(.link).font(.caption)
            }
        case .failed(let s):
            Text(s).font(.caption).foregroundStyle(Theme.warn).lineLimit(2)
        }
    }

    /// Drag to make the side panel, and the preview in it, bigger. Double-click to reset.
    private var resizer: some View {
        Rectangle().fill(Color.clear).frame(width: 12).contentShape(Rectangle())
            .overlay(Capsule().fill(dragWidth == nil ? Theme.track : Theme.ink).frame(width: 3, height: 40))
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in dragWidth = max(280, min(900, sideWidth - g.translation.width)) }
                .onEnded { _ in if let w = dragWidth { sideWidth = w }; dragWidth = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { sideWidth = 360 })
            .accessibilityLabel("Resize the side panel")
    }
}

/// One compact row for the window buttons and the bar: the buttons move down to the bar's centre line.
/// AppKit lays them out again now and then, so this repeats on window updates; it changes nothing when they're in place.
struct WindowChrome: NSViewRepresentable {
    static let barHeight: CGFloat = 38

    func makeNSView(context: Context) -> Aligner { Aligner() }
    func updateNSView(_ view: Aligner, context: Context) { view.align() }

    final class Aligner: NSView {
        private var observer: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.align() }
            }
            align()
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

        func align() {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type), let bar = button.superview else { continue }
                // the distance from the window's top to the button's centre should be half the bar
                let shift = WindowChrome.barHeight / 2 - button.frame.height / 2
                let y = bar.isFlipped ? shift : bar.bounds.height - shift - button.frame.height
                if abs(button.frame.minY - y) > 0.5 { button.setFrameOrigin(NSPoint(x: button.frame.minX, y: y)) }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
