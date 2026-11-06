import AppKit
import CoreImage
import MetalKit
import SwiftUI

/// Where a picture of `content` aspect sits when fitted into `box`.
func fitted(_ content: CGSize, in box: CGSize) -> CGRect {
    guard content.width > 0, content.height > 0 else { return .zero }
    let s = min(box.width / content.width, box.height / content.height)
    let size = CGSize(width: content.width * s, height: content.height * s)
    return CGRect(x: (box.width - size.width) / 2, y: (box.height - size.height) / 2, width: size.width, height: size.height)
}

/// The picture, drawn on the GPU straight from Core Image: only when something changed, so an idle window costs nothing.
struct PictureView: NSViewRepresentable {
    let editor: Editor
    var mode: ViewMode?          // nil: follow the editor; the side panel's preview always shows the result
    var drivesClock = true

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor, mode: mode, drivesClock: drivesClock) }

    func makeNSView(context: Context) -> ScrollingMTKView {
        let view = ScrollingMTKView(frame: .zero, device: Renderer.shared.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = Renderer.shared.srgb
        view.preferredFramesPerSecond = 60
        view.layer?.isOpaque = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: ScrollingMTKView, context: Context) {
        context.coordinator.mode = mode
    }

    @MainActor final class Coordinator: NSObject, MTKViewDelegate {
        let editor: Editor
        var mode: ViewMode?
        let drivesClock: Bool
        private lazy var queue = Renderer.shared.device?.makeCommandQueue()
        private var drawn = -1
        private var drawnSize = CGSize.zero
        private var drawnScheme = false

        init(editor: Editor, mode: ViewMode?, drivesClock: Bool) {
            self.editor = editor; self.mode = mode; self.drivesClock = drivesClock
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { drawn = -1 }

        func draw(in view: MTKView) {
            if drivesClock { editor.tick() }
            let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let size = view.drawableSize
            guard editor.revision != drawn || size != drawnSize || dark != drawnScheme,
                  let image = editor.currentImage, size.width > 0, size.height > 0,
                  let drawable = view.currentDrawable, let queue, let buffer = queue.makeCommandBuffer() else { return }
            drawn = editor.revision; drawnSize = size; drawnScheme = dark
            let r = Renderer.shared
            let picture = compose(image, in: size)
            let ground = dark ? CIColor(red: 0.11, green: 0.11, blue: 0.11) : CIColor(red: 1, green: 1, blue: 1)
            let final = picture.composited(over: CIImage(color: ground).cropped(to: CGRect(origin: .zero, size: size)))
            r.context.render(final, to: drawable.texture, commandBuffer: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: r.srgb)
            buffer.present(drawable)
            buffer.commit()
        }

        private func compose(_ image: CIImage, in size: CGSize) -> CIImage {
            let r = Renderer.shared, m = mode ?? editor.mode
            let crop = editor.crop
            if m == .crop {
                let box = fitted(image.extent.size, in: size)
                let k = box.width / image.extent.width
                let origin = image.extent.origin
                let whole = image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y)
                    .concatenating(CGAffineTransform(scaleX: k, y: k)), highQualityDownsample: true)
                let dim = whole.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.38, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.38, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 0.38, w: 0),
                ])
                let rect = CGRect(x: crop.minX * k, y: box.height - crop.maxY * k, width: crop.width * k, height: crop.height * k)
                return whole.cropped(to: rect).composited(over: dim).transformed(by: CGAffineTransform(translationX: box.minX, y: box.minY))
            }
            let box = fitted(crop.size, in: size)
            let before = r.scaled(r.cropped(image, crop: crop), to: box.size.rounded, highQuality: false)
            let after = r.colored(before, editor.adjustments, seed: editor.revision)
            let move = CGAffineTransform(translationX: box.minX.rounded(), y: box.minY.rounded())
            if m == .result { return after.cropped(to: before.extent).transformed(by: move) }
            let cut = before.extent.width * editor.split
            let right = after.cropped(to: CGRect(x: cut, y: 0, width: before.extent.width - cut, height: before.extent.height))
            return right.composited(over: before).transformed(by: move)
        }
    }
}

private extension CGSize {
    var rounded: CGSize { CGSize(width: width.rounded(), height: height.rounded()) }
}

final class ScrollingMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // SwiftUI's overlays handle the mouse
}

/// The big picture with what goes on top of it: the crop frame, or the before / after line.
struct Stage: View {
    @Bindable var editor: Editor
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let mode = editor.mode
            let box = fitted(mode == .crop ? (editor.source?.size ?? .zero) : editor.crop.size, in: geo.size)
            ZStack(alignment: .topLeading) {
                PictureView(editor: editor)
                if mode == .crop, let source = editor.source {
                    let k = box.width / source.size.width
                    Rectangle().strokeBorder(.white, lineWidth: 1.5)
                        .frame(width: editor.crop.width * k, height: editor.crop.height * k)
                        .offset(x: box.minX + editor.crop.minX * k, y: box.minY + editor.crop.minY * k)
                        .allowsHitTesting(false)
                }
                if mode == .compare {
                    let x = box.minX + box.width * editor.split
                    Rectangle().fill(.white).frame(width: 2, height: box.height).offset(x: x - 1, y: box.minY).allowsHitTesting(false)
                    Circle().fill(.white).frame(width: 30, height: 30)
                        .overlay(Image(systemName: "chevron.left.chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.black))
                        .offset(x: x - 15, y: box.midY - 15).allowsHitTesting(false)
                    tag("Before").offset(x: box.minX + 10, y: box.minY + 10)
                    GeometryReader { _ in tag("After") }.frame(width: 60, height: 22).offset(x: box.maxX - 62, y: box.minY + 10)
                }
                Color.clear.contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in drag(g, box: box) }.onEnded { _ in dragStart = nil })
            }
            .overlay(ScrollCatcher { dy in editor.setZoom(max(0.2, min(1, editor.zoom - Double(dy) * 0.01))) })
        }
    }

    private func tag(_ s: String) -> some View {
        Text(s).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule()).allowsHitTesting(false)
    }

    private func drag(_ g: DragGesture.Value, box: CGRect) {
        guard let source = editor.source, box.width > 0 else { return }
        switch editor.mode {
        case .compare:
            editor.split = Double(max(0, min(1, (g.location.x - box.minX) / box.width)))
        case .crop:
            if dragStart == nil { dragStart = editor.crop.origin }
            let k = source.size.width / box.width
            editor.moveCrop(to: CGPoint(x: dragStart!.x + g.translation.width * k, y: dragStart!.y + g.translation.height * k))
        case .result:
            // the picture follows the pointer, so the crop moves the other way
            if dragStart == nil { dragStart = editor.crop.origin }
            let k = editor.crop.width / box.width
            editor.moveCrop(to: CGPoint(x: dragStart!.x - g.translation.width * k, y: dragStart!.y - g.translation.height * k))
        }
    }
}

/// Passes scroll-wheel events to a closure and lets everything else through.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> CatcherView { let v = CatcherView(); v.onScroll = onScroll; return v }
    func updateNSView(_ v: CatcherView, context: Context) { v.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return event }
                self.onScroll?(event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.5 : 3))
                return nil
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
