import Foundation

public enum InferenceBackend: String, Codable, Sendable { case mlxLM = "mlx-lm", mlxVLM = "mlx-vlm", whisperMLX = "whisper-mlx", nativeDocument = "native-document" }
public enum ModelHealth: String, Codable, Sendable { case unknown, healthy, degraded, unavailable, failed }
public enum LoadedState: String, Codable, Sendable { case unloaded, loading, loaded, unloading, failed }

public struct CapabilityBenchmark: Codable, Hashable, Sendable {
    public var capability: Capability
    public var quality: Double
    public var firstTokenMilliseconds: Double?
    public var totalMilliseconds: Double?
    public var tokensPerSecond: Double?
    public var peakMemoryBytes: Int64?
    public var measuredAt: Date
    public var failures: Int
    public var malformedOutputs: Int
    public init(capability: Capability, quality: Double, firstTokenMilliseconds: Double? = nil,
                totalMilliseconds: Double? = nil, tokensPerSecond: Double? = nil, peakMemoryBytes: Int64? = nil,
                measuredAt: Date = Date(), failures: Int = 0, malformedOutputs: Int = 0) {
        self.capability = capability; self.quality = quality; self.firstTokenMilliseconds = firstTokenMilliseconds
        self.totalMilliseconds = totalMilliseconds; self.tokensPerSecond = tokensPerSecond; self.peakMemoryBytes = peakMemoryBytes
        self.measuredAt = measuredAt; self.failures = failures; self.malformedOutputs = malformedOutputs
    }
}

public struct RegisteredModel: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var backend: InferenceBackend
    public var localPath: URL
    public var family: String
    public var quantization: String?
    public var capabilities: Set<Capability>
    public var inputModalities: Set<Modality>
    public var outputModalities: Set<Modality>
    public var approximateMemoryBytes: Int64
    public var contextWindow: Int
    public var measuredLoadMilliseconds: Double?
    public var measuredTokensPerSecond: Double?
    public var supportsStructuredOutput: Bool
    public var supportsToolUse: Bool
    public var supportsMultipleImages: Bool
    public var strengths: [String]
    public var weaknesses: [String]
    public var benchmarks: [CapabilityBenchmark]
    public var loadedState: LoadedState
    public var health: ModelHealth

    public init(id: String, backend: InferenceBackend, localPath: URL, family: String,
                quantization: String? = nil, capabilities: Set<Capability>, inputModalities: Set<Modality>,
                outputModalities: Set<Modality> = [.text], approximateMemoryBytes: Int64,
                contextWindow: Int = 32_768, measuredLoadMilliseconds: Double? = nil,
                measuredTokensPerSecond: Double? = nil, supportsStructuredOutput: Bool = false,
                supportsToolUse: Bool = false, supportsMultipleImages: Bool = false,
                strengths: [String] = [], weaknesses: [String] = [], benchmarks: [CapabilityBenchmark] = [],
                loadedState: LoadedState = .unloaded, health: ModelHealth = .unknown) {
        self.id = id; self.backend = backend; self.localPath = localPath; self.family = family
        self.quantization = quantization; self.capabilities = capabilities; self.inputModalities = inputModalities
        self.outputModalities = outputModalities; self.approximateMemoryBytes = approximateMemoryBytes
        self.contextWindow = contextWindow; self.measuredLoadMilliseconds = measuredLoadMilliseconds
        self.measuredTokensPerSecond = measuredTokensPerSecond; self.supportsStructuredOutput = supportsStructuredOutput
        self.supportsToolUse = supportsToolUse; self.supportsMultipleImages = supportsMultipleImages
        self.strengths = strengths; self.weaknesses = weaknesses; self.benchmarks = benchmarks
        self.loadedState = loadedState; self.health = health
    }
}

