import Foundation
import os

private let log = Logger(subsystem: "com.researchoors.HermesNative", category: "ReasoningSummarizer")

// MARK: - Summarization Result

/// A decision-tree node extracted from agent reasoning.
struct ReasoningDecision: Codable, Sendable {
    let id: String
    let label: String
    let reasoning: String
    let options: [String]
}

/// The structured output from reasoning summarization.
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

/// Fast pattern-matching summarizer that extracts decision points
/// using keyword heuristics (pros/cons, alternatives, trade-offs).
final class HeuristicReasoningSummarizer: ReasoningSummarizing {
    @MainActor var isReady: Bool = true

    private var buffer: String = ""
    private var idCounter = 0

    @MainActor
    func feed(delta: String) {
        buffer += delta
    }

    @MainActor
    func summarize() async -> ReasoningSummary? {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let decisions = extractDecisions(from: text)
        buffer = ""

        if decisions.isEmpty { return nil }

        return ReasoningSummary(decisions: decisions, summary: nil)
    }

    @MainActor
    func reset() {
        buffer = ""
        idCounter = 0
    }

    private func extractDecisions(from text: String) -> [ReasoningDecision] {
        var results: [ReasoningDecision] = []

        // Pattern 1: "I should X instead of Y" / "choose between A and B"
        let choicePattern = try? NSRegularExpression(
            pattern: "(?:I (?:should|will|decided to|could|might|need to|want to))\\s*(.+?)(?:\\s*(?:instead of|rather than|over|versus|vs\\.?|or)\\s*(.+?))?(?:\\s*(?:because|since|as|due to)\\s*(.+?))?[.!]|(?:choose|pick|opt for|go with)\\s*(.+?)(?:\\s*(?:over|instead of|rather than|versus|vs\\.?)\\s*(.+?))?",
            options: [.caseInsensitive]
        )
        if let pattern = choicePattern {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in pattern.matches(in: text, range: range) {
                let nsText = text as NSString
                let choice = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let alternative = match.range(at: 2).location != NSNotFound
                    ? nsText.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces) : nil
                let because = match.range(at: 3).location != NSNotFound
                    ? nsText.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespaces) : nil

                let label: String
                if let alt = alternative { label = "\(choice) vs \(alt)" }
                else { label = choice }

                var options: [String] = [choice]
                if let alt = alternative { options.append(alt) }

                idCounter += 1
                results.append(ReasoningDecision(
                    id: "decision-\(idCounter)",
                    label: String(label.prefix(80)),
                    reasoning: because ?? choice,
                    options: options
                ))
            }
        }

        // Pattern 2: numbered steps — "Step 1:", "Phase 2:"
        if results.isEmpty {
            let stepPattern = try? NSRegularExpression(
                pattern: "(?:Step|Phase|Stage)\\s*(\\d+)[:.)]\\s*(.+?)(?=(?:Step|Phase|Stage)\\s*\\d+|$)",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
            if let pattern = stepPattern {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                let matches = pattern.matches(in: text, range: range)
                if matches.count >= 2 {
                    for match in matches {
                        let nsText = text as NSString
                        let stepLabel = nsText.substring(with: match.range(at: 2))
                            .trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "\n", with: " ")
                        idCounter += 1
                        results.append(ReasoningDecision(
                            id: "step-\(idCounter)",
                            label: String(stepLabel.prefix(80)),
                            reasoning: stepLabel,
                            options: []
                        ))
                    }
                }
            }
        }

        // Pattern 3: trade-off / pros-cons
        if results.isEmpty {
            let tradeoffPattern = try? NSRegularExpression(
                pattern: "(?:pros?:|advantages?:|benefits?:)\\s*(.+?)(?:cons?:|disadvantages?:|drawbacks?:|however|but|on the other hand)",
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            )
            if let pattern = tradeoffPattern {
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                if let match = pattern.firstMatch(in: text, range: range) {
                    let nsText = text as NSString
                    let pro = nsText.substring(with: match.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    idCounter += 1
                    results.append(ReasoningDecision(
                        id: "tradeoff-\(idCounter)",
                        label: "Trade-off analysis",
                        reasoning: String(pro.prefix(120)),
                        options: []
                    ))
                }
            }
        }

        return results
    }
}
