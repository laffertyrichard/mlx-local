import Foundation

public struct MachineResources: Codable, Sendable {
    public var totalMemoryBytes: Int64
    public var availableMemoryBytes: Int64
    public var loadedModelIDs: Set<String>
    public var reclaimableMemoryBytes: Int64
    public init(totalMemoryBytes: Int64, availableMemoryBytes: Int64, loadedModelIDs: Set<String> = [], reclaimableMemoryBytes: Int64 = 0) {
        self.totalMemoryBytes = totalMemoryBytes; self.availableMemoryBytes = availableMemoryBytes
        self.loadedModelIDs = loadedModelIDs; self.reclaimableMemoryBytes = reclaimableMemoryBytes
    }
}

public enum PipelineStageKind: String, Codable, Sendable { case direct, documentTextExtraction, ocr, transcription, visionExtraction, reasoning, validation }

public struct RouteStage: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: PipelineStageKind
    public var modelID: String?
    public var backend: InferenceBackend
    public var requiredCapabilities: Set<Capability>
    public var inputModalities: Set<Modality>
    public var fallbackModelIDs: [String]
    /// The evaluated deployable configuration selected independently from base-model identity.
    public var modelProfile: ModelProfile?
    /// Explicit deterministic validator contract; nil preserves the normal model validator.
    public var validationContract: String?
    public init(id: UUID = UUID(), kind: PipelineStageKind, modelID: String?, backend: InferenceBackend,
                requiredCapabilities: Set<Capability>, inputModalities: Set<Modality>, fallbackModelIDs: [String] = [],
                modelProfile: ModelProfile? = nil, validationContract: String? = nil) {
        self.id = id; self.kind = kind; self.modelID = modelID; self.backend = backend
        self.requiredCapabilities = requiredCapabilities; self.inputModalities = inputModalities
        self.fallbackModelIDs = fallbackModelIDs; self.modelProfile = modelProfile
        self.validationContract = validationContract
    }
}

public struct RoutingDecision: Codable, Equatable, Sendable {
    public var requestID: UUID
    public var requirements: TaskRequirements
    public var stages: [RouteStage]
    public var reason: String
    public var warnings: [String]
    public var scores: [String: Double]
    public var isPipeline: Bool { stages.count > 1 }
    public var selectedModelIDs: [String] { stages.compactMap(\.modelID) }

    public init(requestID: UUID, requirements: TaskRequirements, stages: [RouteStage], reason: String,
                warnings: [String] = [], scores: [String: Double] = [:]) {
        self.requestID = requestID; self.requirements = requirements; self.stages = stages
        self.reason = reason; self.warnings = warnings; self.scores = scores
    }
}

public enum RoutingError: LocalizedError, Equatable {
    case noModelsInstalled
    case forcedModelUnavailable(String)
    case forcedModelIncompatible(String, missing: Set<Capability>)
    case unsupportedCapabilities(Set<Capability>)
    case insufficientMemory(required: Int64, available: Int64)
    case invalidAttachment(String)

    public var errorDescription: String? {
        switch self {
        case .noModelsInstalled: "No local inference models are registered."
        case .forcedModelUnavailable(let id): "The manually selected model is unavailable: \(id)."
        case .forcedModelIncompatible(let id, let missing): "\(id) does not provide: \(missing.map(\.rawValue).sorted().joined(separator: ", "))."
        case .unsupportedCapabilities(let caps): "No local route provides: \(caps.map(\.rawValue).sorted().joined(separator: ", "))."
        case .insufficientMemory(let required, let available): "The smallest compatible route needs about \(required) bytes; \(available) bytes are available."
        case .invalidAttachment(let reason): "Attachment rejected: \(reason)"
        }
    }
}

public struct CapabilityRouter: Sendable {
    public init() {}

