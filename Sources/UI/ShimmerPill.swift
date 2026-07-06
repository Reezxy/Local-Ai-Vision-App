import SwiftUI

/// Status pill in the Apple-Intelligence style: dark capsule, dim gray text,
/// and a soft white highlight that sweeps across the letters. Used for
/// "Loading model…" and "Thinking…".
struct ShimmerPill: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // 0 → 1 sweep, repeating every 2 seconds with a small rest.
            let phase = (t.truncatingRemainder(dividingBy: 2.0)) / 2.0

            label
                .foregroundStyle(.white.opacity(0.35))
                .overlay(
                    label
                        .foregroundStyle(.white)
                        .mask(
                            GeometryReader { proxy in
                                let width = proxy.size.width
                                LinearGradient(
                                    stops: [
                                        .init(color: .clear, location: 0.0),
                                        .init(color: .white, location: 0.5),
                                        .init(color: .clear, location: 1.0),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: width * 0.55)
                                // Travel from fully off-screen left to right.
                                .offset(x: -width * 0.55 + (width * 1.55) * phase)
                            }
                        )
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 13)
                .background(Capsule().fill(.black.opacity(0.55)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 18, weight: .medium))
    }
}
