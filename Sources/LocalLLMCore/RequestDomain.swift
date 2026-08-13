import Foundation

public enum Capability: String, Codable, CaseIterable, Hashable, Sendable {
    case generalChat = "general_chat"
    case reasoning, coding
    case longContext = "long_context"
    case vision
    case multiImageVision = "multi_image_vision"
    case ocr = "OCR"
    case documentUnderstanding = "document_understanding"
    case visualReasoning = "visual_reasoning"
    case structuredExtraction = "structured_extraction"
    case speechToText = "speech_to_text"
    case audioUnderstanding = "audio_understanding"
    case toolUse = "tool_use"
    case summarization, comparison
}

public enum Modality: String, Codable, CaseIterable, Hashable, Sendable {
    case text, image, document, audio, code
}

public enum TaskCategory: String, Codable, Hashable, Sendable {
    case chat, reasoning, coding, imageUnderstanding, visualAnalysis
    case documentAnalysis, scannedDocument, transcription, audioAnalysis
    case structuredExtraction, comparison, multimodal, unknown
}

public enum QualityPreference: String, Codable, Sendable { case fast, balanced, best }
public enum LatencySensitivity: String, Codable, Sendable { case interactive, normal, batch }

public struct RequestAttachment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let modality: Modality
    public let mimeType: String?
    public let hasExtractableText: Bool?
    public let pageCount: Int?

    public init(id: UUID = UUID(), url: URL, modality: Modality? = nil, mimeType: String? = nil,
                hasExtractableText: Bool? = nil, pageCount: Int? = nil) {
        self.id = id
        self.url = url
        self.mimeType = mimeType
        self.modality = modality ?? Self.inferModality(url: url, mimeType: mimeType)
        self.hasExtractableText = hasExtractableText
        self.pageCount = pageCount
    }

    public static func inferModality(url: URL, mimeType: String?) -> Modality {
        let mime = (mimeType ?? "").lowercased()
        let ext = url.pathExtension.lowercased()
        if mime.hasPrefix("image/") || ["png", "jpg", "jpeg", "heic", "webp", "tiff", "bmp"].contains(ext) { return .image }
        if mime.hasPrefix("audio/") || ["wav", "mp3", "m4a", "aac", "flac", "ogg"].contains(ext) { return .audio }
        if mime == "application/pdf" || ["pdf", "doc", "docx", "rtf", "pages"].contains(ext) { return .document }
        if ["swift", "py", "js", "ts", "tsx", "jsx", "rs", "go", "java", "c", "cpp", "h", "json", "yaml", "yml"].contains(ext) { return .code }
        return .document
    }
}

public struct ConversationTurn: Codable, Hashable, Sendable {
    public var role: String
    public var content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public struct InferenceRequest: Identifiable, Codable, Sendable {
    public let id: UUID
    public var text: String
    public var attachments: [RequestAttachment]
    public var history: [ConversationTurn]
    public var quality: QualityPreference
    public var latencySensitivity: LatencySensitivity
    public var minimumContextTokens: Int
    public var requiresStructuredOutput: Bool
    public var structuredOutputSchema: String?
    public var localOnly: Bool
    public var forcedModelID: String?

    public init(id: UUID = UUID(), text: String, attachments: [RequestAttachment] = [], history: [ConversationTurn] = [],
                quality: QualityPreference = .balanced, latencySensitivity: LatencySensitivity = .normal,
                minimumContextTokens: Int = 0, requiresStructuredOutput: Bool = false,
                structuredOutputSchema: String? = nil, localOnly: Bool = true, forcedModelID: String? = nil) {
        self.id = id; self.text = text; self.attachments = attachments; self.history = history; self.quality = quality
        self.latencySensitivity = latencySensitivity; self.minimumContextTokens = minimumContextTokens
        self.requiresStructuredOutput = requiresStructuredOutput; self.structuredOutputSchema = structuredOutputSchema
        self.localOnly = localOnly; self.forcedModelID = forcedModelID
    }
}

public struct TaskRequirements: Codable, Equatable, Sendable {
    public var category: TaskCategory
    public var requiredCapabilities: Set<Capability>
    public var inputModalities: Set<Modality>
    public var minimumContextTokens: Int
    public var requiresStructuredOutput: Bool
    public var confidence: Double
    public var evidence: [String]

    public init(category: TaskCategory, requiredCapabilities: Set<Capability>, inputModalities: Set<Modality>,
                minimumContextTokens: Int = 0, requiresStructuredOutput: Bool = false,
                confidence: Double = 1, evidence: [String] = []) {
        self.category = category; self.requiredCapabilities = requiredCapabilities; self.inputModalities = inputModalities
        self.minimumContextTokens = minimumContextTokens; self.requiresStructuredOutput = requiresStructuredOutput
        self.confidence = confidence; self.evidence = evidence
    }
}
