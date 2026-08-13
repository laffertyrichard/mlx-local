import Foundation

public enum ArtifactKind: String, Codable, Sendable { case text, markdown, json, transcript, visionObservations, finalResponse }
public struct PipelineArtifact: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: ArtifactKind
    public var content: String
    public var sourceURLs: [URL]
    public var confidence: Double?
    public var metadata: [String: String]
    public init(id: UUID = UUID(), kind: ArtifactKind, content: String, sourceURLs: [URL] = [],
                confidence: Double? = nil, metadata: [String: String] = [:]) {
        self.id = id; self.kind = kind; self.content = content; self.sourceURLs = sourceURLs
        self.confidence = confidence; self.metadata = metadata
    }
}

public struct StageExecutionInput: Sendable {
    public var request: InferenceRequest
    public var artifacts: [PipelineArtifact]
    public var requiresStructuredOutput: Bool
    public init(request: InferenceRequest, artifacts: [PipelineArtifact], requiresStructuredOutput: Bool) {
        self.request = request; self.artifacts = artifacts; self.requiresStructuredOutput = requiresStructuredOutput
    }
}

public protocol ModelRuntime: Sendable {
    var backend: InferenceBackend { get }
    func load(model: RegisteredModel) async throws
    func unload(model: RegisteredModel) async
    func execute(model: RegisteredModel?, stage: RouteStage, input: StageExecutionInput) async throws -> PipelineArtifact
    func health(model: RegisteredModel) async -> ModelHealth
}

public struct SourceIdentity: Codable, Equatable, Sendable {
    public var path: String
    public var byteCount: Int64
    public var modifiedAt: Date?
    public var digest: String
}

public struct CheckpointContext: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var pipelineVersion: String
    public var preprocessingVersion: String
    public var configurationDigest: String
    public var sourceIdentities: [SourceIdentity]
    public var profileDigests: [String]

    public static func make(request: InferenceRequest, decision: RoutingDecision,
                            pipelineVersion: String = "v3", preprocessingVersion: String = "v1",
                            relevantConfiguration: [String: String] = [:]) throws -> CheckpointContext {
        let sources = try request.attachments.map { attachment -> SourceIdentity in
            let url = attachment.url.resolvingSymlinksInPath()
            guard url.isFileURL else { return SourceIdentity(path: url.absoluteString, byteCount: 0, modifiedAt: nil, digest: "remote") }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return SourceIdentity(path: url.path, byteCount: Int64(values.fileSize ?? 0),
                                  modifiedAt: values.contentModificationDate, digest: try StableDigest.file(url))
        }.sorted { $0.path < $1.path }
        let semanticStages = decision.stages.map { stage in
            [stage.kind.rawValue, stage.modelID ?? "native", stage.backend.rawValue,
             stage.requiredCapabilities.map(\.rawValue).sorted().joined(separator: ","),
             stage.inputModalities.map(\.rawValue).sorted().joined(separator: ","),
             stage.fallbackModelIDs.joined(separator: ","), stage.modelProfile?.configurationDigest ?? "default",
             stage.validationContract ?? "model-validation"].joined(separator: ":")
        }
        let semantic: [String: Any] = [
            "text": request.text,
            "history": request.history.map { ["role": $0.role, "content": $0.content] },
            "attachments": request.attachments.map { ["path": $0.url.resolvingSymlinksInPath().path,
                "modality": $0.modality.rawValue, "mime": $0.mimeType ?? "",
                "extractable": $0.hasExtractableText.map(String.init) ?? "",
                "pages": $0.pageCount.map(String.init) ?? ""] },
            "quality": request.quality.rawValue, "latency": request.latencySensitivity.rawValue,
            "minimum_context": request.minimumContextTokens, "structured": request.requiresStructuredOutput,
            "schema": request.structuredOutputSchema ?? "", "local_only": request.localOnly,
            "forced_model": request.forcedModelID ?? "", "pipeline_version": pipelineVersion,
            "preprocessing_version": preprocessingVersion, "stages": semanticStages,
            "configuration": relevantConfiguration
        ]
        let payload = try JSONSerialization.data(withJSONObject: semantic, options: [.sortedKeys])
        return CheckpointContext(schemaVersion: 2, pipelineVersion: pipelineVersion,
            preprocessingVersion: preprocessingVersion, configurationDigest: StableDigest.sha256(payload),
            sourceIdentities: sources, profileDigests: decision.stages.compactMap { $0.modelProfile?.configurationDigest })
    }
}

