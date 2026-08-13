import Foundation
import LocalInferenceBackends
import LocalLLMCore

@main struct ConstructionTracer {
    static func main() async throws {
        guard CommandLine.arguments.count >= 4 else {
            print("usage: swift run -c release ConstructionTracer <image-a> <image-b> <report.json>"); return
        }
        let root = URL(filePath: FileManager.default.currentDirectoryPath)
        let images = [URL(filePath: CommandLine.arguments[1]), URL(filePath: CommandLine.arguments[2])]
        let reportURL = URL(filePath: CommandLine.arguments[3])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let profileRegistry = try decoder.decode(ModelProfileRegistry.self, from: Data(contentsOf: root.appending(path: "V3/model-profiles.json")))
        guard let profile = profileRegistry.profiles.first(where: { $0.lifecycle == .current && $0.taskClasses.contains(.comparison) }) else {
            throw TracerError.missing("CURRENT construction comparison profile")
        }
        let registry = ModelRegistryDiscovery(benchmarkURL: root.appending(path: "Benchmarks/local-results.json"),
                                              profileURL: root.appending(path: "ModelMetadata/capabilities.json")).discover()
        guard let selectedModel = registry.model(id: profile.baseModelID) else { throw TracerError.missing(profile.baseModelID) }
        let request = InferenceRequest(text: "Compare both construction plan images with exact labels, dimensions, computed areas, provenance, and uncertainty.",
            attachments: images.map { RequestAttachment(url: $0) }, quality: .best, requiresStructuredOutput: true,
            structuredOutputSchema: #"{"rooms":[{"source_image":1,"label":"string","width_ft":0,"length_ft":0,"area_sq_ft":0,"uncertainty":null}],"comparison":"string"}"#)
        let extraction = RouteStage(kind: .visionExtraction, modelID: selectedModel.id, backend: selectedModel.backend,
            requiredCapabilities: [.vision, .multiImageVision], inputModalities: [.image], modelProfile: profile)
        let validation = RouteStage(kind: .validation, modelID: nil, backend: .nativeDocument,
            requiredCapabilities: [], inputModalities: [.text], validationContract: "construction-json-arithmetic-v1")
        let decision = RoutingDecision(requestID: request.id,
            requirements: TaskRequirements(category: .comparison, requiredCapabilities: [.vision, .multiImageVision, .comparison],
                inputModalities: [.image], requiresStructuredOutput: true), stages: [extraction, validation],
            reason: "Construction tracer: evaluated local vision profile followed by deterministic claim validation.")
        let context = try CheckpointContext.make(request: request, decision: decision,
            pipelineVersion: "construction-tracer-v1", preprocessingVersion: profile.preprocessing.version,
            relevantConfiguration: ["boundary": "hybrid", "validator": "construction-json-arithmetic-v1"])
        let total = Int64(ProcessInfo.processInfo.physicalMemory), budget = Int64(Double(total) * 0.72)
        func makeManager(_ port: Int) -> ModelResourceManager {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let vlm = home.appending(path: ".local/bin/mlx_vlm.server")
            let watchdog = root.appending(path: "Sources/MLXMenu/Resources/worker_watchdog.py")
            return ModelResourceManager(registry: registry,
                runtimes: [.mlxVLM: OpenAIWorkerRuntime(backend: .mlxVLM, executable: vlm, watchdogScript: watchdog, basePort: port),
                           .nativeDocument: NativeDocumentRuntime()], memoryBudgetBytes: budget)
        }
        let checkpointURL = reportURL.deletingLastPathComponent().appending(path: "construction-tracer-checkpoint.json")
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: checkpointURL)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let firstManager = makeManager(18581)
        let interrupted = Task {
            try await firstManager.execute(decision: decision, request: request, checkpointContext: context,
                onCheckpoint: { checkpoint in
                    if checkpoint.completedStageCount == 1 {
                        if let data = try? encoder.encode(checkpoint) { try? data.write(to: checkpointURL, options: .atomic) }
                        try? await Task.sleep(for: .seconds(30))
                    }
                })
        }
        let waitDeadline = Date().addingTimeInterval(180)
        while !FileManager.default.fileExists(atPath: checkpointURL.path) && Date() < waitDeadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else {
            interrupted.cancel(); await firstManager.shutdown(); throw TracerError.missing("interruption checkpoint")
        }
        interrupted.cancel()
        var interruptionObserved = false
        do { _ = try await interrupted.value }
        catch is CancellationError { interruptionObserved = true }
        catch { if Task.isCancelled { interruptionObserved = true } else { throw error } }
        await firstManager.shutdown()

        // Decode from disk rather than reuse memory to exercise persisted restart semantics.
        let persisted = try decoder.decode(ExecutionCheckpoint.self, from: Data(contentsOf: checkpointURL))
        let secondManager = makeManager(18681)
        let resumeStarted = Date()
        let trace = try await secondManager.execute(decision: persisted.decision, request: request,
            resumeFrom: persisted, checkpointContext: context)
        let resumeMilliseconds = Date().timeIntervalSince(resumeStarted) * 1000
        let state = await secondManager.snapshot(totalMemoryBytes: total)
        await secondManager.shutdown()
        guard let output = trace.artifacts.last?.content,
              let outputData = output.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: outputData) as? [String: Any],
              let rooms = object["rooms"] as? [[String: Any]] else { throw TracerError.missing("validated structured output") }
        let labels = rooms.compactMap { $0["label"] as? String }
        let areas = rooms.compactMap { ($0["area_sq_ft"] as? NSNumber)?.doubleValue }
        let accepted = labels == ["LOBBY E", "OFFICE F"] && areas.count == 2 && abs(areas[0] - 91) < 0.01 && abs(areas[1] - 92.25) < 0.01
        let report: [String: Any] = [
            "schema_version": 1, "boundary": "hybrid", "profile_id": profile.qualifiedID,
            "profile_digest": profile.configurationDigest, "checkpoint_context_digest": context.configurationDigest,
            "interruption_observed": interruptionObserved, "completed_before_interrupt": persisted.completedStageCount,
            "resume_elapsed_ms": resumeMilliseconds,
            "resumed_stage_reused": trace.telemetry?.stages.first?.reused == true,
            "models_loaded_after_restart": Array(state.loadedModelIDs).sorted(),
            "actual_model_ids": trace.actualModelIDs, "labels": labels, "areas_sq_ft": areas,
            "accepted": accepted, "output": output,
            "provenance": ["sources": images.map(\.path), "source_digests": context.sourceIdentities.map(\.digest),
                           "validator": trace.artifacts.last?.metadata["validator"] ?? "unknown"],
            "uncertainty_preserved": rooms.allSatisfy { $0.keys.contains("uncertainty") },
            "unknown_metrics": trace.telemetry?.unknownMetrics ?? []
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: reportURL, options: .atomic)
        print(String(data: data, encoding: .utf8)!)
        guard accepted && interruptionObserved && trace.telemetry?.stages.first?.reused == true && state.loadedModelIDs.isEmpty else {
            throw TracerError.missing("tracer acceptance criteria")
        }
    }
}
enum TracerError: LocalizedError { case missing(String); var errorDescription: String? { if case .missing(let value) = self { return "Missing or invalid \(value)" }; return nil } }
