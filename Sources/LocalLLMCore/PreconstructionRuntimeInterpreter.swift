import Foundation

public enum PreconRuntimeError: Error, Equatable, LocalizedError {
    case unsupported(String), unavailable(String), resourceRefused(String), runtimeFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason), .unavailable(let reason), .resourceRefused(let reason), .runtimeFailed(let reason): reason
        }
    }
}


/// One waiter owns this race, not the manager's shared load.
private final class InterpretationExecutionWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ExecutionTrace, Error>?
    private var task: Task<Void, Never>?
    private var result: Result<ExecutionTrace, Error>?

    func install(_ continuation: CheckedContinuation<ExecutionTrace, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func install(_ task: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished { self.task = task }
        lock.unlock()
        if finished { task.cancel() }
    }
    func finish(_ result: Result<ExecutionTrace, Error>, cancel: Bool = false) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation, task = self.task
        self.continuation = nil; self.task = nil
        lock.unlock()
        if cancel { task?.cancel() }
        continuation?.resume(with: result)
    }
}

public struct PreconRuntimeInterpreter: Sendable {
    public let manager: ModelResourceManager
    public let textModelID: String?
    public let imageModelID: String?
    public let textProfile: ModelProfile?
    public let imageProfile: ModelProfile?

    public init(manager: ModelResourceManager, textModelID: String?, imageModelID: String? = nil,
                textProfile: ModelProfile? = nil, imageProfile: ModelProfile? = nil) {
        self.manager = manager; self.textModelID = textModelID; self.imageModelID = imageModelID
        self.textProfile = textProfile; self.imageProfile = imageProfile
    }

    public func profileDigest() async throws -> String {
        let models = await manager.registeredModels()
        let selected = [(textModelID, textProfile), (imageModelID, imageProfile)]
        let parts = try selected.map { id, profile -> String in
            guard let id else { return "none" }
            guard let model = models.first(where: { $0.id == id }) else { throw PreconRuntimeError.unavailable("Unknown model \(id)") }
            if let profile, profile.baseModelID != id { throw PreconRuntimeError.unsupported("Profile does not belong to \(id)") }
            return [id, model.backend.rawValue, profile?.configurationDigest ?? "default"].joined(separator: "|")
        }
        return StableDigest.sha256(try JSONEncoder().encode(parts))
    }

    public func pipeline(store: PreconProjectStore, project: URL) async throws -> InterpretationPipeline {
        var pipeline = InterpretationPipeline(store: store, project: project, interpreter: interpret)
        pipeline.profileDigest = try await profileDigest()
        return pipeline
    }

    public func interpret(_ input: InterpretationRequest) async throws -> String {
        try Task.checkCancellation()
        let imageStage = input.stage != .nativeText
        guard let id = imageStage ? imageModelID : textModelID else {
            if imageStage { throw PreconRuntimeError.unsupported("No image model selected for \(input.stage.rawValue)") }
            throw PreconRuntimeError.unavailable("No text model selected")
        }
        let models = await manager.registeredModels()
        guard let model = models.first(where: { $0.id == id }), model.health != .unavailable, model.health != .failed else {
            throw PreconRuntimeError.unavailable("Model \(id) is missing or unhealthy")
        }
        let capability: Capability = input.stage == .ocr ? .ocr : input.stage == .vision ? .vision : .reasoning
        let modality: Modality = imageStage ? .image : .text
        guard model.capabilities.contains(capability), model.inputModalities.contains(modality), model.supportsStructuredOutput else {
            throw PreconRuntimeError.unsupported("Model \(id) cannot provide structured \(input.stage.rawValue) output")
        }
        var profile = imageStage ? imageProfile : textProfile
        if let profile, profile.baseModelID != id { throw PreconRuntimeError.unsupported("Profile does not belong to \(id)") }
        if profile == nil {
            profile = ModelProfile(id: "precon-default", version: "1", baseModelID: id,
                                   taskClasses: [.structuredExtraction], capabilities: [capability],
                                   createdAt: Date(timeIntervalSince1970: 0))
        }
        profile?.generation.maxOutputTokens = input.maxOutputTokens
        var effectivePrompt = ""
        if let system = profile?.systemPrompt, !system.isEmpty { effectivePrompt += system + "\n\n" }
        if let instruction = profile?.taskInstruction, !instruction.isEmpty { effectivePrompt += instruction + "\n\n" }
        if let examples = profile?.fewShotExamples, !examples.isEmpty {
            effectivePrompt += "Examples:\n" + examples.joined(separator: "\n---\n") + "\n\n"
        }
        if input.stage == .ocr { effectivePrompt += "Extract the text content from this image.\n\n" }
        effectivePrompt += input.instruction + "\n" + (input.text ?? "") + "\nReturn only valid JSON."
        // ponytail: mirrors RouterRuntimes.swift:121,206-237; share prompt/threshold policy if that backend changes.
        if model.backend == .mlxLM, effectivePrompt.count > max(8_000, model.contextWindow * 3) {
            throw PreconRuntimeError.unsupported("Effective prompt exceeds the single-call backend limit; shorten the profile or input")
        }
        let snapshot = await manager.snapshot(totalMemoryBytes: 0)
        if !snapshot.loadedModelIDs.contains(id), model.approximateMemoryBytes > snapshot.availableMemoryBytes {
            throw PreconRuntimeError.resourceRefused("Model \(id) needs about \(model.approximateMemoryBytes) bytes; headroom is \(snapshot.availableMemoryBytes)")
        }
        var attachments: [RequestAttachment] = []
        if imageStage {
            guard let image = input.image, image.isFileURL else { throw PreconRuntimeError.unsupported("Missing local page PNG") }
            attachments = [RequestAttachment(url: image, modality: .image, mimeType: "image/png")]
        }
        let request = InferenceRequest(text: input.instruction + "\n" + (input.text ?? ""), attachments: attachments,
                                       requiresStructuredOutput: true, localOnly: true, forcedModelID: id)
        let kind: PipelineStageKind = input.stage == .ocr ? .ocr : input.stage == .vision ? .visionExtraction : .reasoning
        let stage = RouteStage(kind: kind, modelID: id, backend: model.backend, requiredCapabilities: [capability],
                               inputModalities: [modality], modelProfile: profile)
        let requirements = TaskRequirements(category: .structuredExtraction, requiredCapabilities: [capability],
                                            inputModalities: [modality], requiresStructuredOutput: true)
        let decision = RoutingDecision(requestID: request.id, requirements: requirements, stages: [stage],
                                       reason: "Explicit preconstruction model selection")
        do {
            let wait = InterpretationExecutionWait()
            // ponytail: cancel this waiter promptly, not the shared cold load; runtime entry may still occur
            // after loading and must honor cancellation. Idle-load reclamation remains the manager's policy.
            let trace = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    wait.install(continuation)
                    let execution = Task {
                        do {
                            try Task.checkCancellation()
                            let trace = try await manager.execute(decision: decision, request: request)
                            wait.finish(.success(trace))
                        } catch { wait.finish(.failure(error)) }
                    }
                    wait.install(execution)
                }
            } onCancel: {
                wait.finish(.failure(CancellationError()), cancel: true)
            }
            try Task.checkCancellation()
            guard let artifact = trace.artifacts.last else { throw PreconRuntimeError.runtimeFailed("No artifact returned") }
            return artifact.content
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            // ponytail: execute wraps underlying admission/runtime errors; preserve the reason, not a guessed subtype.
            throw PreconRuntimeError.runtimeFailed(String(describing: error))
        }
    }
}