public struct StageTelemetry: Codable, Equatable, Sendable {
    public var stageIndex: Int
    public var kind: PipelineStageKind
    public var requestedModelID: String?
    public var actualModelID: String?
    public var profileID: String?
    public var wallMilliseconds: Double
    public var queueMilliseconds: Double?
    public var loadMilliseconds: Double?
    public var firstTokenMilliseconds: Double?
    public var inferenceMilliseconds: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var tokensPerSecond: Double?
    public var peakMemoryBytes: Int64?
    public var estimatedActiveMemoryBytes: Int64?
    public var cacheHit: Bool?
    public var retries: Int
    public var fallback: String?
    public var reused: Bool
}

public struct ExecutionTelemetry: Codable, Equatable, Sendable {
    /// Cumulative active execution time; excludes downtime between attempts.
    public var wallMilliseconds: Double
    public var attemptWallMilliseconds: Double
    public var endToEndAgeMilliseconds: Double
    public var stages: [StageTelemetry]
    public var cancellationRequested: Bool
    public var unknownMetrics: [String]
}

public enum PipelineEvent: Sendable, Equatable {
    case stageStarted(PipelineStageKind, String?)
    case fallback(PipelineStageKind, from: String, to: String, reason: String)
    case stageCompleted(PipelineStageKind, artifactID: UUID, milliseconds: Double)
    case stageReused(PipelineStageKind, artifactID: UUID)
    case modelLoaded(String, milliseconds: Double)
    case modelUnloaded(String)
}

public struct ExecutionCheckpoint: Codable, Equatable, Sendable {
    public var decision: RoutingDecision
    public var artifacts: [PipelineArtifact]
    public var actualModelIDs: [String]
    public var fallbacks: [String]
    public var startedAt: Date
    public var completedStageCount: Int
    public var context: CheckpointContext?
    public var stageTelemetry: [StageTelemetry]?
    public var artifactDigests: [String]?
    public var activeExecutionMilliseconds: Double?
}

public struct ExecutionTrace: Codable, Equatable, Sendable {
    public var decision: RoutingDecision
    public var artifacts: [PipelineArtifact]
    public var actualModelIDs: [String]
    public var fallbacks: [String]
    public var startedAt: Date
    public var completedAt: Date
    public var telemetry: ExecutionTelemetry?
}

public enum ResourceError: LocalizedError {
    case runtimeUnavailable(InferenceBackend)
    case modelMissing(String)
    case memoryBudgetExceeded(modelID: String)
    case allFallbacksFailed(stage: PipelineStageKind, errors: [String])
    case malformedStructuredOutput(String)
    case stageTimedOut(PipelineStageKind)
    case staleCheckpoint([String])
    public var errorDescription: String? {
        switch self {
        case .runtimeUnavailable(let backend): "No local runtime is installed for \(backend.rawValue)."
        case .modelMissing(let id): "The routed model disappeared from the registry: \(id)."
        case .memoryBudgetExceeded(let id): "Model \(id) cannot fit after unloading idle models."
        case .allFallbacksFailed(let stage, let errors): "Every candidate failed for \(stage.rawValue): \(errors.joined(separator: "; "))."
        case .malformedStructuredOutput(let id): "Model \(id) twice produced invalid structured output."
        case .stageTimedOut(let stage): "Stage \(stage.rawValue) exceeded its timeout."
        case .staleCheckpoint(let reasons): "Checkpoint rejected as stale: \(reasons.joined(separator: "; "))."
        }
    }
}

