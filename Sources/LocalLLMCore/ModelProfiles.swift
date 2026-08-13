import CryptoKit
import Foundation

public enum ProfileLifecycle: String, Codable, Sendable { case current, candidate, retired }
public enum EvaluationSplit: String, Codable, Sendable { case train, development, heldOut = "held_out" }
public enum ExperimentDecision: String, Codable, Sendable { case promote, reject, retain }

public struct GenerationConfiguration: Codable, Hashable, Sendable {
    public var temperature: Double
    public var topP: Double?
    public var topK: Int?
    public var repetitionPenalty: Double?
    public var maxOutputTokens: Int
    public var stopSequences: [String]
    public var promptCacheEnabled: Bool
    public init(temperature: Double = 0, topP: Double? = nil, topK: Int? = nil,
                repetitionPenalty: Double? = nil, maxOutputTokens: Int = 8192,
                stopSequences: [String] = [], promptCacheEnabled: Bool = true) {
        self.temperature = temperature; self.topP = topP; self.topK = topK
        self.repetitionPenalty = repetitionPenalty; self.maxOutputTokens = maxOutputTokens
        self.stopSequences = stopSequences; self.promptCacheEnabled = promptCacheEnabled
    }
}

public struct PreprocessingConfiguration: Codable, Hashable, Sendable {
    public var version: String
    public var pdfDPI: Int
    public var maximumImageDimension: Int
    public var imageGrouping: Int
    public var contrastNormalization: Bool
    public var chunkSize: Int
    public var chunkOverlap: Int
    public init(version: String = "v1", pdfDPI: Int = 144, maximumImageDimension: Int = 4096,
                imageGrouping: Int = 1, contrastNormalization: Bool = false,
                chunkSize: Int = 8_000, chunkOverlap: Int = 400) {
        self.version = version; self.pdfDPI = pdfDPI; self.maximumImageDimension = maximumImageDimension
        self.imageGrouping = imageGrouping; self.contrastNormalization = contrastNormalization
        self.chunkSize = chunkSize; self.chunkOverlap = chunkOverlap
    }
}

/// A deployable, versioned configuration. Base weights remain immutable and adapters are references.
public struct ModelProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var version: String
    public var baseModelID: String
    public var taskClasses: Set<TaskCategory>
    public var capabilities: Set<Capability>
    public var lifecycle: ProfileLifecycle
    public var systemPrompt: String
    public var taskInstruction: String
    public var fewShotExamples: [String]
    public var promptTemplateVersion: String
    public var preprocessing: PreprocessingConfiguration
    public var generation: GenerationConfiguration
    public var adapterID: String?
    public var backendOptions: [String: String]
    public var createdAt: Date
    public init(id: String, version: String, baseModelID: String, taskClasses: Set<TaskCategory>,
                capabilities: Set<Capability>, lifecycle: ProfileLifecycle = .candidate,
                systemPrompt: String = "", taskInstruction: String = "", fewShotExamples: [String] = [],
                promptTemplateVersion: String = "v1", preprocessing: PreprocessingConfiguration = .init(),
                generation: GenerationConfiguration = .init(), adapterID: String? = nil,
                backendOptions: [String: String] = [:], createdAt: Date = Date()) {
        self.id = id; self.version = version; self.baseModelID = baseModelID; self.taskClasses = taskClasses
        self.capabilities = capabilities; self.lifecycle = lifecycle; self.systemPrompt = systemPrompt
        self.taskInstruction = taskInstruction; self.fewShotExamples = fewShotExamples
        self.promptTemplateVersion = promptTemplateVersion; self.preprocessing = preprocessing
        self.generation = generation; self.adapterID = adapterID; self.backendOptions = backendOptions
        self.createdAt = createdAt
    }
    public var qualifiedID: String { "\(id)@\(version)" }
    public var configurationDigest: String {
        let generationData = (try? JSONEncoder().encode(generation)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        let preprocessingData = (try? JSONEncoder().encode(preprocessing)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? [:]
        let canonical: [String: Any] = ["id": id, "version": version, "base_model": baseModelID,
            "task_classes": taskClasses.map(\.rawValue).sorted(), "capabilities": capabilities.map(\.rawValue).sorted(),
            "lifecycle": lifecycle.rawValue, "system_prompt": systemPrompt, "task_instruction": taskInstruction,
            "examples": fewShotExamples, "prompt_template": promptTemplateVersion,
            "preprocessing": preprocessingData, "generation": generationData, "adapter": adapterID ?? "",
            "backend_options": backendOptions, "created_at": ISO8601DateFormatter().string(from: createdAt)]
        let bytes = (try? JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])) ?? Data(qualifiedID.utf8)
        return StableDigest.sha256(bytes)
    }
}

