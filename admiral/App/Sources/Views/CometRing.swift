import SwiftUI

/// A thin comet that walks clockwise around a session's avatar while it's actively working
/// (`.busy`). The rounded square stays static (axis-aligned, corners aligned with the avatar);
/// a comet with a bright cyan head and a smoothly fading blue tail travels its border and
/// wraps seamlessly each loop.
///
/// The fade is built from many stroked layers that share one animated dash-phase, so they move
/// in lockstep as a single comet. Every layer's "on" segment starts at the same point and runs
/// a different length: the long faint layers form the tail, the short bright ones the head.
/// Keeping the shared edge at the *start* (not the far end) keeps the bright head on the
/// cleanly-wrapping edge, so the tail never tears at the seam. To travel clockwise we simply
/// mirror the view horizontally — the square is symmetric, so the flip is invisible except that
/// the natural counter-clockwise motion becomes clockwise, with the head still leading.
/// Decorative — never intercepts taps, mounted only while busy.
struct CometRing: View {
    var size: CGFloat
    var lineWidth: CGFloat = 1.5
    @State private var phase: CGFloat = 0

    private static let layers = 14

    var body: some View {
        let radius = size * 0.28
        let perimeter = 4 * (size - 2 * radius) + 2 * .pi * radius
        let tailLength = perimeter * 0.32   // full comet length (faint tail → bright head)
        let headLength = perimeter * 0.04   // the bright tip

        ZStack {
            // Longest + faintest first (drawn under), shortest + brightest last (on top). Their
            // transparencies composite into a smooth bright-head-to-faint-tail gradient.
            ForEach(0..<Self.layers, id: \.self) { i in
                let t = CGFloat(i) / CGFloat(Self.layers - 1)   // 0 = tail end, 1 = head
                let length = tailLength + (headLength - tailLength) * t
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        Self.cometColor(t).opacity(0.05 + 0.95 * t * t),  // eased fade
                        style: StrokeStyle(
                            lineWidth: lineWidth, lineCap: .round,
                            dash: [length, perimeter - length], dashPhase: phase
                        )
                    )
            }
        }
        .shadow(color: Self.cometColor(1).opacity(0.5), radius: 2.5)
        .frame(width: size, height: size)
        .scaleEffect(x: -1, y: 1)   // mirror: counter-clockwise → clockwise (square is symmetric)
        .onAppear {
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                phase = perimeter   // one full loop, forever
            }
        }
        .allowsHitTesting(false)
    }

    /// Tail (blue) → head (bright cyan tipping toward white).
    private static func cometColor(_ t: CGFloat) -> Color {
        Color(red: 0.20 + (0.55 - 0.20) * t,
              green: 0.45 + (0.95 - 0.45) * t,
              blue: 1.0)
    }
}