public actor ModelResourceManager {
    private struct Residency { var lastUsed: Date; var activeRequests: Int }
    private var registry: ModelRegistry
    private let runtimes: [InferenceBackend: any ModelRuntime]
    private var resident: [String: Residency] = [:]
    private var loading: [String: Task<Void, Error>] = [:]
    private var reservedMemory: [String: Int64] = [:]
    public let memoryBudgetBytes: Int64
    public var stageTimeout: Duration

    public init(registry: ModelRegistry, runtimes: [InferenceBackend: any ModelRuntime], memoryBudgetBytes: Int64,
                stageTimeout: Duration = .seconds(600)) {
        self.registry = registry; self.runtimes = runtimes; self.memoryBudgetBytes = memoryBudgetBytes; self.stageTimeout = stageTimeout
    }

    public func snapshot(totalMemoryBytes: Int64) -> MachineResources {
        let used = resident.keys.compactMap { registry.model(id: $0)?.approximateMemoryBytes }.reduce(0, +) + reservedMemory.values.reduce(0, +)
        let reclaimable = resident.compactMap { id, state in state.activeRequests == 0 ? registry.model(id: id)?.approximateMemoryBytes : nil }.reduce(0, +)
        return MachineResources(totalMemoryBytes: totalMemoryBytes, availableMemoryBytes: max(0, memoryBudgetBytes - used),
                                loadedModelIDs: Set(resident.keys), reclaimableMemoryBytes: reclaimable)
    }

    public func registeredModels() -> [RegisteredModel] { registry.models }

    public func execute(decision: RoutingDecision, request: InferenceRequest,
                        resumeFrom checkpoint: ExecutionCheckpoint? = nil,
                        checkpointContext suppliedContext: CheckpointContext? = nil,
                        onEvent: (@Sendable (PipelineEvent) async -> Void)? = nil,
                        onCheckpoint: (@Sendable (ExecutionCheckpoint) async -> Void)? = nil) async throws -> ExecutionTrace {
        let context = try suppliedContext ?? CheckpointContext.make(request: request, decision: decision)
        let attemptStarted = Date()
        let started = checkpoint?.startedAt ?? attemptStarted
        var activeExecutionMilliseconds = checkpoint?.activeExecutionMilliseconds ?? 0
        var artifacts = checkpoint?.artifacts ?? []
        var actual = checkpoint?.actualModelIDs ?? []
        var fallbacks = checkpoint?.fallbacks ?? []
        var metrics = checkpoint?.stageTelemetry ?? []
        var firstStage = 0
        if let checkpoint {
            var stale: [String] = []
            if checkpoint.context == nil { stale.append("legacy checkpoint has no validity context") }
            if checkpoint.context?.schemaVersion != context.schemaVersion { stale.append("schema version changed") }
            if checkpoint.context?.pipelineVersion != context.pipelineVersion { stale.append("pipeline version changed") }
            if checkpoint.context?.preprocessingVersion != context.preprocessingVersion { stale.append("preprocessing version changed") }
            if checkpoint.context?.configurationDigest != context.configurationDigest { stale.append("request, route, profile, or relevant configuration changed") }
            let priorSources = checkpoint.context?.sourceIdentities ?? []
            let sourcesMatch = priorSources.count == context.sourceIdentities.count && zip(priorSources, context.sourceIdentities).allSatisfy {
                $0.path == $1.path && $0.byteCount == $1.byteCount && $0.digest == $1.digest
            }
            if !sourcesMatch { stale.append("source identity or content changed") }
            if checkpoint.completedStageCount < 0 || checkpoint.completedStageCount > decision.stages.count || checkpoint.artifacts.count != checkpoint.completedStageCount {
                stale.append("completed stage/artifact count is inconsistent")
            }
            let expectedDigests = checkpoint.artifactDigests ?? []
            let actualDigests = Self.artifactDigests(checkpoint.artifacts, context: context)
            if expectedDigests.count != checkpoint.completedStageCount || expectedDigests != actualDigests {
                stale.append("checkpoint artifact integrity chain is missing or invalid")
            }
            if checkpoint.actualModelIDs.count > checkpoint.completedStageCount || (checkpoint.stageTelemetry?.count ?? 0) < checkpoint.completedStageCount {
                stale.append("model or telemetry counts are inconsistent")
            }
            guard stale.isEmpty else { throw ResourceError.staleCheckpoint(stale) }
            firstStage = checkpoint.completedStageCount
            for index in 0..<firstStage {
                await onEvent?(.stageReused(decision.stages[index].kind, artifactID: artifacts[index].id))
                if let metricIndex = metrics.firstIndex(where: { $0.stageIndex == index }) {
                    metrics[metricIndex].reused = true; metrics[metricIndex].cacheHit = true
                } else {
                    metrics.append(StageTelemetry(stageIndex: index, kind: decision.stages[index].kind,
                        requestedModelID: decision.stages[index].modelID, actualModelID: nil,
                        profileID: decision.stages[index].modelProfile?.qualifiedID, wallMilliseconds: 0,
                        queueMilliseconds: nil, loadMilliseconds: nil, firstTokenMilliseconds: nil,
                        inferenceMilliseconds: nil, inputTokens: nil, outputTokens: nil, tokensPerSecond: nil,
                        peakMemoryBytes: nil, estimatedActiveMemoryBytes: nil, cacheHit: true, retries: 0,
                        fallback: nil, reused: true))
                }
            }
        }
        for stageIndex in firstStage..<decision.stages.count {
            try Task.checkCancellation()
            let stage = decision.stages[stageIndex]
            await onEvent?(.stageStarted(stage.kind, stage.modelID))
            let stageStarted = Date()
            do {
                let result = try await executeStage(stage, request: request, artifacts: artifacts,
                                                    isFinal: stageIndex == decision.stages.count - 1, onEvent: onEvent)
                let elapsed = Date().timeIntervalSince(stageStarted) * 1000
                activeExecutionMilliseconds += elapsed
                artifacts.append(result.artifact); if let id = result.modelID { actual.append(id) }
                if let fallback = result.fallback { fallbacks.append(fallback) }
                let modelMemory = result.modelID.flatMap { registry.model(id: $0)?.approximateMemoryBytes }
                metrics.append(StageTelemetry(stageIndex: stageIndex, kind: stage.kind,
                    requestedModelID: stage.modelID, actualModelID: result.modelID,
                    profileID: result.actualProfileID, wallMilliseconds: elapsed,
                    queueMilliseconds: nil, loadMilliseconds: result.loadMilliseconds, firstTokenMilliseconds: nil,
                    inferenceMilliseconds: max(0, elapsed - (result.loadMilliseconds ?? 0)),
                    inputTokens: Int(result.artifact.metadata["input_tokens"] ?? ""),
                    outputTokens: Int(result.artifact.metadata["output_tokens"] ?? ""),
                    tokensPerSecond: Double(result.artifact.metadata["tokens_per_second"] ?? ""),
                    peakMemoryBytes: Int64(result.artifact.metadata["peak_memory_bytes"] ?? ""),
                    estimatedActiveMemoryBytes: modelMemory, cacheHit: result.cacheHit, retries: result.retries,
                    fallback: result.fallback, reused: false))
                await onCheckpoint?(ExecutionCheckpoint(decision: decision, artifacts: artifacts, actualModelIDs: actual,
                    fallbacks: fallbacks, startedAt: started, completedStageCount: stageIndex + 1,
                    context: context, stageTelemetry: metrics, artifactDigests: Self.artifactDigests(artifacts, context: context),
                    activeExecutionMilliseconds: activeExecutionMilliseconds))
            } catch {
                let elapsed = Date().timeIntervalSince(stageStarted) * 1000
                activeExecutionMilliseconds += elapsed
                metrics.append(StageTelemetry(stageIndex: stageIndex, kind: stage.kind,
                    requestedModelID: stage.modelID, actualModelID: nil, profileID: nil,
                    wallMilliseconds: elapsed, queueMilliseconds: nil, loadMilliseconds: nil,
                    firstTokenMilliseconds: nil, inferenceMilliseconds: nil, inputTokens: nil, outputTokens: nil,
                    tokensPerSecond: nil, peakMemoryBytes: nil, estimatedActiveMemoryBytes: nil,
                    cacheHit: nil, retries: 0, fallback: "failed: \(error.localizedDescription)", reused: false))
                await onCheckpoint?(ExecutionCheckpoint(decision: decision, artifacts: artifacts, actualModelIDs: actual,
                    fallbacks: fallbacks, startedAt: started, completedStageCount: stageIndex,
                    context: context, stageTelemetry: metrics, artifactDigests: Self.artifactDigests(artifacts, context: context),
                    activeExecutionMilliseconds: activeExecutionMilliseconds))
                throw error
            }
        }
        let completed = Date()
        return ExecutionTrace(decision: decision, artifacts: artifacts, actualModelIDs: actual, fallbacks: fallbacks,
            startedAt: started, completedAt: completed,
            telemetry: ExecutionTelemetry(wallMilliseconds: activeExecutionMilliseconds,
                attemptWallMilliseconds: completed.timeIntervalSince(attemptStarted) * 1000,
                endToEndAgeMilliseconds: completed.timeIntervalSince(started) * 1000,
                stages: metrics.sorted { $0.stageIndex < $1.stageIndex }, cancellationRequested: Task.isCancelled,
                unknownMetrics: ["queue latency", "first-token latency", "exact Metal/KV memory" ]))
    }

    private static func artifactDigests(_ artifacts: [PipelineArtifact], context: CheckpointContext) -> [String] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var prior = context.configurationDigest
        return artifacts.enumerated().map { index, artifact in
            let encoded = (try? encoder.encode(artifact)) ?? Data()
            let digest = StableDigest.sha256(Data("\(prior):\(index):".utf8) + encoded)
            prior = digest; return digest
        }
    }

    public func unloadIdle(olderThan cutoff: Date, onEvent: (@Sendable (PipelineEvent) async -> Void)? = nil) async {
        let ids = resident.filter { $0.value.activeRequests == 0 && $0.value.lastUsed < cutoff }.map(\.key)
        for id in ids { await unload(id: id, onEvent: onEvent) }
    }

    public func shutdown(onEvent: (@Sendable (PipelineEvent) async -> Void)? = nil) async {
        for task in loading.values { task.cancel() }
        loading.removeAll(); reservedMemory.removeAll()
        for id in Array(resident.keys) { await unload(id: id, onEvent: onEvent) }
    }

    private func executeStage(_ stage: RouteStage, request: InferenceRequest, artifacts: [PipelineArtifact], isFinal: Bool,
                              onEvent: (@Sendable (PipelineEvent) async -> Void)?) async throws -> (artifact: PipelineArtifact, modelID: String?, actualProfileID: String?, fallback: String?, loadMilliseconds: Double?, cacheHit: Bool?, retries: Int) {
        if stage.kind == .validation, stage.validationContract == "construction-json-arithmetic-v1", let artifact = DeterministicClaimValidator.validateMultiImage(artifacts) {
            let start = Date()
            await onEvent?(.stageCompleted(stage.kind, artifactID: artifact.id, milliseconds: Date().timeIntervalSince(start) * 1000))
            return (artifact, nil, nil, nil, nil, true, 0)
        }
        guard let preferred = stage.modelID else {
            guard let runtime = runtimes[stage.backend] else { throw ResourceError.runtimeUnavailable(stage.backend) }
            let start = Date()
            let artifact = try await timed(stage.kind) { try await runtime.execute(model: nil, stage: stage, input: StageExecutionInput(request: request, artifacts: artifacts, requiresStructuredOutput: false)) }
            await onEvent?(.stageCompleted(stage.kind, artifactID: artifact.id, milliseconds: Date().timeIntervalSince(start) * 1000))
            return (artifact, nil, nil, nil, nil, true, 0)
        }
        let ids = [preferred] + stage.fallbackModelIDs
        var errors: [String] = []
        for (index, id) in ids.enumerated() {
            guard let model = registry.model(id: id) else { errors.append("\(id): missing"); continue }
            guard let runtime = runtimes[model.backend] else { errors.append("\(id): runtime unavailable"); continue }
            let candidateStage: RouteStage = {
                var value = stage
                if value.modelProfile?.baseModelID != model.id { value.modelProfile = nil }
                return value
            }()
            do {
                let loadResult = try await ensureLoaded(model, runtime: runtime, onEvent: onEvent)
                resident[id]?.activeRequests += 1
                defer { resident[id]?.activeRequests -= 1; resident[id]?.lastUsed = Date() }
                let start = Date()
                var retryCount = 0
                var artifact = try await timed(stage.kind) { try await runtime.execute(model: model, stage: candidateStage, input: StageExecutionInput(request: request, artifacts: artifacts, requiresStructuredOutput: request.requiresStructuredOutput && isFinal)) }
                if request.requiresStructuredOutput && isFinal {
                    if let normalized = normalizedJSON(artifact.content) {
                        artifact.content = normalized
                    } else {
                        retryCount += 1
                        artifact = try await timed(stage.kind) { try await runtime.execute(model: model, stage: candidateStage, input: StageExecutionInput(request: request, artifacts: artifacts, requiresStructuredOutput: true)) }
                        guard let normalized = normalizedJSON(artifact.content) else { throw ResourceError.malformedStructuredOutput(id) }
                        artifact.content = normalized
                    }
                }
                if index > 0 { await onEvent?(.fallback(stage.kind, from: preferred, to: id, reason: errors.last ?? "preferred candidate failed")) }
                await onEvent?(.stageCompleted(stage.kind, artifactID: artifact.id, milliseconds: Date().timeIntervalSince(start) * 1000))
                return (artifact, id, candidateStage.modelProfile?.qualifiedID,
                    index > 0 ? "\(preferred) → \(id)" : nil, loadResult.milliseconds, loadResult.cacheHit, retryCount + index)
            } catch {
                errors.append("\(id): \(error.localizedDescription)")
                if resident[id]?.activeRequests == 0 { await unload(id: id, onEvent: onEvent) }
            }
        }
        throw ResourceError.allFallbacksFailed(stage: stage.kind, errors: errors)
    }

    private func ensureLoaded(_ model: RegisteredModel, runtime: any ModelRuntime,
                              onEvent: (@Sendable (PipelineEvent) async -> Void)?) async throws -> (milliseconds: Double, cacheHit: Bool) {
        if resident[model.id] != nil { resident[model.id]?.lastUsed = Date(); return (0, true) }
        if let inFlight = loading[model.id] {
            let waitStarted = Date()
            try await inFlight.value
            if resident[model.id] == nil {
                resident[model.id] = Residency(lastUsed: Date(), activeRequests: 0)
                var loadedModel = model; loadedModel.loadedState = .loaded; loadedModel.health = .healthy; registry.upsert(loadedModel)
                reservedMemory.removeValue(forKey: model.id); loading.removeValue(forKey: model.id)
                await onEvent?(.modelLoaded(model.id, milliseconds: 0))
            }
            return (Date().timeIntervalSince(waitStarted) * 1000, false)
        }
        while residentMemory() + reservedMemory.values.reduce(0, +) + model.approximateMemoryBytes > memoryBudgetBytes {
            guard let victim = resident.filter({ $0.value.activeRequests == 0 }).min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key else {
                throw ResourceError.memoryBudgetExceeded(modelID: model.id)
            }
            await unload(id: victim, onEvent: onEvent)
        }
        reservedMemory[model.id] = model.approximateMemoryBytes
        var loadingModel = model; loadingModel.loadedState = .loading; registry.upsert(loadingModel)
        let start = Date()
        let task = Task { try await runtime.load(model: model) }
        loading[model.id] = task
        do {
            try await task.value
            if resident[model.id] == nil {
                resident[model.id] = Residency(lastUsed: Date(), activeRequests: 0)
                var loadedModel = model; loadedModel.loadedState = .loaded; loadedModel.health = .healthy; registry.upsert(loadedModel)
                await onEvent?(.modelLoaded(model.id, milliseconds: Date().timeIntervalSince(start) * 1000))
            }
            loading.removeValue(forKey: model.id); reservedMemory.removeValue(forKey: model.id)
            return (Date().timeIntervalSince(start) * 1000, false)
        } catch {
            loading.removeValue(forKey: model.id); reservedMemory.removeValue(forKey: model.id)
            var failedModel = model; failedModel.loadedState = .failed; failedModel.health = .degraded; registry.upsert(failedModel)
            throw error
        }
    }

    private func unload(id: String, onEvent: (@Sendable (PipelineEvent) async -> Void)?) async {
        guard let model = registry.model(id: id), let runtime = runtimes[model.backend], resident[id]?.activeRequests == 0 else { return }
        resident.removeValue(forKey: id); await runtime.unload(model: model)
        var unloadedModel = model; unloadedModel.loadedState = .unloaded; registry.upsert(unloadedModel)
        await onEvent?(.modelUnloaded(id))
    }
    private func residentMemory() -> Int64 { resident.keys.compactMap { registry.model(id: $0)?.approximateMemoryBytes }.reduce(0, +) }
    private func normalizedJSON(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil { return trimmed }
        guard let start = trimmed.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = trimmed.lastIndex(where: { $0 == "}" || $0 == "]" }), start <= end else { return nil }
        let candidate = String(trimmed[start...end])
        guard let data = candidate.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
        return candidate
    }
    private func timed<T: Sendable>(_ kind: PipelineStageKind, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask { try await Task.sleep(for: self.stageTimeout); throw ResourceError.stageTimedOut(kind) }
            guard let first = try await group.next() else { throw ResourceError.stageTimedOut(kind) }
            group.cancelAll(); return first
        }
    }
}
