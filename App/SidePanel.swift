import SwiftUI

struct SidePanel: View {
    @Bindable var editor: Editor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if editor.mode == .crop {
                    Card(title: "Preview") {
                        PictureView(editor: editor, mode: .result, drivesClock: false)
                            .aspectRatio(max(editor.crop.width, 1) / max(editor.crop.height, 1), contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(maxWidth: .infinity)
                    }
                }
                lookCard
                cropCard
                trimCard
                speedCard
                lightCard
                exportCard
                if !editor.recent.isEmpty { recentCard }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private var lookCard: some View {
        Card(title: "Look") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(Look.allCases) { look in
                    Chip(title: look.name, selected: editor.adjustments.look == look, wide: true) { editor.adjustments.look = look }
                }
            }
            InkSlider(label: "Grain", value: $editor.adjustments.grain, range: 0...30)
            Text(editor.settings.format == .gif ? "Grain barely compresses in a GIF: even a little makes the file much bigger." : "Film grain, added to the finished picture.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var cropCard: some View {
        Card(title: "Crop") {
            HStack(spacing: 6) {
                ForEach(Aspect.allCases) { a in Chip(title: a.rawValue, selected: editor.aspect == a) { editor.setAspect(a) } }
            }
            InkSlider(label: "Zoom", value: Binding(get: { editor.zoom * 100 }, set: { editor.setZoom($0 / 100) }), range: 20...100, zero: 20, reset: 100) { "\(Int($0.rounded()))%" }
            HStack(spacing: 6) {
                Chip(title: "← Left edge") { editor.snap(.left) }
                Chip(title: "Center") { editor.snap(.center) }
                Chip(title: "Right edge →") { editor.snap(.right) }
            }
        }
    }

    private var trimCard: some View {
        Card(title: "Trim") {
            Text("Drag the yellow handles under the picture, or set the ends where the playhead is.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Chip(title: "Start here") { editor.startHere() }
                Chip(title: "End here") { editor.endHere() }
            }
        }
    }

    private var speedCard: some View {
        Card(title: "Speed") {
            InkSlider(label: "Whole clip", value: Binding(get: { log2(editor.clip.speed) * 100 }, set: { editor.clip.speed = pow(2, $0 / 100) }), range: -400...400) { speedText(pow(2, $0 / 100)) }
            HStack(spacing: 6) {
                Chip(title: "＋ Speed up a part") { editor.addPart() }
                if editor.settings.format == .sticker { Chip(title: "Fit into 3 s") { editor.fitIntoStickerLength() } }
            }
            if let id = editor.selectedPart, let part = editor.clip.parts.first(where: { $0.id == id }) {
                InkSlider(label: "This part", value: Binding(get: { log2(part.speed) * 100 }, set: { editor.setSelectedPartSpeed(pow(2, $0 / 100)) }), range: -300...300, reset: 100) { speedText(pow(2, $0 / 100)) }
                HStack(spacing: 6) {
                    Chip(title: "Starts here") { editor.moveSelectedPart(from: true) }
                    Chip(title: "Ends here") { editor.moveSelectedPart(from: false) }
                    Chip(title: "Delete") { editor.deleteSelectedPart() }
                }
                Text("\(secondsText(part.from)) – \(secondsText(part.to)): plays at \(speedText(editor.clip.speed * part.speed))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Fast parts are the dark bands on the timeline. Click one to change it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lightCard: some View {
        Card(title: "Light and colour") {
            InkSlider(label: "Exposure", value: $editor.adjustments.exposure, range: -150...150)
            InkSlider(label: "Shadows", value: $editor.adjustments.shadows, range: -100...100)
            InkSlider(label: "Contrast", value: $editor.adjustments.contrast, range: -100...100)
            InkSlider(label: "Saturation", value: $editor.adjustments.saturation, range: -100...100)
            InkSlider(label: "Warmth", value: $editor.adjustments.warmth, range: -50...50)
            HStack(spacing: 6) {
                Chip(title: "Auto") { editor.autoLight() }
                Chip(title: "Reset") { editor.resetColor() }
            }
        }
    }

    private var hint: String {
        switch editor.settings.format {
        case .gif: "Plays everywhere. Up to 256 colours, so files are big."
        case .mp4: "Full colour, small file, plays everywhere. With the silent sound track Telegram sends it as a video; without it, as a GIF."
        case .webm: "Full colour, small file, VP9, no sound. Good for the web and Discord."
        case .sticker: "Telegram video sticker: VP9, 512 px, up to 3 s and 256 KB, no sound. Then send the file to @Stickers with /newvideo."
        }
    }

    private var exportCard: some View {
        Card(title: "Export settings") {
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if editor.settings.format != .sticker {
                InkSlider(label: "Width", value: Binding(get: { Double(editor.settings.width) }, set: { editor.settings.width = Int(($0 / 20).rounded()) * 20 }), range: 240...1920, zero: 240, reset: 600) { "\(Int($0)) px" }
            }
            InkSlider(label: "Frame rate", value: Binding(get: { Double(editor.settings.fps) }, set: { editor.settings.fps = Int($0.rounded()) }), range: 6...60, zero: 6, reset: 15) { "\(Int($0)) fps" }
            if editor.settings.format == .mp4 {
                Toggle("Add a silent sound track", isOn: $editor.settings.silentTrack).toggleStyle(.switch).tint(Theme.ink).font(.callout)
            }
            if editor.settings.format == .gif {
                Toggle("Smooth gradients (dithering)", isOn: $editor.settings.dither).toggleStyle(.switch).tint(Theme.ink).font(.callout)
            }
            if let p = editor.plan {
                Text("\(p.size.width)×\(p.size.height) px · \(secondsText(p.length)) · \(p.fps) fps · \(p.frames) frames")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                if editor.isStickerTooLong {
                    Text("The clip plays \(secondsText(p.total)), but Telegram stickers stop at 3 s: the red part is left out. Trim it, or press “Fit into 3 s”.")
                        .font(.caption).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                }
                if editor.settings.format == .gif, editor.settings.fps > 50 {
                    Text("GIF tops out at 50 fps.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var recentCard: some View {
        Card(title: "Recent downloads") {
            ForEach(editor.recent) { item in
                HStack(spacing: 10) {
                    Group {
                        if let data = item.poster, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFill() }
                        else { Color.black }
                    }
                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.caption).lineLimit(1).truncationMode(.middle)
                        Text(sizeText(item.bytes)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button { editor.reveal(item.path) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).help("Show in Finder").accessibilityLabel("Show in Finder")
                    Button { editor.removeRecent(item) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("Remove from this list").accessibilityLabel("Remove from this list")
                }
            }
        }
    }
}
