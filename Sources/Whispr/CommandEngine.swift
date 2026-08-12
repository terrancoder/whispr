import Foundation

/// Command mode (PLAN.md §4.8): a spoken instruction applied to selected
/// text ("make this concise", "translate to French") → replacement text; with
/// no selection, the instruction is answered inline. Unlike the cleanup
/// filter, this prompt IS an instruction-follower — but constrained to return
/// only the replacement/answer text.
enum CommandEngine {
    static let maxSelectionWords = 1000

    private static let rewritePrompt = """
    You are a precise text-editing engine. You receive a piece of SELECTED TEXT and a spoken INSTRUCTION. Apply the instruction to the selected text and return ONLY the resulting replacement text.

    Rules:
    - Return only the rewritten text — no preamble, no explanations, no quotes, no code fences, no labels.
    - Preserve the original meaning unless the instruction says otherwise.
    - Preserve the original language unless asked to translate.
    - Keep formatting (line breaks, list markers) unless the instruction changes it.
    - If the instruction is unclear, make the smallest reasonable interpretation.
    """

    private static let answerPrompt = """
    You answer a spoken question or request with plain text that will be typed directly at the user's cursor.

    Rules:
    - Return only the answer text — no preamble, no markdown headers, no quotes, no code fences unless code was requested.
    - Be concise: a short sentence or paragraph unless the request clearly needs more.
    """

    static func run(instruction: String, selection: String?) async throws -> String {
        let messages: [[String: String]]
        if let selection, !selection.isEmpty {
            messages = [
                ["role": "system", "content": rewritePrompt],
                [
                    "role": "user",
                    "content": "INSTRUCTION: \(instruction)\n\nSELECTED TEXT:\n\(selection)",
                ],
            ]
        } else {
            messages = [
                ["role": "system", "content": answerPrompt],
                ["role": "user", "content": instruction],
            ]
        }
        return try await LLMClient.chat(messages: messages, maxTokens: 2048, timeout: 20)
    }
}