    public func route(request: InferenceRequest, requirements: TaskRequirements,
                      registry: ModelRegistry, resources: MachineResources,
                      profileRegistry: ModelProfileRegistry? = nil) throws -> RoutingDecision {
        guard !registry.models.isEmpty else { throw RoutingError.noModelsInstalled }
        try validateAttachments(request)
        if let forced = request.forcedModelID {
            guard let model = registry.model(id: forced), model.health != .failed, model.health != .unavailable else {
                throw RoutingError.forcedModelUnavailable(forced)
            }
            let nativeDocument = requirements.inputModalities.contains(.document) && !requirements.requiredCapabilities.contains(.ocr)
            let modelCapabilities = nativeDocument ? requirements.requiredCapabilities.subtracting([.documentUnderstanding]) : requirements.requiredCapabilities
            let modelModalities = nativeDocument ? Set([Modality.text]) : requirements.inputModalities
            let missing = modelCapabilities.subtracting(model.capabilities)
            let modalityMissing = !modelModalities.subtracting([.text]).isSubset(of: model.inputModalities)
            guard missing.isEmpty && !modalityMissing else {
                throw RoutingError.forcedModelIncompatible(forced, missing: missing.union(modalityMissing ? modalityCapabilities(modelModalities) : []))
            }
            guard canFit(model, resources: resources) else { throw RoutingError.insufficientMemory(required: model.approximateMemoryBytes, available: resources.availableMemoryBytes) }
            let scores = [model.id: score(model, request: request, requirements: requirements, resources: resources, profileRegistry: profileRegistry)]
            let modelRequirements = TaskRequirements(category: requirements.category, requiredCapabilities: modelCapabilities,
                inputModalities: modelModalities, minimumContextTokens: requirements.minimumContextTokens,
                requiresStructuredOutput: requirements.requiresStructuredOutput, evidence: requirements.evidence)
            var stages: [RouteStage] = []
            if nativeDocument { stages.append(RouteStage(kind: .documentTextExtraction, modelID: nil, backend: .nativeDocument, requiredCapabilities: [], inputModalities: [.document])) }
            stages.append(makeStage(kind: .direct, selected: model, alternatives: [], requirements: modelRequirements))
            let decision = RoutingDecision(requestID: request.id, requirements: requirements, stages: stages,
                reason: "Manual override selected \(model.id); capability and resource checks passed\(nativeDocument ? " after native document extraction" : "").", warnings: [], scores: scores)
            return applyingProfiles(decision, request: request, registry: profileRegistry)
        }

        let requiresSpecialistSynthesis = requirements.category == .comparison && requirements.requiredCapabilities.contains(.multiImageVision)
        let direct = (requirements.inputModalities.contains(.document) || requiresSpecialistSynthesis) ? [] : registry.compatible(with: requirements).filter { canFit($0, resources: resources) }
        if let selected = ranked(direct, request: request, requirements: requirements, resources: resources, profileRegistry: profileRegistry).first {
            let rankedModels = ranked(direct, request: request, requirements: requirements, resources: resources, profileRegistry: profileRegistry)
            let decision = RoutingDecision(requestID: request.id, requirements: requirements,
                stages: [makeStage(kind: .direct, selected: selected, alternatives: Array(rankedModels.dropFirst()), requirements: requirements)],
                reason: explain(selected, request: request, requirements: requirements, resources: resources, pipeline: false),
                warnings: [], scores: scoreMap(rankedModels, request: request, requirements: requirements, resources: resources, profileRegistry: profileRegistry))
            return applyingProfiles(decision, request: request, registry: profileRegistry)
        }

        let specs = pipelineSpecs(for: requirements)
        guard !specs.isEmpty else {
            let supported = registry.models.reduce(into: Set<Capability>()) { $0.formUnion($1.capabilities) }
            throw RoutingError.unsupportedCapabilities(requirements.requiredCapabilities.subtracting(supported))
        }
        var stages: [RouteStage] = []
        var allScores: [String: Double] = [:]
        var peakRequired: Int64 = 0
        for spec in specs {
            if spec.kind == .documentTextExtraction {
                stages.append(RouteStage(kind: spec.kind, modelID: nil, backend: .nativeDocument,
                                         requiredCapabilities: [], inputModalities: [.document]))
                continue
            }
            let stageRequirements = TaskRequirements(category: requirements.category, requiredCapabilities: spec.capabilities,
                inputModalities: spec.modalities, minimumContextTokens: spec.kind == .reasoning ? requirements.minimumContextTokens : 0,
                requiresStructuredOutput: spec.structured, evidence: requirements.evidence)
            let candidates = registry.compatible(with: stageRequirements)
            let fitted = candidates.filter { canFit($0, resources: resources) }
            guard let selected = ranked(fitted, request: request, requirements: stageRequirements, resources: resources, profileRegistry: profileRegistry).first else {
                if let smallest = candidates.min(by: { $0.approximateMemoryBytes < $1.approximateMemoryBytes }) {
                    throw RoutingError.insufficientMemory(required: smallest.approximateMemoryBytes, available: resources.availableMemoryBytes)
                }
                throw RoutingError.unsupportedCapabilities(spec.capabilities)
            }
            let rankedModels = ranked(fitted, request: request, requirements: stageRequirements, resources: resources, profileRegistry: profileRegistry)
            peakRequired = max(peakRequired, selected.approximateMemoryBytes)
            allScores.merge(scoreMap(rankedModels, request: request, requirements: stageRequirements, resources: resources, profileRegistry: profileRegistry), uniquingKeysWith: max)
            stages.append(makeStage(kind: spec.kind, selected: selected, alternatives: Array(rankedModels.dropFirst()), requirements: stageRequirements))
        }
        let decision = RoutingDecision(requestID: request.id, requirements: requirements, stages: stages,
            reason: "No single registered model satisfied all requirements. Selected a sequential \(stages.map(\.kind.rawValue).joined(separator: " → ")) pipeline; each specialist is capability-compatible and the peak estimate (\(peakRequired) bytes) fits available memory.",
            warnings: [], scores: allScores)
        return applyingProfiles(decision, request: request, registry: profileRegistry)
    }

