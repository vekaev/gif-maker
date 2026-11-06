import AppKit
import SwiftUI

/// The owner's look: paper and ink, heavy lowercase headlines, black pills, cards with hairlines.
/// Colour belongs to the picture, and to the one thing borrowed from QuickTime: the yellow trim frame.
enum Theme {
    static let paper = Color(nsColor: NSColor(name: nil) { $0.isDark ? .black : NSColor(red: 0.965, green: 0.961, blue: 0.949, alpha: 1) })
    static let card = Color(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(white: 0.11, alpha: 1) : .white })
    static let ink = Color(nsColor: NSColor(name: nil) { $0.isDark ? .white : .black })
    static let line = Color(nsColor: NSColor(name: nil) { ($0.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.09) })
    static let track = Color(nsColor: NSColor(name: nil) { ($0.isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.14) })
    static let trim = Color(red: 0.96, green: 0.77, blue: 0.09)
    static let warn = Color(red: 0.84, green: 0.23, blue: 0.25)
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// Light / dark / follow the system, chosen in Settings.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "appearance"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? { self == .system ? nil : (self == .light ? .light : .dark) }
}

struct InkPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// The one primary action: a black pill (white in dark mode).
struct Pill: View {
    let title: String
    var enabled = true
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(scheme == .dark ? Color.black : Color.white)
                .padding(.horizontal, 18).frame(height: 30)
                .background(Theme.ink, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(InkPress())
        .opacity(enabled ? 1 : 0.4)
        .disabled(!enabled)
    }
}

/// A small choice: outlined, or filled when it's the current one.
struct Chip: View {
    let title: String
    var selected = false
    var wide = false
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(selected ? (scheme == .dark ? Color.black : Color.white) : Theme.ink)
                .padding(.horizontal, 10).frame(height: 26)
                .frame(maxWidth: wide ? .infinity : nil)
                .background(selected ? Theme.ink : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : Theme.track))
                .contentShape(Capsule())
        }
        .buttonStyle(InkPress())
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink.opacity(0.45))
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line))
        }
    }
}

/// A slider that fills from zero to the thumb, so a two-way setting reads as two-way. It snaps to its default when
/// dragged close, and a reset arrow appears once it's been changed (double-clicking also resets it).
struct InkSlider: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var zero = 0.0
    var reset: Double? = 0
    var text: (Double) -> String = { v in
        let r = Int(v.rounded())
        return r > 0 ? "+\(r)" : "\(r)"
    }

    private var isEdited: Bool { reset.map { abs(value - $0) > 1e-6 } ?? false }

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 84, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                let at = { (v: Double) in CGFloat((v - range.lowerBound) / (range.upperBound - range.lowerBound)) * (w - 14) + 7 }
                let x = at(value), z = at(min(range.upperBound, max(range.lowerBound, zero)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track).frame(height: 3)
                    Capsule().fill(Theme.ink).frame(width: abs(x - z), height: 3).offset(x: min(x, z))
                    Circle().fill(Theme.card)
                        .overlay(Circle().strokeBorder(Theme.ink, lineWidth: 1.5))
                        .frame(width: 14, height: 14).offset(x: x - 7)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let f = Double(min(1, max(0, (g.location.x - 7) / (w - 14))))
                    let span = range.upperBound - range.lowerBound, next = range.lowerBound + f * span
                    if let reset, abs(next - reset) < span * 0.01 { value = reset } else { value = next }
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded { if let reset { value = reset } })
            }
            .frame(height: 18)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(text(value))
            .accessibilityAdjustableAction { d in
                let step = (range.upperBound - range.lowerBound) / 20
                value = min(range.upperBound, max(range.lowerBound, value + (d == .increment ? step : -step)))
            }
            Text(text(value)).font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            // always takes up its place, so the slider doesn't change width when it appears
            Button { if let reset { value = reset } } label: {
                Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.6))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(InkPress())
            .opacity(isEdited ? 1 : 0)
            .disabled(!isEdited)
            .accessibilityHidden(!isEdited)
            .help("Reset \(label)")
            .accessibilityLabel("Reset \(label)")
        }
    }
}

/// The app's mark: a crop frame around a play triangle. One ink colour, so it works on any paper.
struct StartArt: View {
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width, size.height) / 56
            ctx.translateBy(x: (size.width - 56 * s) / 2, y: (size.height - 56 * s) / 2)
            ctx.scaleBy(x: s, y: s)
            var corners = Path()
            for (x, y, dx, dy) in [(4.0, 4.0, 1.0, 1.0), (52, 4, -1, 1), (52, 52, -1, -1), (4, 52, 1, -1)] {
                corners.move(to: CGPoint(x: x, y: y + 13 * dy))
                corners.addLine(to: CGPoint(x: x, y: y))
                corners.addLine(to: CGPoint(x: x + 13 * dx, y: y))
            }
            ctx.stroke(corners, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            var play = Path()
            play.move(to: CGPoint(x: 22, y: 18)); play.addLine(to: CGPoint(x: 40, y: 28)); play.addLine(to: CGPoint(x: 22, y: 38)); play.closeSubpath()
            ctx.fill(play, with: .color(Theme.ink))
            ctx.stroke(play, with: .color(Theme.ink), style: StrokeStyle(lineWidth: 3, lineJoin: .round))
        }
    }
}
