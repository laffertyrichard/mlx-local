import Foundation

public enum PreconRuntimeError: Error, Equatable, LocalizedError {
    case unsupported(String), unavailable(String), resourceRefused(String), runtimeFailed(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let reason), .unavailable(let reason), .resourceRefused(let reason), .runtimeFailed(let reason): reason
        }
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

    /// Advisory only; execute remains the authority if another request changes headroom.
    public func admissionReason() async -> String? {
        let models = await manager.registeredModels()
        let snapshot = await manager.snapshot(totalMemoryBytes: 0)
        for id in [textModelID, imageModelID].compactMap({ $0 }) {
            guard let model = models.first(where: { $0.id == id }) else { return "Unknown model \(id)" }
            if !snapshot.loadedModelIDs.contains(id), model.approximateMemoryBytes > snapshot.availableMemoryBytes {
                return "Model \(id) needs about \(model.approximateMemoryBytes) bytes; headroom is \(snapshot.availableMemoryBytes)"
            }
        }
        return nil
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
            let trace = try await manager.execute(decision: decision, request: request)
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
