import Foundation

/// A single turn in the conversation. Text is what the user asked (typed or
/// transcribed) and the vision model's spoken answer.
struct Interaction: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant }

    let id = UUID()
    let role: Role
    var text: String
    let createdAt: Date = .now
}

/// High-level state machine that the UI observes. The whole app is essentially
/// a loop through these phases: listen -> capture -> think -> speak.
enum PipelinePhase: Equatable, Sendable {
    case idle
    case listening          // recording / awaiting user question
    case transcribing       // Whisper turning audio into text
    case capturingFrame     // grabbing the current camera frame
    case thinking           // Qwen3-VL reasoning over frame + question
    case speaking           // Kokoro reading the answer aloud
    case error(String)
}
