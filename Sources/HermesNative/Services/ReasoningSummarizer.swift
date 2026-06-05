import Foundation
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "ReasoningSummarizer")

// MARK: - Summarization Result

struct ReasoningDecision: Codable, Sendable {
    let id: String
    let label: String
    let reasoning: String
    let options: [String]
}

struct ReasoningSummary: Codable, Sendable {
    let decisions: [ReasoningDecision]
    let summary: String?
}

// MARK: - Reasoning Summarizer Protocol

protocol ReasoningSummarizing: AnyObject {
    @MainActor var isReady: Bool { get }
    @MainActor func feed(delta: String)
    @MainActor func summarize() async -> ReasoningSummary?
    @MainActor func reset()
}

// MARK: - Heuristic Summarizer (Pattern-Based)

final class HeuristicReasoningSummarizer: ReasoningSummarizing {
    @MainActor var isReady: Bool = true
    private var buffer: String = ""
    private var idCounter = 0

    @MainActor func feed(delta: String) { buffer += delta }

    @MainActor func summarize() async -> ReasoningSummary? {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let decisions = extractDecisions(from: text)
        buffer = ""
        if decisions.isEmpty { return nil }
        return ReasoningSummary(decisions: decisions, summary: nil)
    }

    @MainActor func reset() { buffer = ""; idCounter = 0 }

    private func extractDecisions(from text: String) -> [ReasoningDecision] {
        var results: [ReasoningDecision] = []
        let pattern = try? NSRegularExpression(pattern: "(?:I (?:should|will|decided to|could|might|need to|want to))\\s*(.+?)(?:\\s*(?:instead of|rather than|over|versus|vs\\.?|or)\\s*(.+?))?(?:\\s*(?:because|since|as|due to)\\s*(.+?))?[.!]|(?:choose|pick|opt for|go with)\\s*(.+?)(?:\\s*(?:over|instead of|rather than|versus|vs\\.?)\\s*(.+?))?", options: [.caseInsensitive])
        if let pattern {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                let nsText = text as NSString
                let choice = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let alt = match.range(at: 2).location != NSNotFound ? nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces) : nil
                let because = match.range(at: 3).location != NSNotFound ? nsText.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces) : nil
                let label = alt.map { "\(choice) vs \($0)" } ?? choice
                var options = [choice]; if let alt { options.append(alt) }
                idCounter += 1
                results.append(ReasoningDecision(id: "decision-\(idCounter)", label: String(label.prefix(80)), reasoning: because ?? choice, options: options))
            }
        }
        if results.isEmpty {
            let stepPattern = try? NSRegularExpression(pattern: "(?:Step|Phase|Stage)\\s*(\\d+)[:.)]\\s*(.+?)(?=(?:Step|Phase|Stage)\\s*\\d+|$)", options: [.caseInsensitive, .dotMatchesLineSeparators])
            if let pattern = stepPattern {
                let r = NSRange(text.startIndex..<text.endIndex, in: text)
                if pattern.matches(in: text, range: r).count >= 2 {
                    for m in pattern.matches(in: text, range: r) {
                        let s = (text as NSString).substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\n", with: " ")
                        idCounter += 1
                        results.append(ReasoningDecision(id: "step-\(idCounter)", label: String(s.prefix(80)), reasoning: s, options: []))
                    }
                }
            }
        }
        if results.isEmpty {
            let tradeoffPattern = try? NSRegularExpression(pattern: "(?:pros?:|advantages?:|benefits?:)\\s*(.+?)(?:cons?:|disadvantages?:|drawbacks?:|however|but|on the other hand)", options: [.caseInsensitive, .dotMatchesLineSeparators])
            if let pattern = tradeoffPattern,
               let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
                let pro = (text as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                idCounter += 1
                results.append(ReasoningDecision(id: "tradeoff-\(idCounter)", label: "Trade-off analysis", reasoning: String(pro.prefix(120)), options: []))
            }
        }
        return results
    }
}

// MARK: - MLX-Powered Summarizer (Apple Silicon)

#if canImport(MLXLLM) && canImport(MLXLMCommon)

import MLXLLM
import MLXLMCommon

/// MLX-accelerated summarizer using Gemma 3 1B 4-bit on Apple Silicon.
/// Model downloads from HuggingFace on first use (~600MB, cached).
/// Requires HuggingFace tokenizer/downloader adapters to be wired before use.
@MainActor
final class MLXReasoningSummarizer: ReasoningSummarizing {
    let isReady: Bool = false
    func feed(delta: String) {}
    func summarize() async -> ReasoningSummary? { nil }
    func reset() {}
}

#endif
