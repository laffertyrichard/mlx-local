import Foundation
import LocalLLMCore

struct EvaluationFailure: Error, CustomStringConvertible { let description: String }
func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    guard condition() else { throw EvaluationFailure(description: "FAIL: \(name)") }
    print("PASS: \(name)")
}
func checkThrows(_ name: String, _ operation: () throws -> Void) throws {
    do { try operation(); throw EvaluationFailure(description: "FAIL: \(name) did not throw") }
    catch is EvaluationFailure { throw EvaluationFailure(description: "FAIL: \(name) did not throw") }
    catch { print("PASS: \(name) [\(error.localizedDescription)]") }
}
func model(_ id: String, backend: InferenceBackend = .mlxLM, caps: Set<Capability>,
           modalities: Set<Modality> = [.text], memory: Int64 = 1_000,
           health: ModelHealth = .healthy) -> RegisteredModel {
    RegisteredModel(id: id, backend: backend, localPath: URL(filePath: "/tmp/\(id)"), family: "eval",
                    capabilities: caps, inputModalities: modalities, approximateMemoryBytes: memory,
                    supportsStructuredOutput: true, health: health)
}

actor MockRuntime: ModelRuntime {
    nonisolated let backend: InferenceBackend
    var loadFailures: Set<String>; var outputs: [String: [String]]; var loads: [String] = []; var unloads: [String] = []
    var executedProfileIDs: [String?] = []
    init(backend: InferenceBackend = .mlxLM, loadFailures: Set<String> = [], outputs: [String: [String]] = [:]) {
        self.backend = backend; self.loadFailures = loadFailures; self.outputs = outputs
    }
    func load(model: RegisteredModel) async throws { loads.append(model.id); if loadFailures.contains(model.id) { throw CocoaError(.fileReadUnknown) } }
    func unload(model: RegisteredModel) async { unloads.append(model.id) }
    func execute(model: RegisteredModel?, stage: RouteStage, input: StageExecutionInput) async throws -> PipelineArtifact {
        executedProfileIDs.append(stage.modelProfile?.qualifiedID)
        let id = model?.id ?? "native"; var values = outputs[id] ?? ["ok"]; let value = values.removeFirst(); outputs[id] = values.isEmpty ? [value] : values
        if value == "__FAIL__" { throw CocoaError(.fileReadUnknown) }
        return PipelineArtifact(kind: stage.kind == .transcription ? .transcript : .finalResponse, content: value)
    }
    func health(model: RegisteredModel) async -> ModelHealth { .healthy }
    func recordedUnloads() -> [String] { unloads }
    func recordedLoads() -> [String] { loads }
    func recordedProfiles() -> [String?] { executedProfileIDs }
}

actor CheckpointRecorder {
    var checkpoints: [ExecutionCheckpoint] = []
    func append(_ checkpoint: ExecutionCheckpoint) { checkpoints.append(checkpoint) }
    func last() -> ExecutionCheckpoint? { checkpoints.last }
}

actor SlowRuntime: ModelRuntime {
    nonisolated let backend: InferenceBackend = .mlxLM
    var loadCount = 0
    func load(model: RegisteredModel) async throws { loadCount += 1; try await Task.sleep(for: .milliseconds(100)) }
    func unload(model: RegisteredModel) async {}
    func execute(model: RegisteredModel?, stage: RouteStage, input: StageExecutionInput) async throws -> PipelineArtifact { PipelineArtifact(kind: .finalResponse, content: "ok") }
    func health(model: RegisteredModel) async -> ModelHealth { .healthy }
    func count() -> Int { loadCount }
}

struct CheapSemanticClassifier: SemanticTaskClassifying {
    func classify(_ request: InferenceRequest, baseline: TaskRequirements) async throws -> TaskRequirements {
        TaskRequirements(category: .reasoning, requiredCapabilities: [.reasoning], inputModalities: [.text], confidence: 0.9, evidence: ["cheap semantic signal"])
    }
}