public struct ModelRegistry: Sendable {
    public private(set) var models: [RegisteredModel]
    public init(models: [RegisteredModel] = []) { self.models = models }
    public mutating func upsert(_ model: RegisteredModel) {
        if let index = models.firstIndex(where: { $0.id == model.id }) { models[index] = model } else { models.append(model) }
    }
    public mutating func remove(id: String) { models.removeAll { $0.id == id } }
    public func model(id: String) -> RegisteredModel? { models.first { $0.id == id } }
    public func compatible(with requirements: TaskRequirements) -> [RegisteredModel] {
        models.filter { model in
            model.health != .unavailable && model.health != .failed &&
            requirements.requiredCapabilities.isSubset(of: model.capabilities) &&
            requirements.inputModalities.subtracting([.text]).isSubset(of: model.inputModalities) &&
            model.contextWindow >= requirements.minimumContextTokens &&
            (!requirements.requiresStructuredOutput || model.supportsStructuredOutput)
        }
    }
}

public struct ModelCapabilityProfile: Codable, Sendable {
    public var backend: InferenceBackend?
    public var capabilities: Set<Capability>?
    public var inputModalities: Set<Modality>?
    public var outputModalities: Set<Modality>?
    public var contextWindow: Int?
    public var supportsStructuredOutput: Bool?
    public var supportsToolUse: Bool?
    public var supportsMultipleImages: Bool?
    public var strengths: [String]?
    public var weaknesses: [String]?
}

public struct ModelRegistryDiscovery: Sendable {
    public let cacheRoot: URL
    public let metadataDirectory: URL?
    public let benchmarkURL: URL?
    public let profileURL: URL?
    public init(cacheRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub"),
                metadataDirectory: URL? = nil, benchmarkURL: URL? = nil, profileURL: URL? = nil) {
        self.cacheRoot = cacheRoot; self.metadataDirectory = metadataDirectory; self.benchmarkURL = benchmarkURL; self.profileURL = profileURL
    }

