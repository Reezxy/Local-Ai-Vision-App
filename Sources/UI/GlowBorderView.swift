import SwiftUI

/// Apple-Intelligence-style glow hugging the screen edges: a wide, soft
/// blue → purple → pink gradient that slowly rotates and breathes. Always on.
///
/// Performance: two stroke layers instead of three, capped at 24 fps, and the
/// whole thing is rasterized in one Metal pass via `drawingGroup()` so the
/// blurs don't re-run on the CPU-side render tree every tick.
struct GlowBorderView: View {
    private let colors: [Color] = [
        .blue, .purple, .pink, .purple, .cyan, .blue,
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let rotation = Angle.degrees((t * 20).truncatingRemainder(dividingBy: 360))
            let breathe = 0.85 + 0.15 * sin(t * 1.4)

            let gradient = AngularGradient(
                colors: colors,
                center: .center,
                angle: rotation
            )

            GeometryReader { proxy in
                let shape = RoundedRectangle(
                    cornerRadius: cornerRadius(for: proxy.size),
                    style: .continuous
                )
                ZStack {
                    // Wide soft wash bleeding into the screen.
                    shape
                        .strokeBorder(gradient, lineWidth: 26)
                        .blur(radius: 22)
                        .opacity(0.65 * breathe)
                    // Bright core right at the edge.
                    shape
                        .strokeBorder(gradient, lineWidth: 5)
                        .blur(radius: 2)
                        .opacity(0.9)
                }
                .drawingGroup()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// Match the physical display corner radius closely enough.
    private func cornerRadius(for size: CGSize) -> CGFloat {
        min(size.width, size.height) > 500 ? 18 : 56
    }
}
