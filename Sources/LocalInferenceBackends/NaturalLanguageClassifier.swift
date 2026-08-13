import Foundation
import LocalLLMCore
import NaturalLanguage

public actor NaturalLanguageTaskClassifier: SemanticTaskClassifying {
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    private let examples: [(String, TaskCategory, Set<Capability>)] = [
        ("have a casual conversation and answer a simple question", .chat, [.generalChat]),
        ("work through a difficult problem and justify the conclusion", .reasoning, [.reasoning]),
        ("inspect source code, diagnose a bug, and propose a fix", .coding, [.coding, .reasoning]),
        ("extract named fields into a machine readable schema", .structuredExtraction, [.structuredExtraction, .reasoning]),
        ("summarize and synthesize a long body of information", .reasoning, [.summarization, .reasoning]),
    ]

    public init() {}

    public func classify(_ request: InferenceRequest, baseline: TaskRequirements) async throws -> TaskRequirements {
        guard let embedding, let query = embedding.vector(for: request.text), !request.text.isEmpty else { return baseline }
        var best: (score: Double, category: TaskCategory, capabilities: Set<Capability>)?
        for (example, category, capabilities) in examples {
            guard let vector = embedding.vector(for: example) else { continue }
            let score = cosine(query, vector)
            if best == nil || score > best!.score { best = (score, category, capabilities) }
        }
        guard let best, best.score >= 0.35 else { return baseline }
        var result = baseline
        result.category = best.category
        result.requiredCapabilities.formUnion(best.capabilities)
        if baseline.requiredCapabilities == [.generalChat], best.category != .chat { result.requiredCapabilities.remove(.generalChat) }
        result.confidence = min(0.9, 0.55 + best.score * 0.35)
        result.evidence.append("Apple NaturalLanguage semantic similarity \(String(format: "%.2f", best.score))")
        return result
    }

    private func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return -1 }
        var dot = 0.0, aa = 0.0, bb = 0.0
        for index in a.indices { dot += a[index] * b[index]; aa += a[index] * a[index]; bb += b[index] * b[index] }
        return dot / max((aa * bb).squareRoot(), 1e-9)
    }
}