public struct ProfileMetrics: Codable, Hashable, Sendable {
    public var quality: Double
    public var completeness: Double?
    public var hallucinationRate: Double?
    public var malformedOutputRate: Double
    public var totalMilliseconds: Double?
    public var firstTokenMilliseconds: Double?
    public var tokensPerSecond: Double?
    public var peakMemoryBytes: Int64?
    public var loadMilliseconds: Double?
    public var failures: Int
    public var examples: Int
    public init(quality: Double, completeness: Double? = nil, hallucinationRate: Double? = nil,
                malformedOutputRate: Double = 0, totalMilliseconds: Double? = nil,
                firstTokenMilliseconds: Double? = nil, tokensPerSecond: Double? = nil,
                peakMemoryBytes: Int64? = nil, loadMilliseconds: Double? = nil,
                failures: Int = 0, examples: Int) {
        self.quality = quality; self.completeness = completeness; self.hallucinationRate = hallucinationRate
        self.malformedOutputRate = malformedOutputRate; self.totalMilliseconds = totalMilliseconds
        self.firstTokenMilliseconds = firstTokenMilliseconds; self.tokensPerSecond = tokensPerSecond
        self.peakMemoryBytes = peakMemoryBytes; self.loadMilliseconds = loadMilliseconds
        self.failures = failures; self.examples = examples
    }
}

public struct OptimizationExperiment: Identifiable, Codable, Sendable {
    public var id: String
    public var recordedAt: Date
    public var taskClass: TaskCategory
    public var datasetID: String
    public var datasetVersion: String
    public var split: EvaluationSplit
    public var baselineProfileID: String
    public var candidateProfileID: String
    public var changedVariables: [String]
    public var before: ProfileMetrics
    public var after: ProfileMetrics
    public var regressions: [String]
    public var decision: ExperimentDecision
    public var rationale: String
    public var provenance: [String: String]
    public var independentCaseCount: Int
    public var evidenceDigest: String
    public var scorerVersion: String
    public init(id: String, recordedAt: Date = Date(), taskClass: TaskCategory, datasetID: String,
                datasetVersion: String, split: EvaluationSplit, baselineProfileID: String,
                candidateProfileID: String, changedVariables: [String], before: ProfileMetrics,
                after: ProfileMetrics, regressions: [String] = [], decision: ExperimentDecision,
                rationale: String, provenance: [String: String] = [:], independentCaseCount: Int,
                evidenceDigest: String, scorerVersion: String) {
        self.id = id; self.recordedAt = recordedAt; self.taskClass = taskClass; self.datasetID = datasetID
        self.datasetVersion = datasetVersion; self.split = split; self.baselineProfileID = baselineProfileID
        self.candidateProfileID = candidateProfileID; self.changedVariables = changedVariables
        self.before = before; self.after = after; self.regressions = regressions
        self.decision = decision; self.rationale = rationale; self.provenance = provenance
        self.independentCaseCount = independentCaseCount; self.evidenceDigest = evidenceDigest
        self.scorerVersion = scorerVersion
    }
}

public enum ProfileRegistryError: LocalizedError, Equatable {
    case duplicateProfile(String)
    case unknownProfile(String)
    case insufficientHeldOutEvidence(String)
    case rejectedExperiment(String)
    case invalidAdapter(String)
    public var errorDescription: String? {
        switch self {
        case .duplicateProfile(let id): "Profile already exists: \(id)."
        case .unknownProfile(let id): "Unknown profile: \(id)."
        case .insufficientHeldOutEvidence(let id): "Profile \(id) lacks held-out evidence with at least two examples."
        case .rejectedExperiment(let id): "Profile \(id) has no accepted, regression-free held-out result."
        case .invalidAdapter(let id): "Adapter for \(id) is missing or outside the configured adapter root."
        }
    }
}

public struct ModelProfileRegistry: Codable, Sendable {
    public var schemaVersion: Int?
    public var releaseVersion: Int?
    public private(set) var profiles: [ModelProfile]
    public private(set) var experiments: [OptimizationExperiment]
    public init(schemaVersion: Int = 1, releaseVersion: Int = 1,
                profiles: [ModelProfile] = [], experiments: [OptimizationExperiment] = []) {
        self.schemaVersion = schemaVersion; self.releaseVersion = releaseVersion
        self.profiles = profiles; self.experiments = experiments
    }
    public static func merged(shipped: ModelProfileRegistry, installed: ModelProfileRegistry) -> ModelProfileRegistry {
        let shippedWins = (shipped.releaseVersion ?? 0) > (installed.releaseVersion ?? 0)
        let primary = shippedWins ? shipped : installed
        let secondary = shippedWins ? installed : shipped
        var profiles = primary.profiles
        for profile in secondary.profiles where !profiles.contains(where: { $0.qualifiedID == profile.qualifiedID }) { profiles.append(profile) }
        var experiments = primary.experiments
        for experiment in secondary.experiments where !experiments.contains(where: { $0.id == experiment.id }) { experiments.append(experiment) }
        return ModelProfileRegistry(schemaVersion: max(shipped.schemaVersion ?? 1, installed.schemaVersion ?? 1),
            releaseVersion: max(shipped.releaseVersion ?? 0, installed.releaseVersion ?? 0),
            profiles: profiles, experiments: experiments)
    }