    private struct StageSpec { var kind: PipelineStageKind; var capabilities: Set<Capability>; var modalities: Set<Modality>; var structured: Bool = false }
    private func pipelineSpecs(for r: TaskRequirements) -> [StageSpec] {
        var stages: [StageSpec] = []
        var remaining = r.requiredCapabilities
        if remaining.contains(.ocr) {
            if r.inputModalities.contains(.document) {
                stages.append(StageSpec(kind: .documentTextExtraction, capabilities: [], modalities: [.document]))
            }
            stages.append(StageSpec(kind: .ocr, capabilities: [.ocr], modalities: [.image], structured: true))
            remaining.subtract([.ocr, .documentUnderstanding, .structuredExtraction])
        } else if r.inputModalities.contains(.document) {
            stages.append(StageSpec(kind: .documentTextExtraction, capabilities: [], modalities: [.document]))
            remaining.remove(.documentUnderstanding)
        }
        if remaining.contains(.speechToText) {
            stages.append(StageSpec(kind: .transcription, capabilities: [.speechToText], modalities: [.audio], structured: true))
            remaining.subtract([.speechToText, .audioUnderstanding])
        }
        if remaining.contains(.vision) || remaining.contains(.multiImageVision) || remaining.contains(.visualReasoning) {
            let caps: Set<Capability> = remaining.contains(.multiImageVision) ? [.vision, .multiImageVision] : [.vision]
            stages.append(StageSpec(kind: .visionExtraction, capabilities: caps, modalities: [.image], structured: true))
            remaining.subtract([.vision, .multiImageVision, .visualReasoning])
        }
        if !remaining.isEmpty || stages.isEmpty || r.category == .multimodal || r.requiresStructuredOutput || r.requiredCapabilities.contains(.structuredExtraction) {
            var language = remaining
            language.remove(.structuredExtraction)
            language.remove(.comparison)
            if language.isEmpty { language = [.reasoning] }
            if !language.contains(.coding) && !language.contains(.generalChat) { language.insert(.reasoning) }
            stages.append(StageSpec(kind: .reasoning, capabilities: language, modalities: [.text], structured: r.requiresStructuredOutput))
        }
        if r.category == .comparison && r.requiredCapabilities.contains(.multiImageVision) {
            stages.append(StageSpec(kind: .validation, capabilities: [.reasoning], modalities: [.text], structured: r.requiresStructuredOutput))
        }
        return stages
    }