    public func discover() -> ModelRegistry {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: nil) else { return ModelRegistry() }
        var registry = ModelRegistry()
        for folder in folders where folder.lastPathComponent.hasPrefix("models--") {
            let encoded = String(folder.lastPathComponent.dropFirst("models--".count))
            guard let separator = encoded.range(of: "--") else { continue }
            let id = encoded.replacingCharacters(in: separator, with: "/")
            let snapshots = folder.appending(path: "snapshots")
            guard let choices = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey]),
                  let snapshot = choices.filter({ fm.fileExists(atPath: $0.appending(path: "config.json").path) && containsModelWeights($0) })
                    .max(by: { modificationDate($0) < modificationDate($1) }),
                  let discovered = makeModel(id: id, snapshot: snapshot, cacheFolder: folder) else { continue }
            registry.upsert(loadOverride(for: id) ?? discovered)
        }
        if let profileURL, let data = try? Data(contentsOf: profileURL),
           let profiles = try? JSONDecoder().decode([String: ModelCapabilityProfile].self, from: data) {
            for (id, profile) in profiles {
                guard var model = registry.model(id: id) else { continue }
                if let value = profile.backend { model.backend = value }
                if let value = profile.capabilities { model.capabilities = value }
                if let value = profile.inputModalities { model.inputModalities = value }
                if let value = profile.outputModalities { model.outputModalities = value }
                if let value = profile.contextWindow { model.contextWindow = value }
                if let value = profile.supportsStructuredOutput { model.supportsStructuredOutput = value }
                if let value = profile.supportsToolUse { model.supportsToolUse = value }
                if let value = profile.supportsMultipleImages { model.supportsMultipleImages = value }
                if let value = profile.strengths { model.strengths = value }
                if let value = profile.weaknesses { model.weaknesses = value }
                registry.upsert(model)
            }
        }
        if let benchmarkURL, let data = try? Data(contentsOf: benchmarkURL) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            if let values = try? decoder.decode([String: [CapabilityBenchmark]].self, from: data) {
                for (id, benchmarks) in values {
                    guard var model = registry.model(id: id) else { continue }
                    model.benchmarks = benchmarks
                    model.measuredTokensPerSecond = benchmarks.compactMap(\.tokensPerSecond).max()
                    model.measuredLoadMilliseconds = benchmarks.compactMap(\.firstTokenMilliseconds).min()
                    if let peak = benchmarks.compactMap(\.peakMemoryBytes).max() { model.approximateMemoryBytes = max(model.approximateMemoryBytes, Int64(Double(peak) * 1.15)) }
                    registry.upsert(model)
                }
            }
        }
        return registry
    }

    private func makeModel(id: String, snapshot: URL, cacheFolder: URL) -> RegisteredModel? {
        guard let data = try? Data(contentsOf: snapshot.appending(path: "config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let family = (config["model_type"] as? String ?? "unknown").lowercased()
        if ["bert", "embedding", "_mtp"].contains(where: family.contains) { return nil }
        let architecture = ((config["architectures"] as? [String]) ?? []).joined(separator: " ").lowercased()
        let descriptor = "\(family) \(architecture)"
        let isVision = ["vl", "vision", "ocr", "gemma4", "dots_ocr"].contains(where: descriptor.contains)
        let isOCR = descriptor.contains("ocr")
        let isCoder = id.localizedCaseInsensitiveContains("coder")
        var caps: Set<Capability> = isOCR ? [.ocr, .documentUnderstanding, .structuredExtraction] : [.generalChat, .reasoning, .summarization, .comparison]
        var inputs: Set<Modality> = [.text]
        if isCoder { caps.insert(.coding); inputs.insert(.code) }
        if isVision {
            inputs.formUnion([.image, .document])
            if !isOCR { caps.formUnion([.vision, .visualReasoning, .documentUnderstanding]) }
        }
        let multiImage = isVision && !isOCR
        if multiImage { caps.insert(.multiImageVision) }
        let context = (config["max_position_embeddings"] as? Int) ?? (config["text_config"] as? [String: Any])?["max_position_embeddings"] as? Int ?? 32_768
        if context > 32_768 && !isOCR { caps.insert(.longContext) }
        let size = directorySize(cacheFolder.appending(path: "blobs"))
        let quant = quantization(from: id)
        return RegisteredModel(id: id, backend: isVision ? .mlxVLM : .mlxLM, localPath: snapshot, family: family,
            quantization: quant, capabilities: caps, inputModalities: inputs, approximateMemoryBytes: max(Int64(Double(size) * 1.15), 512_000_000),
            contextWindow: context, supportsStructuredOutput: true, supportsToolUse: false,
            supportsMultipleImages: multiImage, strengths: isOCR ? ["document OCR"] : isCoder ? ["code"] : isVision ? ["visual understanding"] : ["language"],
            weaknesses: [], health: .healthy)
    }

    private func loadOverride(for id: String) -> RegisteredModel? {
        guard let metadataDirectory else { return nil }
        let safe = id.replacingOccurrences(of: "/", with: "--") + ".json"
        guard let data = try? Data(contentsOf: metadataDirectory.appending(path: safe)) else { return nil }
        return try? JSONDecoder().decode(RegisteredModel.self, from: data)
    }
    private func modificationDate(_ url: URL) -> Date { (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    private func containsModelWeights(_ snapshot: URL) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(at: snapshot, includingPropertiesForKeys: nil) else { return false }
        return files.contains { ["safetensors", "gguf", "npz"].contains($0.pathExtension.lowercased()) }
    }
    private func quantization(from id: String) -> String? {
        let expression = try? NSRegularExpression(pattern: #"(?i)(\d+(?:\.\d+)?bit|fp16|bf16)"#)
        let range = NSRange(id.startIndex..., in: id)
        guard let match = expression?.firstMatch(in: id, range: range), let r = Range(match.range(at: 1), in: id) else { return nil }
        return String(id[r])
    }
    private func directorySize(_ root: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var result: Int64 = 0
        for case let file as URL in e { if let v = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true { result += Int64(v.fileSize ?? 0) } }
        return result
    }
}

public actor BenchmarkStore {
    public let url: URL
    private var records: [String: [CapabilityBenchmark]]
    public init(url: URL) {
        self.url = url
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let value = try? decoder.decode([String: [CapabilityBenchmark]].self, from: data) { records = value } else { records = [:] }
    }
    public func benchmarks(for modelID: String) -> [CapabilityBenchmark] { records[modelID] ?? [] }
    public func record(modelID: String, benchmark: CapabilityBenchmark) throws {
        var values = records[modelID] ?? []
        values.removeAll { $0.capability == benchmark.capability }
        values.append(benchmark); records[modelID] = values
        let data = try JSONEncoder.pretty.encode(records)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; e.dateEncodingStrategy = .iso8601; return e }
}