    public func profile(qualifiedID: String) -> ModelProfile? { profiles.first { $0.qualifiedID == qualifiedID } }
    public mutating func register(_ profile: ModelProfile, adapterRoot: URL? = nil) throws {
        guard !profiles.contains(where: { $0.qualifiedID == profile.qualifiedID }) else { throw ProfileRegistryError.duplicateProfile(profile.qualifiedID) }
        if let adapter = profile.adapterID {
            guard let root = adapterRoot else { throw ProfileRegistryError.invalidAdapter(profile.qualifiedID) }
            let candidate = root.appending(path: adapter).standardizedFileURL
            guard candidate.path.hasPrefix(root.standardizedFileURL.path + "/"), FileManager.default.fileExists(atPath: candidate.path) else {
                throw ProfileRegistryError.invalidAdapter(profile.qualifiedID)
            }
        }
        profiles.append(profile)
    }
    public mutating func record(_ experiment: OptimizationExperiment) { experiments.removeAll { $0.id == experiment.id }; experiments.append(experiment) }
    public mutating func promote(_ qualifiedID: String) throws {
        guard let target = profiles.first(where: { $0.qualifiedID == qualifiedID }) else { throw ProfileRegistryError.unknownProfile(qualifiedID) }
        let evidence = experiments.filter { $0.candidateProfileID == qualifiedID && $0.split == .heldOut &&
            $0.independentCaseCount >= 2 && $0.after.examples >= 2 && !$0.evidenceDigest.isEmpty && !$0.scorerVersion.isEmpty }
        guard !evidence.isEmpty else { throw ProfileRegistryError.insufficientHeldOutEvidence(qualifiedID) }
        guard evidence.contains(where: { experiment in
            experiment.decision == .promote && experiment.regressions.isEmpty &&
            experiment.after.quality >= experiment.before.quality &&
            experiment.after.failures <= experiment.before.failures &&
            experiment.after.malformedOutputRate <= experiment.before.malformedOutputRate
        }) else { throw ProfileRegistryError.rejectedExperiment(qualifiedID) }
        for index in profiles.indices where profiles[index].baseModelID == target.baseModelID && !profiles[index].taskClasses.isDisjoint(with: target.taskClasses) {
            if profiles[index].lifecycle == .current { profiles[index].lifecycle = .retired }
        }
        if let index = profiles.firstIndex(where: { $0.qualifiedID == qualifiedID }) { profiles[index].lifecycle = .current }
    }
    public mutating func rollback(retired qualifiedID: String) throws {
        guard let target = profiles.first(where: { $0.qualifiedID == qualifiedID && $0.lifecycle == .retired }) else { throw ProfileRegistryError.unknownProfile(qualifiedID) }
        for index in profiles.indices where profiles[index].baseModelID == target.baseModelID && !profiles[index].taskClasses.isDisjoint(with: target.taskClasses) {
            if profiles[index].lifecycle == .current { profiles[index].lifecycle = .candidate }
        }
        if let index = profiles.firstIndex(where: { $0.qualifiedID == qualifiedID }) { profiles[index].lifecycle = .current }
    }
    public func preferred(baseModelID: String, category: TaskCategory, capabilities: Set<Capability>, quality: QualityPreference) -> ModelProfile? {
        let candidates = profiles.filter { $0.baseModelID == baseModelID && $0.lifecycle == .current &&
            ($0.taskClasses.isEmpty || $0.taskClasses.contains(category)) && capabilities.isSubset(of: $0.capabilities) }
        return candidates.sorted { lhs, rhs in
            let lm = latestMetrics(lhs.qualifiedID), rm = latestMetrics(rhs.qualifiedID)
            let ls = paretoScore(lm, quality: quality), rs = paretoScore(rm, quality: quality)
            return ls == rs ? lhs.qualifiedID < rhs.qualifiedID : ls > rs
        }.first
    }
    public func latestHeldOutMetrics(_ qualifiedID: String) -> ProfileMetrics? {
        experiments.filter { $0.candidateProfileID == qualifiedID && $0.split == .heldOut }
            .sorted { $0.recordedAt > $1.recordedAt }.first?.after
    }
    private func latestMetrics(_ id: String) -> ProfileMetrics? { latestHeldOutMetrics(id) }
    private func paretoScore(_ metrics: ProfileMetrics?, quality: QualityPreference) -> Double {
        guard let metrics else { return 0 }
        let latency = metrics.totalMilliseconds.map { min($0 / 300_000, 1) } ?? 0.5
        switch quality { case .best: return metrics.quality * 0.85 - latency * 0.15; case .fast: return metrics.quality * 0.45 - latency * 0.55; case .balanced: return metrics.quality * 0.7 - latency * 0.3 }
    }
}

public enum StableDigest {
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func fnv1a64(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return String(format: "%016llx", hash)
    }
    public static func file(_ url: URL) throws -> String { sha256(try Data(contentsOf: url, options: [.mappedIfSafe])) }
}
