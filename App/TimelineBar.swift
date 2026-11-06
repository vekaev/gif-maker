import SwiftUI

/// The QuickTime-style trimmer: a filmstrip, a yellow frame with handles, a bar on top to slide the whole clip,
/// the fast parts as bands, and in red what a sticker can't fit.
struct TimelineBar: View {
    @Bindable var editor: Editor
    @State private var slideFrom: Clip?
    @State private var scrubbing = false
    private let handle: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Button { editor.togglePlay() } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36)
                        .background(Theme.card, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.track))
                        .contentShape(Circle())
                }
                .buttonStyle(InkPress())
                .accessibilityLabel(editor.isPlaying ? "Pause" : "Play")
                GeometryReader { geo in track(width: geo.size.width) }
                    .frame(height: 44)
                    .padding(.horizontal, handle)
                    .padding(.top, 12)
            }
            HStack {
                PlayheadTime(editor: editor)
                Spacer()
                Text(clipText).monospacedDigit()
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.leading, 46 + handle).padding(.trailing, handle)
        }
    }

    private var clipText: String {
        let c = editor.clip, length = c.playLength
        let changed = abs(length - (c.end - c.start)) > 0.05
        return "\(secondsText(c.start)) – \(secondsText(c.end)) · " + (changed ? "plays \(secondsText(length))" : secondsText(length))
    }

    @ViewBuilder private func track(width w: CGFloat) -> some View {
        let d = max(editor.duration, 0.001), c = editor.clip
        let x = { (t: Double) in CGFloat(t / d) * w }
        ZStack(alignment: .topLeading) {
            Filmstrip(editor: editor, width: w)
            Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, x(c.start))).allowsHitTesting(false)
            Rectangle().fill(.black.opacity(0.6)).frame(width: max(0, w - x(c.end))).offset(x: x(c.end)).allowsHitTesting(false)
            if let cut = editor.stickerCut {
                Hatch().frame(width: max(0, x(c.end) - x(cut))).offset(x: x(cut)).allowsHitTesting(false)
            }
            // the seek surface, below the parts and handles
            Color.clear.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !scrubbing { scrubbing = true; editor.beginScrub() }
                        editor.scrub(to: Double(g.location.x / w) * d)
                    }
                    .onEnded { _ in scrubbing = false; editor.endScrub(rewind: false) })
            ForEach(c.parts) { part in
                Text(speedText(part.speed))
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    .frame(width: max(2, x(part.to) - x(part.from)), height: 15)
                    .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white, lineWidth: part.id == editor.selectedPart ? 1.5 : 0))
                    .offset(x: x(part.from), y: 29)
                    .onTapGesture { editor.selectedPart = part.id }
                    .accessibilityLabel("Fast part, \(speedText(part.speed))")
            }
            // the yellow frame
            Rectangle().fill(Theme.trim).frame(width: max(0, x(c.end) - x(c.start)), height: 3).offset(x: x(c.start), y: -3).allowsHitTesting(false)
            Rectangle().fill(Theme.trim).frame(width: max(0, x(c.end) - x(c.start)), height: 3).offset(x: x(c.start), y: 44).allowsHitTesting(false)
            trimHandle(left: true).offset(x: x(c.start) - handle, y: -3)
                .gesture(handleDrag(width: w, left: true))
            trimHandle(left: false).offset(x: x(c.end), y: -3)
                .gesture(handleDrag(width: w, left: false))
            UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4)
                .fill(Theme.trim).frame(width: max(0, x(c.end) - x(c.start)), height: 10)
                .offset(x: x(c.start), y: -13)
                .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { g in
                        if slideFrom == nil { slideFrom = c; editor.beginScrub() }
                        editor.slide(from: slideFrom!, by: Double(g.translation.width / w) * d)
                    }
                    .onEnded { _ in slideFrom = nil; editor.endScrub(rewind: false) })
                .accessibilityLabel("Move the whole clip")
            Playhead(editor: editor, width: w)
        }
        .frame(width: w, height: 44, alignment: .topLeading)
        .coordinateSpace(.named("track"))
    }

    private func trimHandle(left: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: left ? 6 : 0, bottomLeadingRadius: left ? 6 : 0, bottomTrailingRadius: left ? 0 : 6, topTrailingRadius: left ? 0 : 6)
            .fill(Theme.trim)
            .frame(width: handle, height: 50)
            .overlay(RoundedRectangle(cornerRadius: 1).fill(.black.opacity(0.45)).frame(width: 2.5, height: 16))
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .accessibilityLabel(left ? "Start of the clip" : "End of the clip")
    }

    private func handleDrag(width w: CGFloat, left: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("track"))
            .onChanged { g in
                if !scrubbing { scrubbing = true; editor.beginScrub() }
                let t = Double(g.location.x / w) * editor.duration
                if left { editor.trim(start: t) } else { editor.trim(end: t) }
            }
            .onEnded { _ in scrubbing = false; editor.endScrub(rewind: !left) }
    }
}

/// Only these small views read the playhead, so its movement doesn't redraw anything else.
private struct Playhead: View {
    let editor: Editor
    let width: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: 1).fill(.white)
            .shadow(color: .black.opacity(0.4), radius: 1)
            .frame(width: 2, height: 56)
            .offset(x: CGFloat(editor.time / max(editor.duration, 0.001)) * width - 1, y: -6)
            .allowsHitTesting(false)
    }
}

private struct PlayheadTime: View {
    let editor: Editor
    var body: some View { Text(secondsText(editor.time)).monospacedDigit() }
}

private struct Filmstrip: View {
    let editor: Editor
    let width: CGFloat
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(editor.thumbnails.enumerated()), id: \.offset) { _, image in
                ZStack {
                    Color.black
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
                }
                .frame(width: width / CGFloat(max(editor.thumbnails.count, 1)), height: 44)
                .clipped()
            }
        }
        .frame(width: width, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .allowsHitTesting(false)
    }
}

private struct Hatch: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.warn.opacity(0.3)))
            var p = Path(), x = -size.height
            while x < size.width {
                p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 9
            }
            ctx.stroke(p, with: .color(Theme.warn.opacity(0.7)), lineWidth: 3)
        }
    }
}