    private func ranked(_ models: [RegisteredModel], request: InferenceRequest, requirements: TaskRequirements,
                        resources: MachineResources, profileRegistry: ModelProfileRegistry?) -> [RegisteredModel] {
        models.sorted { a, b in
            let sa = score(a, request: request, requirements: requirements, resources: resources, profileRegistry: profileRegistry)
            let sb = score(b, request: request, requirements: requirements, resources: resources, profileRegistry: profileRegistry)
            return sa == sb ? a.id < b.id : sa > sb
        }
    }
    private func score(_ model: RegisteredModel, request: InferenceRequest, requirements: TaskRequirements,
                       resources: MachineResources, profileRegistry: ModelProfileRegistry?) -> Double {
        let relevant = model.benchmarks.filter { requirements.requiredCapabilities.contains($0.capability) }
        let selectedProfile = profileRegistry?.preferred(baseModelID: model.id, category: requirements.category,
            capabilities: requirements.requiredCapabilities, quality: request.quality)
        let profileMetrics = selectedProfile.flatMap { profileRegistry?.latestHeldOutMetrics($0.qualifiedID) }
        let quality = profileMetrics?.quality ?? (relevant.isEmpty ? 0.55 : relevant.map(\.quality).reduce(0, +) / Double(relevant.count))
        let failurePenalty = profileMetrics.map { Double($0.failures) * 0.04 + $0.malformedOutputRate * 0.08 } ??
            relevant.reduce(0.0) { $0 + Double($1.failures + $1.malformedOutputs) * 0.04 }
        let speed = model.measuredTokensPerSecond.map { min($0 / 50, 1) } ?? 0.3
        let loadPenalty = min((model.measuredLoadMilliseconds ?? 5_000) / 60_000, 1)
        let memoryPenalty = min(Double(model.approximateMemoryBytes) / Double(max(resources.totalMemoryBytes, 1)), 1)
        let resident = resources.loadedModelIDs.contains(model.id) ? 0.14 : 0
        let weights: (Double, Double) = request.quality == .best ? (0.72, 0.08) : request.quality == .fast ? (0.38, 0.36) : (0.56, 0.2)
        return weights.0 * quality + weights.1 * speed + resident - 0.08 * loadPenalty - 0.12 * memoryPenalty - failurePenalty
    }
    private func canFit(_ model: RegisteredModel, resources: MachineResources) -> Bool {
        resources.loadedModelIDs.contains(model.id) || model.approximateMemoryBytes <= Int64(Double(resources.availableMemoryBytes + resources.reclaimableMemoryBytes) * 0.9)
    }
    private func makeStage(kind: PipelineStageKind, selected: RegisteredModel, alternatives: [RegisteredModel], requirements: TaskRequirements) -> RouteStage {
        RouteStage(kind: kind, modelID: selected.id, backend: selected.backend, requiredCapabilities: requirements.requiredCapabilities,
                   inputModalities: requirements.inputModalities, fallbackModelIDs: alternatives.map(\.id))
    }
    private func scoreMap(_ models: [RegisteredModel], request: InferenceRequest, requirements: TaskRequirements,
                          resources: MachineResources, profileRegistry: ModelProfileRegistry?) -> [String: Double] {
        Dictionary(uniqueKeysWithValues: models.map { ($0.id, score($0, request: request, requirements: requirements,
            resources: resources, profileRegistry: profileRegistry)) })
    }
    private func explain(_ model: RegisteredModel, request: InferenceRequest, requirements: TaskRequirements, resources: MachineResources, pipeline: Bool) -> String {
        var factors = ["provides all required capabilities"]
        if resources.loadedModelIDs.contains(model.id) { factors.append("already loaded") }
        if !model.benchmarks.filter({ requirements.requiredCapabilities.contains($0.capability) }).isEmpty { factors.append("has relevant local benchmark data") }
        factors.append("fits the current memory budget")
        return "Selected \(model.id): " + factors.joined(separator: ", ") + "."
    }
    private func applyingProfiles(_ decision: RoutingDecision, request: InferenceRequest,
                                  registry: ModelProfileRegistry?) -> RoutingDecision {
        guard let registry else { return decision }
        var result = decision
        for index in result.stages.indices {
            guard let modelID = result.stages[index].modelID else { continue }
            result.stages[index].modelProfile = registry.preferred(baseModelID: modelID,
                category: decision.requirements.category,
                capabilities: result.stages[index].requiredCapabilities,
                quality: request.quality)
        }
        return result
    }

    private func validateAttachments(_ request: InferenceRequest) throws {
        let fm = FileManager.default
        for attachment in request.attachments {
            if request.localOnly && !attachment.url.isFileURL { throw RoutingError.invalidAttachment("remote URLs are disabled in local-only mode") }
            guard attachment.url.isFileURL else { continue }
            let resolved = attachment.url.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw RoutingError.invalidAttachment("file does not exist or is not a regular file: \(attachment.url.lastPathComponent)")
            }
            guard fm.isReadableFile(atPath: resolved.path) else { throw RoutingError.invalidAttachment("file is not readable: \(attachment.url.lastPathComponent)") }
            let limit: Int
            switch attachment.modality {
            case .image: limit = 50 * 1024 * 1024
            case .audio: limit = 250 * 1024 * 1024
            case .code, .text: limit = 8 * 1024 * 1024
            case .document: limit = 512 * 1024 * 1024
            }
            if let size = try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > limit {
                throw RoutingError.invalidAttachment("\(attachment.modality.rawValue) file exceeds the local safety limit")
            }
            if attachment.modality == .document, let pages = attachment.pageCount, pages > 250 {
                throw RoutingError.invalidAttachment("documents over 250 pages must be split into smaller local jobs")
            }
        }
    }

    private func modalityCapabilities(_ modalities: Set<Modality>) -> Set<Capability> {
        var result: Set<Capability> = []
        if modalities.contains(.image) { result.insert(.vision) }
        if modalities.contains(.audio) { result.insert(.speechToText) }
        if modalities.contains(.document) { result.insert(.documentUnderstanding) }
        if modalities.contains(.code) { result.insert(.coding) }
        return result
    }
}
