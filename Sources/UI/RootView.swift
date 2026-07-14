import SwiftUI

extension View {
    /// Small round glass background. Uses Liquid Glass on iOS 26+, falling back
    /// to a material on earlier systems.
    @ViewBuilder
    func glassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .circle)
        } else {
            self.background(.ultraThinMaterial.opacity(0.7), in: Circle())
        }
    }

    /// Capsule glass background with high transparency (input bar).
    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            self.background(.ultraThinMaterial.opacity(0.55), in: Capsule())
        }
    }
}

/// The whole app is one page: a full-screen live camera with the holographic
/// object effect, an Apple-Intelligence-style edge glow while the assistant is
/// active, and the conversation rendered directly on the image.
struct RootView: View {
    let environment: AppEnvironment
    private var pipeline: VisionPipeline { environment.pipeline }

    @State private var questionText = ""
    @State private var showModels = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            // Full-screen live camera.
            if environment.camera.authorized {
                CameraPreviewView(session: environment.camera.session)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                    .overlay(Text("Camera access needed").foregroundStyle(.white))
            }

            // Conversation directly on the camera image (screenshot style).
            ConversationOverlay(pipeline: pipeline)

            // Bottom controls.
            VStack {
                Spacer()

                if pipeline.phase == .listening {
                    ListeningIndicator(level: pipeline.micLevel)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                } else if pipeline.phase == .transcribing {
                    ShimmerPill(text: "Transcribing…")
                        .padding(.bottom, 8)
                        .transition(.opacity)
                } else if pipeline.isModelLoading {
                    ShimmerPill(text: "Loading model…")
                        .padding(.bottom, 8)
                        .transition(.opacity)
                } else if pipeline.phase == .thinking || pipeline.phase == .capturingFrame {
                    ShimmerPill(text: "Thinking…")
                        .padding(.bottom, 8)
                        .transition(.opacity)
                } else if let error = pipeline.modelLoadError {
                    ModelErrorBadge(message: error) { pipeline.retryModelLoad() }
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }

                if case .error(let message) = pipeline.phase {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 4)
                }

                InputBar(
                    text: $questionText,
                    focused: $inputFocused,
                    onSend: {
                        pipeline.submit(text: questionText)
                        questionText = ""
                        inputFocused = false
                    },
                    onMicDown: { pipeline.startVoiceInput() },
                    onMicUp: { pipeline.finishVoiceInput() },
                    isListening: pipeline.phase == .listening,
                    micLevel: pipeline.micLevel
                )
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            // Apple-Intelligence edge glow, always on.
            GlowBorderView()
        }
        .animation(.easeInOut(duration: 0.25), value: pipeline.phase)
        .overlay(alignment: .top) {
            Text("made by Reezxy")
                .font(.system(size: 12, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.35))
                .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                .padding(.top, 12)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topLeading) {
            Button { showModels = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .glassCircle()
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }
        .sheet(isPresented: $showModels) {
            ModelManagementView(models: environment.models)
        }
        .task {
            await environment.camera.requestAccess()
            environment.camera.configureAndStart()
            pipeline.warmUp()
        }
    }
}

// MARK: - Conversation overlay (screenshot style)

/// The user's question big at the top, an "INTELLIGENCE" caps label, and the
/// streaming answer below — all in SF Pro directly over the camera image,
/// auto-cleared by the pipeline a few seconds after speech ends.
private struct ConversationOverlay: View {
    let pipeline: VisionPipeline

    private var answerText: String? {
        if !pipeline.partialAnswer.isEmpty { return pipeline.partialAnswer }
        return pipeline.visibleAnswer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let question = pipeline.visibleQuestion {
                Text(question)
                    .font(.system(.title, design: .default, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)

                if answerText != nil || pipeline.phase == .thinking {
                    Text("INTELLIGENCE")
                        .font(.system(size: 12, weight: .semibold))
                        .tracking(3)
                        .foregroundStyle(.white.opacity(0.55))
                        .transition(.opacity)
                }

                if let answer = answerText {
                    Text(answer)
                        .font(.system(.title2, design: .default, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }
            }
            Spacer()
        }
        .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
        .padding(.horizontal, 24)
        .padding(.top, 68)
        .animation(.easeInOut(duration: 0.35), value: pipeline.visibleQuestion)
        .animation(.easeInOut(duration: 0.2), value: answerText)
        .allowsHitTesting(false)
    }
}

/// Shown when the vision model fails to load, with the reason and a retry.
private struct ModelErrorBadge: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Label("Vision model failed to load", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}

// MARK: - Listening indicator

/// "Listening…" with live level bars. The bars are driven by the actual
/// microphone level, so they are also the answer to "is it even recording?" —
/// if they move, the mic is live.
private struct ListeningIndicator: View {
    let level: Double

    private static let barCount = 5
    /// Each bar reacts to a slightly different slice of the level, so the group
    /// ripples rather than moving as one block.
    private static let weights: [Double] = [0.55, 0.85, 1.0, 0.8, 0.5]

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            // Recording dot.
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .scaleEffect(pulse ? 1.35 : 0.85)
                .opacity(pulse ? 1 : 0.5)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)

            HStack(spacing: 3) {
                ForEach(0 ..< Self.barCount, id: \.self) { index in
                    Capsule()
                        .fill(.white)
                        .frame(width: 3, height: barHeight(index))
                        .animation(.easeOut(duration: 0.12), value: level)
                }
            }
            .frame(height: 22)

            Text("Listening…")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        .onAppear { pulse = true }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let minimum: Double = 4
        let maximum: Double = 22
        let scaled = minimum + (maximum - minimum) * level * Self.weights[index]
        return CGFloat(min(max(scaled, minimum), maximum))
    }
}

// MARK: - Input bar

private struct InputBar: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onMicDown: () -> Void
    let onMicUp: () -> Void
    let isListening: Bool
    let micLevel: Double

    var body: some View {
        HStack(spacing: 12) {
            TextField("Ask about what you see…", text: $text)
                .focused(focused)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .foregroundStyle(.white)
                .tint(.white)
                .glassCapsule()
                .submitLabel(.send)
                .onSubmit(onSend)

            if text.isEmpty {
                // Push-to-talk mic. While recording it turns red and grows a ring
                // that rides the input level, so holding the button visibly does
                // something the moment you press it.
                Image(systemName: "mic.fill")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background {
                        if isListening {
                            Circle().fill(.red.opacity(0.85))
                        }
                    }
                    .glassCircle()
                    .overlay {
                        if isListening {
                            Circle()
                                .stroke(.red.opacity(0.6), lineWidth: 2)
                                .scaleEffect(1 + 0.35 * micLevel)
                                .opacity(1 - 0.5 * micLevel)
                                .animation(.easeOut(duration: 0.12), value: micLevel)
                        }
                    }
                    .scaleEffect(isListening ? 1.08 : 1)
                    .animation(.spring(duration: 0.25), value: isListening)
                    // Without this the touch target is the mic glyph itself, not
                    // the button — a press slightly off the icon hits nothing and
                    // the app looks dead.
                    .contentShape(Circle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { _ in onMicDown() }
                            .onEnded { _ in onMicUp() }
                    )
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .glassCircle()
                }
            }
        }
    }
}
