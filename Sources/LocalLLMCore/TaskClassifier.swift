import Foundation

public protocol SemanticTaskClassifying: Sendable {
    func classify(_ request: InferenceRequest, baseline: TaskRequirements) async throws -> TaskRequirements
}

public struct TaskClassifier: Sendable {
    public let semanticClassifier: (any SemanticTaskClassifying)?
    public init(semanticClassifier: (any SemanticTaskClassifying)? = nil) { self.semanticClassifier = semanticClassifier }

    public func classify(_ request: InferenceRequest) async -> TaskRequirements {
        var result = deterministicClassification(request)
        if result.confidence < 0.72, let semanticClassifier,
           let refined = try? await semanticClassifier.classify(request, baseline: result) {
            result = refined
            result.evidence.append("Ambiguous text refined by local semantic classifier")
        }
        return result
    }

    public func deterministicClassification(_ request: InferenceRequest) -> TaskRequirements {
        let text = request.text.lowercased()
        let modalities = Set(request.attachments.map(\.modality)).union(request.text.isEmpty ? [] : [.text])
        let images = request.attachments.filter { $0.modality == .image }.count
        let documents = request.attachments.filter { $0.modality == .document }
        let audioCount = request.attachments.filter { $0.modality == .audio }.count
        let hasCode = modalities.contains(.code) || containsAny(text, ["traceback", "compiler error", "exception", "function", "code", "python", "swift", "javascript", "typescript", "debug"])
        let wantsExtraction = request.requiresStructuredOutput || containsAny(text, ["extract", "return json", "export csv", "list all", "table of", "dimensions", "fields"])
        let wantsComparison = containsAny(text, ["compare", "difference", "versus", " vs ", "contrast"])
        let wantsReasoning = containsAny(text, ["why", "explain", "analyze", "reason", "what's wrong", "what is wrong", "evaluate", "synthesize"])
        var caps: Set<Capability> = []
        var category: TaskCategory = .chat
        var evidence: [String] = []
        var confidence = 0.62
        var specialistModalities = 0

        if audioCount > 0 {
            specialistModalities += 1; caps.insert(.speechToText); category = .transcription; confidence = 0.98
            evidence.append("\(audioCount) audio attachment(s) require speech-to-text")
            if containsAny(text, ["summarize", "question", "analyze", "minutes", "what did", "what was", "who said"]) {
                caps.formUnion([.summarization, .reasoning]); category = .audioAnalysis
            }
        }
        if !documents.isEmpty {
            specialistModalities += 1; caps.insert(.documentUnderstanding); category = .documentAnalysis; confidence = 0.96
            evidence.append("\(documents.count) document attachment(s) detected")
            if documents.contains(where: { $0.hasExtractableText == false }) || containsAny(text, ["scan", "scanned", "ocr"]) {
                caps.insert(.ocr); category = .scannedDocument
                evidence.append("Scanned/non-extractable document requires OCR")
            }
        }
        if images > 0 {
            specialistModalities += 1; caps.insert(.vision); category = .imageUnderstanding; confidence = 0.98
            evidence.append("\(images) image attachment(s) require vision")
            if images > 1 { caps.insert(.multiImageVision); evidence.append("Multiple images require multi-image support") }
            if wantsReasoning { caps.insert(.visualReasoning); category = .visualAnalysis }
        }
        if hasCode {
            if modalities.contains(.code) { specialistModalities += 1 }
            caps.insert(.coding); category = .coding; confidence = max(confidence, 0.88)
            evidence.append("Code file or coding terminology detected")
        }
        if wantsReasoning {
            if !modalities.contains(.image) { caps.insert(.reasoning) }
            if specialistModalities == 0 { category = .reasoning; confidence = 0.78 }
            evidence.append("Reasoning intent detected")
        }
        if caps.isEmpty { caps.insert(.generalChat); evidence.append("No specialist modality or task signal detected") }
        if wantsExtraction { caps.insert(.structuredExtraction); category = .structuredExtraction; evidence.append("Structured extraction intent detected") }
        if wantsComparison { caps.formUnion([.comparison, .reasoning]); category = .comparison; evidence.append("Comparison intent detected") }
        if specialistModalities > 1 { category = .multimodal; evidence.append("Combined modalities require a multi-stage route") }
        if request.minimumContextTokens > 32_768 { caps.insert(.longContext); evidence.append("Requested context exceeds 32K tokens") }
        if request.requiresStructuredOutput { confidence = max(confidence, 0.9) }
        return TaskRequirements(category: category, requiredCapabilities: caps, inputModalities: modalities,
                                minimumContextTokens: request.minimumContextTokens,
                                requiresStructuredOutput: request.requiresStructuredOutput,
                                confidence: confidence, evidence: evidence)
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool { needles.contains(where: text.contains) }
}