@main struct RouterEvaluation {
    static func main() async throws {
        let classifier = TaskClassifier(), router = CapabilityRouter()
        let resources = MachineResources(totalMemoryBytes: 64_000, availableMemoryBytes: 50_000)
        let v1Config = ServerConfiguration(executable: URL(filePath: "/python"), launcherScript: URL(filePath: "/wrapper.py"), modelPath: URL(filePath: "/model"), port: 9876)
        try check(v1Config.arguments.prefix(3) == ["/wrapper.py", "--model", "/model"] && v1Config.endpoint.absoluteString == "http://127.0.0.1:9876/v1", "V1 local server command remains compatible")
        let cacheRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let snapshot = cacheRoot.appending(path: "models--org--Qwen/snapshots/abc"), blobs = cacheRoot.appending(path: "models--org--Qwen/blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"qwen\"}".utf8).write(to: snapshot.appending(path: "config.json")); try Data(repeating: 1, count: 10).write(to: snapshot.appending(path: "model.safetensors")); try Data(repeating: 1, count: 10).write(to: blobs.appending(path: "weights"))
        try check(ModelCatalog(cacheRoot: cacheRoot).discover().map(\.repository) == ["org/Qwen"], "V1 cached model discovery remains compatible")

        let coding = await classifier.classify(InferenceRequest(text: "Explain this Python traceback"))
        try check(coding.requiredCapabilities.isSuperset(of: [.coding, .reasoning]), "obvious coding classification")
        let scanURL = URL(filePath: "/tmp/plans.pdf"); try Data("mock".utf8).write(to: scanURL)
        let scan = RequestAttachment(url: scanURL, hasExtractableText: false)
        let scanned = await classifier.classify(InferenceRequest(text: "Extract every room dimension", attachments: [scan], requiresStructuredOutput: true))
        try check(scanned.requiredCapabilities.isSuperset(of: [.ocr, .documentUnderstanding, .structuredExtraction]), "scanned PDF classification")
        let images = ["a.png", "b.png", "c.png"].map { RequestAttachment(url: URL(filePath: "/tmp/\($0)")) }
        let compared = await classifier.classify(InferenceRequest(text: "Compare these elevations", attachments: images))
        try check(compared.requiredCapabilities.isSuperset(of: [.vision, .multiImageVision, .comparison, .reasoning]), "adversarial multi-image comparison")
        let audio = await classifier.classify(InferenceRequest(text: "Summarize this meeting recording", attachments: [RequestAttachment(url: URL(filePath: "/tmp/meeting.m4a"))]))
        try check(audio.requiredCapabilities.isSuperset(of: [.speechToText, .summarization, .reasoning]), "audio pipeline classification")
        let transcriptionOnly = await classifier.classify(InferenceRequest(text: "Transcribe this verbatim", attachments: [RequestAttachment(url: URL(filePath: "/tmp/meeting.m4a"))]))
        try check(transcriptionOnly.category == .transcription && transcriptionOnly.requiredCapabilities == [.speechToText], "plain transcription avoids unnecessary reasoning stage")
        let mixed = await classifier.classify(InferenceRequest(text: "Compare and summarize both", attachments: [RequestAttachment(url: URL(filePath: "/tmp/a.png")), RequestAttachment(url: URL(filePath: "/tmp/a.wav"))]))
        try check(mixed.category == .multimodal && mixed.requiredCapabilities.isSuperset(of: [.vision, .speechToText]), "mixed modalities retain every required capability")
        let photo = await classifier.classify(InferenceRequest(text: "What's wrong with the framing?", attachments: [RequestAttachment(url: URL(filePath: "/tmp/a.jpg"))]))
        try check(photo.requiredCapabilities.contains(.visualReasoning) && !photo.requiredCapabilities.contains(.ocr), "visual reasoning is not misrouted to OCR")
        let ambiguous = await TaskClassifier(semanticClassifier: CheapSemanticClassifier()).classify(InferenceRequest(text: "Handle this appropriately"))
        try check(ambiguous.category == .reasoning && ambiguous.evidence.contains(where: { $0.contains("semantic") }), "ambiguous task uses cheap semantic classifier")

        var fast = model("fast", caps: [.generalChat], memory: 5_000)
        fast.benchmarks = [CapabilityBenchmark(capability: .generalChat, quality: 0.6, tokensPerSecond: 100)]
        var good = model("good", caps: [.generalChat], memory: 5_000)
        good.benchmarks = [CapabilityBenchmark(capability: .generalChat, quality: 0.95, tokensPerSecond: 20)]
        let chatReq = TaskRequirements(category: .chat, requiredCapabilities: [.generalChat], inputModalities: [.text])
        var decision = try router.route(request: InferenceRequest(text: "hello", quality: .best), requirements: chatReq,
                                        registry: ModelRegistry(models: [fast, good]), resources: resources)
        try check(decision.selectedModelIDs == ["good"], "local benchmark quality influences route")
        let residentA = model("resident-a", caps: [.generalChat]), residentB = model("resident-b", caps: [.generalChat])
        decision = try router.route(request: InferenceRequest(text: "hello"), requirements: chatReq,
                                    registry: ModelRegistry(models: [residentA, residentB]),
                                    resources: MachineResources(totalMemoryBytes: 64_000, availableMemoryBytes: 50_000, loadedModelIDs: ["resident-b"]))
        try check(decision.selectedModelIDs == ["resident-b"], "resident model reuse influences route")
        decision = try router.route(request: InferenceRequest(text: "hello", forcedModelID: "fast"), requirements: chatReq,
                                    registry: ModelRegistry(models: [fast, good]), resources: resources)
        try check(decision.reason.contains("Manual override"), "manual mode forced override")
        try checkThrows("unavailable forced model") { _ = try router.route(request: InferenceRequest(text: "x", forcedModelID: "gone"), requirements: chatReq, registry: ModelRegistry(models: [fast]), resources: resources) }
        let unhealthy = model("unhealthy", caps: [.generalChat], health: .unavailable)
        try checkThrows("registered but unhealthy model") { _ = try router.route(request: InferenceRequest(text: "x", forcedModelID: "unhealthy"), requirements: chatReq, registry: ModelRegistry(models: [unhealthy]), resources: resources) }
        let imageReq = TaskRequirements(category: .imageUnderstanding, requiredCapabilities: [.vision], inputModalities: [.text, .image])
        try checkThrows("incompatible forced model") { _ = try router.route(request: InferenceRequest(text: "image", forcedModelID: "fast"), requirements: imageReq, registry: ModelRegistry(models: [fast]), resources: resources) }
        try checkThrows("unsupported modality") { _ = try router.route(request: InferenceRequest(text: "audio"), requirements: TaskRequirements(category: .transcription, requiredCapabilities: [.speechToText], inputModalities: [.audio, .text]), registry: ModelRegistry(models: [fast]), resources: resources) }
        let remote = InferenceRequest(text: "inspect", attachments: [RequestAttachment(url: URL(string: "https://example.com/a.png")!, modality: .image)])
        try checkThrows("local-only rejects remote attachment URL") { _ = try router.route(request: remote, requirements: imageReq, registry: ModelRegistry(models: [model("vision", backend: .mlxVLM, caps: [.vision], modalities: [.image])]), resources: resources) }
        try checkThrows("insufficient memory") { _ = try router.route(request: InferenceRequest(text: "x"), requirements: chatReq, registry: ModelRegistry(models: [model("huge", caps: [.generalChat], memory: 100_000)]), resources: resources) }

        let ocr = model("ocr", backend: .mlxVLM, caps: [.ocr, .documentUnderstanding, .structuredExtraction], modalities: [.text, .document, .image])
        let reasoner = model("reason", caps: [.reasoning])
        let scanReq = TaskRequirements(category: .scannedDocument, requiredCapabilities: [.ocr, .documentUnderstanding, .reasoning], inputModalities: [.text, .document])
        decision = try router.route(request: InferenceRequest(text: "analyze", attachments: [scan]), requirements: scanReq,
                                    registry: ModelRegistry(models: [ocr, reasoner]), resources: resources)
        try check(decision.stages.map(\.kind) == [.documentTextExtraction, .ocr, .reasoning], "multi-model scanned document pipeline")
        let jsonScanReq = TaskRequirements(category: .structuredExtraction, requiredCapabilities: [.ocr, .documentUnderstanding, .structuredExtraction], inputModalities: [.text, .document], requiresStructuredOutput: true)
        decision = try router.route(request: InferenceRequest(text: "return valid JSON", attachments: [scan], requiresStructuredOutput: true), requirements: jsonScanReq, registry: ModelRegistry(models: [ocr, reasoner]), resources: resources)
        try check(decision.stages.map(\.kind) == [.documentTextExtraction, .ocr, .reasoning], "scanned JSON route keeps OCR intermediate and terminal structuring stage")
        try check(decision.reason.contains("sequential"), "pipeline decision is inspectable")
        let multiRequirements = TaskRequirements(category: .comparison, requiredCapabilities: [.vision, .multiImageVision, .comparison, .reasoning], inputModalities: [.text, .image])
        let vision = model("vision", backend: .mlxVLM, caps: [.vision, .multiImageVision, .comparison, .reasoning], modalities: [.text, .image])
        decision = try router.route(request: InferenceRequest(text: "compare"), requirements: multiRequirements, registry: ModelRegistry(models: [vision, reasoner]), resources: resources)
        try check(decision.stages.map(\.kind) == [.visionExtraction, .reasoning, .validation], "multi-image comparisons use extraction, synthesis, and validation")
        let localText = URL(filePath: NSTemporaryDirectory()).appending(path: "router-eval.txt"); try "source".write(to: localText, atomically: true, encoding: .utf8)
        let manualDocument = InferenceRequest(text: "summarize", attachments: [RequestAttachment(url: localText)], forcedModelID: "reason")
        let manualDocumentReq = TaskRequirements(category: .documentAnalysis, requiredCapabilities: [.documentUnderstanding, .reasoning], inputModalities: [.text, .document])
        decision = try router.route(request: manualDocument, requirements: manualDocumentReq, registry: ModelRegistry(models: [reasoner]), resources: resources)
        try check(decision.stages.map(\.kind) == [.documentTextExtraction, .direct], "manual text model receives native document normalization")

        let preferred = model("preferred", caps: [.generalChat]), fallback = model("fallback", caps: [.generalChat])
        let runtime = MockRuntime(loadFailures: ["preferred"])
        var manager = ModelResourceManager(registry: ModelRegistry(models: [preferred, fallback]), runtimes: [.mlxLM: runtime], memoryBudgetBytes: 10_000)
        let preferredOnlyProfile = ModelProfile(id: "preferred-profile", version: "1", baseModelID: "preferred",
            taskClasses: [.chat], capabilities: [.generalChat], lifecycle: .current, systemPrompt: "preferred only")
        let fallbackStage = RouteStage(kind: .direct, modelID: "preferred", backend: .mlxLM, requiredCapabilities: [.generalChat], inputModalities: [.text], fallbackModelIDs: ["fallback"], modelProfile: preferredOnlyProfile)
        let fallbackDecision = RoutingDecision(requestID: UUID(), requirements: chatReq, stages: [fallbackStage], reason: "eval", warnings: [], scores: [:])
        var trace = try await manager.execute(decision: fallbackDecision, request: InferenceRequest(text: "hi"))
        let fallbackProfiles = await runtime.recordedProfiles()
        try check(trace.actualModelIDs == ["fallback"] && trace.fallbacks == ["preferred → fallback"] &&
                  trace.telemetry?.stages.first?.profileID == nil && fallbackProfiles.last! == nil,
                  "fallback uses default configuration and actual profile provenance")

        let a = model("a", caps: [.generalChat], memory: 7_000), b = model("b", caps: [.generalChat], memory: 7_000)
        let pressureRuntime = MockRuntime(); manager = ModelResourceManager(registry: ModelRegistry(models: [a, b]), runtimes: [.mlxLM: pressureRuntime], memoryBudgetBytes: 10_000)
        for id in ["a", "b"] {
            let s = RouteStage(kind: .direct, modelID: id, backend: .mlxLM, requiredCapabilities: [.generalChat], inputModalities: [.text])
            let d = RoutingDecision(requestID: UUID(), requirements: chatReq, stages: [s], reason: "", warnings: [], scores: [:])
            _ = try await manager.execute(decision: d, request: InferenceRequest(text: "hi"))
        }
        let recordedUnloads = await pressureRuntime.recordedUnloads()
        try check(recordedUnloads == ["a"], "memory pressure unloads idle model")

        let jsonRuntime = MockRuntime(outputs: ["a": ["not json", "still bad"], "b": ["{\"ok\":true}"]])
        manager = ModelResourceManager(registry: ModelRegistry(models: [a, b]), runtimes: [.mlxLM: jsonRuntime], memoryBudgetBytes: 10_000)
        let structuredStage = RouteStage(kind: .direct, modelID: "a", backend: .mlxLM, requiredCapabilities: [.generalChat], inputModalities: [.text], fallbackModelIDs: ["b"])
        let structuredDecision = RoutingDecision(requestID: UUID(), requirements: TaskRequirements(category: .structuredExtraction, requiredCapabilities: [.generalChat], inputModalities: [.text], requiresStructuredOutput: true), stages: [structuredStage], reason: "", warnings: [], scores: [:])
        trace = try await manager.execute(decision: structuredDecision, request: InferenceRequest(text: "json", requiresStructuredOutput: true))
        try check(trace.actualModelIDs == ["b"], "malformed structured output retries then falls back")

        let pipelineRuntime = MockRuntime(outputs: ["ocr-stage": ["plain OCR text"], "json-stage": ["{\"field\":\"value\"}"]])
        let ocrStageModel = model("ocr-stage", caps: [.generalChat]), jsonStageModel = model("json-stage", caps: [.generalChat])
        manager = ModelResourceManager(registry: ModelRegistry(models: [ocrStageModel, jsonStageModel]), runtimes: [.mlxLM: pipelineRuntime], memoryBudgetBytes: 10_000)
        let structuredPipeline = RoutingDecision(requestID: UUID(), requirements: TaskRequirements(category: .structuredExtraction, requiredCapabilities: [.generalChat], inputModalities: [.text], requiresStructuredOutput: true), stages: [
            RouteStage(kind: .ocr, modelID: "ocr-stage", backend: .mlxLM, requiredCapabilities: [], inputModalities: [.text]),
            RouteStage(kind: .reasoning, modelID: "json-stage", backend: .mlxLM, requiredCapabilities: [.generalChat], inputModalities: [.text])], reason: "structured pipeline")
        trace = try await manager.execute(decision: structuredPipeline, request: InferenceRequest(text: "return json", requiresStructuredOutput: true))
        try check(trace.artifacts.first?.content == "plain OCR text" && trace.artifacts.last?.content.contains("field") == true, "structured contract applies only to terminal pipeline stage")
        await manager.shutdown()

        let checkpointRuntime = MockRuntime(outputs: ["a": ["intermediate"], "b": ["__FAIL__"]])
        let recorder = CheckpointRecorder()
        manager = ModelResourceManager(registry: ModelRegistry(models: [a, b]), runtimes: [.mlxLM: checkpointRuntime], memoryBudgetBytes: 10_000)
        let failingPipeline = RoutingDecision(requestID: UUID(), requirements: chatReq, stages: [
            RouteStage(kind: .transcription, modelID: "a", backend: .mlxLM, requiredCapabilities: [], inputModalities: [.text]),
            RouteStage(kind: .reasoning, modelID: "b", backend: .mlxLM, requiredCapabilities: [.generalChat], inputModalities: [.text])], reason: "checkpoint")
        do { _ = try await manager.execute(decision: failingPipeline, request: InferenceRequest(text: "x"), onCheckpoint: { checkpoint in await recorder.append(checkpoint) }) } catch {}
        let partial = await recorder.last()
        try check(partial?.completedStageCount == 1 && partial?.artifacts.first?.content == "intermediate" &&
                  (partial?.activeExecutionMilliseconds ?? 0) > 0 && partial?.stageTelemetry?.contains(where: { $0.fallback?.hasPrefix("failed:") == true }) == true,
                  "completed artifact and failed-attempt active telemetry survive downstream failure")
        await manager.shutdown()

        let resumeRuntime = MockRuntime(outputs: ["b": ["resumed final"]])
        let resumedManager = ModelResourceManager(registry: ModelRegistry(models: [a, b]), runtimes: [.mlxLM: resumeRuntime], memoryBudgetBytes: 10_000)
        let resumed = try await resumedManager.execute(decision: failingPipeline, request: InferenceRequest(text: "x"), resumeFrom: partial)
        let resumeLoads = await resumeRuntime.recordedLoads()
        try check(resumed.artifacts.map(\.content) == ["intermediate", "resumed final"] && !resumeLoads.contains("a") && resumed.telemetry?.stages.first?.reused == true,
                  "real checkpoint resume reuses completed expensive stage")
        await resumedManager.shutdown()

        var staleRejected = false
        do { _ = try await resumedManager.execute(decision: failingPipeline, request: InferenceRequest(text: "changed"), resumeFrom: partial) }
        catch ResourceError.staleCheckpoint { staleRejected = true }
        try check(staleRejected, "stale checkpoint rejects changed request configuration")
        var historyRejected = false
        do { _ = try await resumedManager.execute(decision: failingPipeline,
            request: InferenceRequest(text: "x", history: [ConversationTurn(role: "user", content: "changed context")]), resumeFrom: partial) }
        catch ResourceError.staleCheckpoint { historyRejected = true }
        try check(historyRejected, "conversation history change invalidates checkpoint")
        var tampered = partial!
        tampered.artifacts[0].content = "poisoned"
        var tamperRejected = false
        do { _ = try await resumedManager.execute(decision: failingPipeline, request: InferenceRequest(text: "x"), resumeFrom: tampered) }
        catch ResourceError.staleCheckpoint { tamperRejected = true }
        try check(tamperRejected, "checkpoint artifact integrity tampering is rejected")

        let sourceRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        let sourceFile = sourceRoot.appending(path: "plan.txt"); try Data("v1".utf8).write(to: sourceFile)
        let sourceRequest = InferenceRequest(text: "inspect", attachments: [RequestAttachment(url: sourceFile, modality: .code)])
        let sourceDecision = RoutingDecision(requestID: sourceRequest.id, requirements: chatReq, stages: [RouteStage(kind: .direct, modelID: "a", backend: .mlxLM, requiredCapabilities: [.generalChat], inputModalities: [.text])], reason: "source")
        let sourceRecorder = CheckpointRecorder(), sourceRuntime = MockRuntime(outputs: ["a": ["saved"]])
        let sourceManager = ModelResourceManager(registry: ModelRegistry(models: [a]), runtimes: [.mlxLM: sourceRuntime], memoryBudgetBytes: 10_000)
        _ = try await sourceManager.execute(decision: sourceDecision, request: sourceRequest, onCheckpoint: { await sourceRecorder.append($0) })
        let sourceCheckpoint = await sourceRecorder.last(); try Data("v2".utf8).write(to: sourceFile)
        var sourceRejected = false
        do { _ = try await sourceManager.execute(decision: sourceDecision, request: sourceRequest, resumeFrom: sourceCheckpoint) }
        catch ResourceError.staleCheckpoint { sourceRejected = true }
        try check(sourceRejected, "source file content change invalidates checkpoint")
        await sourceManager.shutdown()

        let slowRuntime = SlowRuntime()
        manager = ModelResourceManager(registry: ModelRegistry(models: [a]), runtimes: [.mlxLM: slowRuntime], memoryBudgetBytes: 10_000)
        let concurrentStage = RouteStage(kind: .direct, modelID: "a", backend: .mlxLM, requiredCapabilities: [.generalChat], inputModalities: [.text])
        let concurrentDecision = RoutingDecision(requestID: UUID(), requirements: chatReq, stages: [concurrentStage], reason: "concurrent")
        async let first = manager.execute(decision: concurrentDecision, request: InferenceRequest(text: "one"))
        async let second = manager.execute(decision: concurrentDecision, request: InferenceRequest(text: "two"))
        _ = try await (first, second)
        let sharedLoadCount = await slowRuntime.count()
        try check(sharedLoadCount == 1, "concurrent requests share one model load")
        await manager.shutdown()

        let restartRuntime = MockRuntime()
        let restartedManager = ModelResourceManager(registry: ModelRegistry(models: [a]), runtimes: [.mlxLM: restartRuntime], memoryBudgetBytes: 10_000)
        let restartStage = RouteStage(kind: .direct, modelID: "a", backend: .mlxLM, requiredCapabilities: [.generalChat], inputModalities: [.text])
        let restartDecision = RoutingDecision(requestID: UUID(), requirements: chatReq, stages: [restartStage], reason: "restart")
        let restartTrace = try await restartedManager.execute(decision: restartDecision, request: InferenceRequest(text: "after restart"))
        try check(restartTrace.actualModelIDs == ["a"], "server and application manager restart")
        await restartedManager.shutdown()

        let baselineProfile = ModelProfile(id: "vision-default", version: "1", baseModelID: "vision",
            taskClasses: [.comparison], capabilities: [.vision], lifecycle: .current)
        let candidateProfile = ModelProfile(id: "vision-construction", version: "2", baseModelID: "vision",
            taskClasses: [.comparison], capabilities: [.vision], lifecycle: .candidate,
            systemPrompt: "Extract only observed construction facts.", generation: GenerationConfiguration(maxOutputTokens: 512))
        var profiles = ModelProfileRegistry(profiles: [baselineProfile, candidateProfile])
        let metric = ProfileMetrics(quality: 0.95, malformedOutputRate: 0, totalMilliseconds: 1_000, failures: 0, examples: 3)
        profiles.record(OptimizationExperiment(id: "heldout-1", taskClass: .comparison, datasetID: "plans", datasetVersion: "1",
            split: .heldOut, baselineProfileID: baselineProfile.qualifiedID, candidateProfileID: candidateProfile.qualifiedID,
            changedVariables: ["prompt", "max_output_tokens"], before: ProfileMetrics(quality: 0.8, examples: 3), after: metric,
            decision: .promote, rationale: "higher quality and lower latency", independentCaseCount: 3,
            evidenceDigest: "test-evidence", scorerVersion: "test-v1"))
        try profiles.promote(candidateProfile.qualifiedID)
        try check(profiles.profile(qualifiedID: candidateProfile.qualifiedID)?.lifecycle == .current && profiles.profile(qualifiedID: baselineProfile.qualifiedID)?.lifecycle == .retired,
                  "profile promotion requires held-out evidence and retires prior current")
        try profiles.rollback(retired: baselineProfile.qualifiedID)
        try check(profiles.profile(qualifiedID: baselineProfile.qualifiedID)?.lifecycle == .current, "profile rollback restores trusted baseline")

        let profileData = try Data(contentsOf: URL(filePath: FileManager.default.currentDirectoryPath).appending(path: "V3/model-profiles.json"))
        let profileDecoder = JSONDecoder(); profileDecoder.dateDecodingStrategy = .iso8601
        let installedProfiles = try profileDecoder.decode(ModelProfileRegistry.self, from: profileData)
        try check(installedProfiles.profiles.contains { $0.lifecycle == .current } && installedProfiles.experiments.contains { $0.split == .heldOut },
                  "versioned deployed profile registry decodes with held-out evidence")
        let localOnlyProfile = ModelProfile(id: "local-only", version: "1", baseModelID: "local", taskClasses: [], capabilities: [], lifecycle: .candidate)
        let mergedProfiles = ModelProfileRegistry.merged(shipped: installedProfiles,
            installed: ModelProfileRegistry(schemaVersion: 1, releaseVersion: 0, profiles: [localOnlyProfile]))
        try check(mergedProfiles.profile(qualifiedID: localOnlyProfile.qualifiedID) != nil &&
                  mergedProfiles.profiles.contains(where: { $0.lifecycle == .current }),
                  "profile release migration preserves installed-only state while deploying shipped profiles")

        var insufficient = ModelProfileRegistry(profiles: [candidateProfile])
        var blockedPromotion = false
        do { try insufficient.promote(candidateProfile.qualifiedID) } catch ProfileRegistryError.insufficientHeldOutEvidence { blockedPromotion = true }
        try check(blockedPromotion, "profile promotion rejects missing held-out evidence")

        let image1 = URL(filePath: "/tmp/a.png"), image2 = URL(filePath: "/tmp/b.png")
        let extraction = PipelineArtifact(kind: .visionObservations, content: "Room A 12'-6\" × 10'-0\"", sourceURLs: [image1, image2])
        let synthesis = PipelineArtifact(kind: .finalResponse, content: "Room A is 12'-6\" × 10'-0\", or 126 sq ft.")
        let validated = DeterministicClaimValidator.validateMultiImage([extraction, synthesis])
        try check(validated?.content.contains("125 sq ft") == true && validated?.metadata["corrections"] == "1",
                  "deterministic claim validator corrects multi-image arithmetic")
        let structuredArtifact = PipelineArtifact(kind: .visionObservations,
            content: #"{"rooms":[{"source_image":1,"label":"A","width_ft":2,"length_ft":3,"area_sq_ft":7,"uncertainty":null},{"source_image":2,"label":"B","width_ft":4,"length_ft":5,"area_sq_ft":20,"uncertainty":null}],"comparison":"B larger","provenance":{"kept":true},"warnings":[]}"#,
            sourceURLs: [image1, image2], confidence: 0.6)
        let structuredValidated = DeterministicClaimValidator.validateMultiImage([structuredArtifact])
        try check(structuredValidated?.content.contains("provenance") == true && structuredValidated?.content.contains("warnings") == true &&
                  structuredValidated?.confidence == nil && structuredValidated?.metadata["validation_scope"] == "area_arithmetic_only",
                  "construction validation preserves extra schema and does not overstate confidence")
        let genericValidationRuntime = MockRuntime(outputs: ["a": ["model validator result"]])
        let genericManager = ModelResourceManager(registry: ModelRegistry(models: [a]), runtimes: [.mlxLM: genericValidationRuntime], memoryBudgetBytes: 10_000)
        let genericStage = RouteStage(kind: .validation, modelID: "a", backend: .mlxLM, requiredCapabilities: [.generalChat], inputModalities: [.text])
        let genericDecision = RoutingDecision(requestID: UUID(), requirements: chatReq, stages: [genericStage], reason: "generic validation")
        let genericTrace = try await genericManager.execute(decision: genericDecision, request: InferenceRequest(text: "validate"))
        try check(genericTrace.artifacts.last?.content == "model validator result", "generic validation does not invoke construction validator")
        await genericManager.shutdown()

        let workflowRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: workflowRoot, withIntermediateDirectories: true)
        let allowed = workflowRoot.appending(path: "plan.pdf"); try Data("fixture".utf8).write(to: allowed)
        let audit = workflowRoot.appending(path: "audit/workflows.jsonl")
        let workflowExecutor = PermissionedWorkflowExecutor(auditURL: audit)
        let (descriptor, handler) = BuiltinWorkflows.localArtifactInspection(root: workflowRoot)
        await workflowExecutor.registerTrusted(descriptor, handler: handler)
        let workflowResult = try await workflowExecutor.execute(WorkflowInvocation(workflowID: descriptor.qualifiedID,
            input: ["instruction": "inventory"], requestedReads: [allowed]))
        try check(workflowResult.output["files"] == "1" && FileManager.default.fileExists(atPath: audit.path),
                  "permissioned local workflow returns provenance and audit log")
        var denied = false
        do { _ = try await workflowExecutor.execute(WorkflowInvocation(workflowID: descriptor.qualifiedID,
            input: [:], requestedReads: [URL(filePath: "/etc/hosts")])) }
        catch WorkflowAuthorizationError.readDenied { denied = true }
        try check(denied, "permissioned workflow denies out-of-scope file access")

        print("\nRouter evaluation passed: all checks")
    }
}
