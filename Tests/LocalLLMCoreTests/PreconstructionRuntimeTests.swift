import AppKit
import Foundation
import PDFKit
import Testing
@testable import LocalLLMCore

private let rtAnswer = #"{"candidates":[{"kind":"dimension","text":"12 ft","quote":"12 ft","confidence":0.9}]}"#
private let rtPackage = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Preconstruction")

private struct RtWorkspace {
    let root: URL
    let store: PreconProjectStore
    let project: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PreconRuntime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try PreconProjectStore(root: root)
        project = try store.createProject(named: "Test", template: rtPackage.appending(path: "templates/project"))
    }
    func sources(_ text: String = "12 ft", pages: Int = 1) throws -> [SourceRecord] {
        let url = root.appending(path: "input-\(UUID()).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24)])
                    .draw(at: NSPoint(x: 72, y: 700))
                NSGraphicsContext.restoreGraphicsState()
            }
            context.endPDFPage()
        }
        context.closePDF()
        return try store.importSource(url, into: project, role: .proposed, revision: "SYN")
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

private actor RtRuntime: ModelRuntime {
    nonisolated let backend: InferenceBackend = .mlxLM
    var calls: [(RouteStage, StageExecutionInput)] = []
    var loads = 0
    let response: @Sendable (Int, RouteStage, StageExecutionInput) async throws -> String
    init(_ response: @escaping @Sendable (Int, RouteStage, StageExecutionInput) async throws -> String = { _,_,_ in rtAnswer }) {
        self.response = response
    }
    func load(model: RegisteredModel) async throws { loads += 1 }
    func unload(model: RegisteredModel) async {}
    func health(model: RegisteredModel) async -> ModelHealth { .healthy }
    func execute(model: RegisteredModel?, stage: RouteStage, input: StageExecutionInput) async throws -> PipelineArtifact {
        calls.append((stage, input))
        return PipelineArtifact(kind: .json, content: try await response(calls.count, stage, input))
    }
}

private actor RtPause {
    var started = false
    var waiter: CheckedContinuation<Void, Never>?
    func signal() { started = true; waiter?.resume(); waiter = nil }
    func wait() async { if !started { await withCheckedContinuation { waiter = $0 } } }
}


private actor ColdLoadRuntime: ModelRuntime {
    nonisolated let backend: InferenceBackend = .mlxLM
    var loadCount = 0
    var executions = 0
    var cancelledEntries = 0
    var releaseLoad: CheckedContinuation<Void, Never>?
    var loadStarted: CheckedContinuation<Void, Never>?
    var cancelledEntered: CheckedContinuation<Void, Never>?
    func load(model: RegisteredModel) async throws {
        loadCount += 1
        await withCheckedContinuation { releaseLoad = $0; loadStarted?.resume(); loadStarted = nil }
    }
    func waitForLoad() async { if loadCount == 0 { await withCheckedContinuation { loadStarted = $0 } } }
    func release() { releaseLoad?.resume(); releaseLoad = nil }
    func waitForCancelledEntry() async {
        if cancelledEntries == 0 { await withCheckedContinuation { cancelledEntered = $0 } }
    }
    func unload(model: RegisteredModel) async {}
    func health(model: RegisteredModel) async -> ModelHealth { .healthy }
    func execute(model: RegisteredModel?, stage: RouteStage, input: StageExecutionInput) async throws -> PipelineArtifact {
        if Task.isCancelled {
            cancelledEntries += 1; cancelledEntered?.resume(); cancelledEntered = nil
            throw CancellationError()
        }
        executions += 1
        return PipelineArtifact(kind: .json, content: rtAnswer)
    }
}
private actor CancellationObserved {
    var returned = false
    func mark() { returned = true }
}

private func rtModel(_ id: String = "text", capabilities: Set<Capability> = [.reasoning],
                     health: ModelHealth = .healthy) -> RegisteredModel {
    RegisteredModel(id: id, backend: .mlxLM, localPath: URL(filePath: "/nonexistent/mock-\(id)"), family: "mock",
                    capabilities: capabilities, inputModalities: [.text, .image], approximateMemoryBytes: 100,
                    supportsStructuredOutput: true, health: health)
}
private func rtManager(_ runtime: RtRuntime, models: [RegisteredModel] = [rtModel()], budget: Int64 = 1000) -> ModelResourceManager {
    ModelResourceManager(registry: ModelRegistry(models: models), runtimes: [.mlxLM: runtime], memoryBudgetBytes: budget)
}
private func rtRequest(_ stage: InterpretationStage = .nativeText) -> InterpretationRequest {
    InterpretationRequest(unitId: "unit", stage: stage, instruction: "Extract JSON", text: "12 ft", image: nil,
                          maxOutputTokens: 64, isRetry: false)
}
private func rtPipeline(_ w: RtWorkspace, _ adapter: PreconRuntimeInterpreter) async throws -> InterpretationPipeline {
    try await adapter.pipeline(store: w.store, project: w.project)
}

@Suite("Preconstruction runtime adapter MOCK")
struct PreconstructionRuntimeTests {
    @Test("S01: chosen text model receives one local structured reasoning stage")
    func chosenTextModel() async throws {
        let runtime = RtRuntime()
        let adapter = PreconRuntimeInterpreter(manager: rtManager(runtime, models: [rtModel(), rtModel("other")]), textModelID: "text")
        _ = try await adapter.interpret(rtRequest())
        let calls = await runtime.calls
        #expect(calls.count == 1)
        let (stage, input) = try #require(calls.first)
        #expect(stage.kind == .reasoning && stage.modelID == "text" && stage.fallbackModelIDs.isEmpty)
        #expect(stage.requiredCapabilities == [.reasoning])
        #expect(input.request.localOnly && input.request.requiresStructuredOutput && input.requiresStructuredOutput)
        #expect(input.request.forcedModelID == "text" && input.request.attachments.isEmpty)
        #expect(input.request.text.contains("12 ft") && input.request.text.contains("Extract JSON"))
        #expect(stage.modelProfile?.generation.maxOutputTokens == 64)
    }

    @Test("S02: missing or incapable image selection is unsupported without calls")
    func unsupportedImage() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let sources = try w.sources("")
        for selection in [nil, "text"] as [String?] {
            let runtime = RtRuntime()
            let adapter = PreconRuntimeInterpreter(manager: rtManager(runtime), textModelID: "text", imageModelID: selection)
            for stage in [InterpretationStage.ocr, .vision] {
                do { _ = try await adapter.interpret(rtRequest(stage)); Issue.record("must refuse") }
                catch PreconRuntimeError.unsupported(let reason) { #expect(!reason.isEmpty) }
            }
            let pipeline = try await rtPipeline(w, adapter)
            let units = try await pipeline.run(sources)
            #expect(units.first?.status == .deferred && units.first?.questions.isEmpty == false)
            #expect(try w.store.interpretation(units[0].id, in: w.project) == nil)
            #expect(await runtime.calls.isEmpty)
            #expect(await runtime.loads == 0)
        }
    }

    @Test("S03: missing unknown or unhealthy text model is unavailable without calls")
    func unavailableModel() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let sources = try w.sources()
        for selection in [nil, "missing", "failed", "unavailable"] as [String?] {
            let runtime = RtRuntime()
            let manager = rtManager(runtime, models: [rtModel("failed", health: .failed), rtModel("unavailable", health: .unavailable)])
            let adapter = PreconRuntimeInterpreter(manager: manager, textModelID: selection)
            do { _ = try await adapter.interpret(rtRequest()); Issue.record("must refuse") }
            catch PreconRuntimeError.unavailable(let reason) { #expect(!reason.isEmpty) }
            let pipeline = InterpretationPipeline(store: w.store, project: w.project, interpreter: adapter.interpret)
            let units = try await pipeline.run(sources)
            #expect(units.first?.status == .deferred)
            #expect(try w.store.interpretation(units[0].id, in: w.project) == nil)
            #expect(await runtime.calls.isEmpty)
            #expect(await runtime.loads == 0)
        }
    }

    @Test("S04: precheck refusal stops unsaved work and a larger budget reruns it")
    func admissionRefusal() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let sources = try w.sources(pages: 2)
        let runtime = RtRuntime()
        let adapter = PreconRuntimeInterpreter(manager: rtManager(runtime, budget: 1), textModelID: "text")
        do { _ = try await adapter.interpret(rtRequest()); Issue.record("must refuse") }
        catch PreconRuntimeError.resourceRefused(let reason) { #expect(!reason.isEmpty) }
        var pipeline = try await rtPipeline(w, adapter)
        let refused = try await pipeline.run(sources)
        #expect(refused.count == 1 && refused[0].status == .deferred && !refused[0].questions.isEmpty)
        #expect(try w.store.interpretation(refused[0].id, in: w.project) == nil)
        #expect(await runtime.calls.isEmpty)
        let available = PreconRuntimeInterpreter(manager: rtManager(runtime), textModelID: "text")
        pipeline = try await rtPipeline(w, available)
        #expect(pipeline.unitID(sources[0], focus: nil) == refused[0].id)
        let completed = try await pipeline.run(sources)
        #expect(completed.count == 2 && completed.allSatisfy { $0.status == .complete })
    }

    @Test("S04: execute refusal after a passing precheck remains unsaved runtime failure")
    func admissionRaceFailsClosed() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let runtime = RtRuntime { _,_,_ in throw ResourceError.memoryBudgetExceeded(modelID: "text") }
        let adapter = PreconRuntimeInterpreter(manager: rtManager(runtime), textModelID: "text")
        do { _ = try await adapter.interpret(rtRequest()); Issue.record("must refuse") }
        catch PreconRuntimeError.runtimeFailed(let reason) { #expect(!reason.isEmpty) }
        let pipeline = try await rtPipeline(w, adapter)
        let units = try await pipeline.run(w.sources(pages: 2))
        #expect(units.count == 1 && units[0].status == .deferred)
        #expect(try w.store.interpretation(units[0].id, in: w.project) == nil)
    }

    @Test("S05: cancellation preserves earlier units and rerun resumes only the unsaved page")
    func cancelledPageResumes() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let sources = try w.sources(pages: 2)
        let pause = RtPause()
        let runtime = RtRuntime { count,_,_ in
            if count == 2 { await pause.signal(); try await Task.sleep(for: .seconds(30)) }
            return rtAnswer
        }
        let adapter = PreconRuntimeInterpreter(manager: rtManager(runtime), textModelID: "text")
        let pipeline = try await rtPipeline(w, adapter)
        let task = Task { try await pipeline.run(sources) }
        await pause.wait(); task.cancel()
        let units = try await task.value
        #expect(units.count == 2 && units[0].status == .complete && units[1].status == .deferred)
        #expect(units[1].questions.contains { $0.localizedCaseInsensitiveContains("cancel") })
        #expect(try w.store.interpretation(units[1].id, in: w.project) == nil)
        let first = try StableDigest.file(w.project.appending(path: "interpretation/\(units[0].id).json"))
        let retryRuntime = RtRuntime()
        let retry = try await rtPipeline(w, PreconRuntimeInterpreter(manager: rtManager(retryRuntime), textModelID: "text"))
        let resumed = try await retry.run(sources)
        #expect(resumed.allSatisfy { $0.status == .complete })
        #expect(await retryRuntime.calls.count == 1)
        #expect(try StableDigest.file(w.project.appending(path: "interpretation/\(units[0].id).json")) == first)
    }

    @Test("S06: malformed output twice fails unsaved while unsupported quotes stay held")
    func malformedAndHeld() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let sources = try w.sources()
        let runtime = RtRuntime { _,_,_ in #"{"wrong":true}"# }
        let pipeline = try await rtPipeline(w, PreconRuntimeInterpreter(manager: rtManager(runtime), textModelID: "text"))
        let units = try await pipeline.run(sources)
        #expect(units[0].status == .failed && !units[0].questions.isEmpty)
        #expect(await runtime.calls.count == 2)
        #expect(try w.store.interpretation(units[0].id, in: w.project) == nil)
        let heldRuntime = RtRuntime { _,_,_ in #"{"candidates":[{"kind":"note","text":"invented","quote":"invented","confidence":1}]}"# }
        let heldPipeline = try await rtPipeline(w, PreconRuntimeInterpreter(manager: rtManager(heldRuntime), textModelID: "text"))
        let held = try await heldPipeline.run(sources)
        #expect(held[0].status == .held && held[0].candidates[0].heldReason == "quote not found in source text")
        #expect(!held[0].questions.isEmpty)
    }

    @Test("S07/C3-03: production pipeline factory binds model profile and source identity")
    func modelProfileIdentity() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let sources = try w.sources()
        let runtime = RtRuntime()
        let manager = rtManager(runtime, models: [rtModel(), rtModel("other")])
        let first = try await rtPipeline(w, PreconRuntimeInterpreter(manager: manager, textModelID: "text"))
        let saved = try await first.run(sources)
        let path = w.project.appending(path: "interpretation/\(saved[0].id).json")
        let before = try StableDigest.file(path)
        let other = try await rtPipeline(w, PreconRuntimeInterpreter(manager: manager, textModelID: "other"))
        #expect(first.unitID(sources[0], focus: nil) != other.unitID(sources[0], focus: nil))
        var profile = ModelProfile(id: "test", version: "1", baseModelID: "text", taskClasses: [.structuredExtraction], capabilities: [.reasoning])
        let profiled = try await rtPipeline(w, PreconRuntimeInterpreter(manager: manager, textModelID: "text", textProfile: profile))
        profile.systemPrompt = "Changed rules"
        let changed = try await rtPipeline(w, PreconRuntimeInterpreter(manager: manager, textModelID: "text", textProfile: profile))
        #expect(profiled.profileDigest != changed.profileDigest && first.profileDigest != profiled.profileDigest)
        _ = try await other.run(sources); _ = try await changed.run(sources)
        let changedSources = try w.sources("24 ft")
        #expect(first.unitID(sources[0], focus: nil) != first.unitID(changedSources[0], focus: nil))
        #expect(try StableDigest.file(path) == before)
        let storedSource = w.project.appending(path: sources[0].path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: storedSource.path)
        try Data("changed source".utf8).write(to: storedSource)
        await #expect(throws: PreconProjectError.self) { _ = try await first.run(sources) }
        #expect(try StableDigest.file(path) == before)
    }

    @Test("S08: OCR image is transient and OCR-only quotes stay held through the adapter")
    func ocrRemainsHeld() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let runtime = RtRuntime { _,stage,input in
            if stage.kind == .ocr {
                #expect(input.request.attachments.count == 1)
                let attachment = try #require(input.request.attachments.first)
                #expect(attachment.modality == .image && attachment.mimeType == "image/png")
                #expect(FileManager.default.fileExists(atPath: attachment.url.path))
                return #"{"text":"12 ft","confidence":0.99}"#
            }
            return rtAnswer
        }
        let manager = rtManager(runtime, models: [rtModel(), rtModel("image", capabilities: [.ocr, .vision])])
        let pipeline = try await rtPipeline(w, PreconRuntimeInterpreter(manager: manager, textModelID: "text", imageModelID: "image"))
        let units = try await pipeline.run(w.sources(""))
        #expect(units[0].status == .held)
        #expect(units[0].candidates[0].heldReason?.contains("no independent text") == true)
        let calls = await runtime.calls
        #expect(calls.map { $0.0.modelID } == ["image", "text"])
        let image = try #require(calls.first?.1.request.attachments.first?.url)
        #expect(!FileManager.default.fileExists(atPath: image.path))
    }


    @Test("S09: accepting evidence writes only a write-once review, never takeoff artifacts")
    func evidenceReviewIsSeparate() throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        _ = try w.store.saveRevision(PreconRevision(revisionId: "R1", synthetic: true),
                                    measurements: [("R1-m.json", Data("geometry".utf8))], in: w.project)
        let directories = ["measurements", "revisions", "checkpoints"]
        let before = try directories.map { try FileManager.default.subpathsOfDirectory(atPath: w.project.appending(path: $0).path).sorted() }
        let candidate = InterpretationCandidate(id: "C1", kind: .note, text: "12 ft", quote: nil,
                                                sourceId: "S1", pageIndex: 0, bbox: nil, confidence: nil, heldReason: "no quote")
        let digest = try candidate.reviewDigest()
        #expect(try w.store.candidateReview(unitId: "unit", candidateId: candidate.id, candidateDigest: digest, in: w.project) == nil)
        let url = try w.store.saveCandidateReview(unitId: "unit", candidateId: candidate.id, candidateDigest: digest,
                                                 decision: .accepted, note: "Checked source", in: w.project)
        let original = try StableDigest.file(url)
        #expect(url.deletingLastPathComponent().path == w.project.appending(path: "interpretation/reviews").path)
        let review = try #require(try w.store.candidateReview(unitId: "unit", candidateId: candidate.id, candidateDigest: digest, in: w.project))
        #expect(!review.stale && review.record.decision == .accepted && review.record.note == "Checked source")
        #expect(try directories.map { try FileManager.default.subpathsOfDirectory(atPath: w.project.appending(path: $0).path).sorted() } == before)
        #expect(throws: PreconProjectError.self) {
            _ = try w.store.saveCandidateReview(unitId: "unit", candidateId: candidate.id, candidateDigest: digest,
                                                decision: .rejected, note: nil, in: w.project)
        }
        #expect(try StableDigest.file(url) == original)
        _ = try w.store.saveCandidateReview(unitId: "unit", candidateId: "C2", candidateDigest: digest,
                                            decision: .rejected, note: nil, in: w.project)
        #expect(try w.store.candidateReview(unitId: "unit", candidateId: "C2", candidateDigest: digest, in: w.project)?.record.decision == .rejected)
    }

    @Test("S07/S09: review binds candidate digest and refuses corrupt or escaped records")
    func staleReviewAndContainment() throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        var candidate = InterpretationCandidate(id: "C1", kind: .note, text: "12 ft", quote: "12 ft",
                                                sourceId: "S1", pageIndex: 0, bbox: nil, confidence: 1, heldReason: nil)
        let digest = try candidate.reviewDigest()
        let url = try w.store.saveCandidateReview(unitId: "unit", candidateId: candidate.id, candidateDigest: digest,
                                                 decision: .accepted, note: nil, in: w.project)
        let bytes = try Data(contentsOf: url)
        candidate.text = "24 ft"
        #expect(try candidate.reviewDigest() != digest)
        let stale = try #require(try w.store.candidateReview(unitId: "unit", candidateId: candidate.id,
                                                        candidateDigest: try candidate.reviewDigest(), in: w.project))
        #expect(stale.stale && stale.record.candidateDigest == digest)
        #expect(try Data(contentsOf: url) == bytes)
        try Data("broken".utf8).write(to: url)
        #expect(throws: PreconProjectError.self) {
            _ = try w.store.candidateReview(unitId: "unit", candidateId: candidate.id, candidateDigest: digest, in: w.project)
        }
        let outside = FileManager.default.temporaryDirectory.appending(path: "PreconOutside-\(UUID())")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: url.deletingLastPathComponent(), withDestinationURL: outside)
        #expect(throws: PreconProjectError.self) {
            _ = try w.store.saveCandidateReview(unitId: "unit", candidateId: "C2", candidateDigest: digest,
                                                decision: .accepted, note: nil, in: w.project)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test("S10: saved candidate unknowns remain explicit null and legacy questions decode empty")
    func explicitUnknowns() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let runtime = RtRuntime { _,_,_ in #"{"candidates":[{"kind":"note","text":"unknown"}]}"# }
        let pipeline = try await rtPipeline(w, PreconRuntimeInterpreter(manager: rtManager(runtime), textModelID: "text"))
        let units = try await pipeline.run(w.sources())
        let bytes = try Data(contentsOf: w.project.appending(path: "interpretation/\(units[0].id).json"))
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let candidates = try #require(json["candidates"] as? [[String: Any]])
        for key in ["quote", "bbox", "confidence"] { #expect(candidates[0][key] is NSNull) }
        #expect(json["questions"] is [String])
        json.removeValue(forKey: "questions")
        let legacy = try PreconJSON.decoder.decode(InterpretationUnit.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.questions.isEmpty)
    }

    @Test("S19/C3-01: over-threshold profiles defer before backend chunking without calls")
    func oversizedProfileRefused() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let runtime = RtRuntime()
        let profile = ModelProfile(id: "long", version: "1", baseModelID: "text", taskClasses: [.structuredExtraction],
                                   capabilities: [.reasoning], systemPrompt: String(repeating: "x", count: 100_000))
        let adapter = PreconRuntimeInterpreter(manager: rtManager(runtime), textModelID: "text", textProfile: profile)
        var refused = false
        do { _ = try await adapter.interpret(rtRequest()) }
        catch PreconRuntimeError.unsupported(let reason) { refused = !reason.isEmpty }
        #expect(refused, "The effective prompt must not enter automatic backend chunking")
        let pipeline = try await rtPipeline(w, adapter)
        let units = try await pipeline.run(w.sources())
        #expect(units[0].status == .deferred)
        #expect(try w.store.interpretation(units[0].id, in: w.project) == nil)
        #expect(await runtime.calls.isEmpty)
        #expect(await runtime.loads == 0)
    }

    @Test("S20/C3-02: unused oversized image selection cannot block a native text stage")
    func unusedImageDoesNotRefuseText() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        var image = rtModel("image", capabilities: [.ocr, .vision]); image.approximateMemoryBytes = 10_000
        let runtime = RtRuntime()
        let adapter = PreconRuntimeInterpreter(manager: rtManager(runtime, models: [rtModel(),image]),
                                               textModelID: "text", imageModelID: "image")
        let pipeline = try await adapter.pipeline(store: w.store, project: w.project)
        let units = try await pipeline.run(w.sources())
        #expect(units[0].status == .complete)
        #expect(await runtime.calls.map { $0.0.modelID } == ["text"])
    }

    @Test("S21/C4-01: cold-load cancellation returns promptly while a live waiter shares the load")
    func cancelColdLoad() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let sources = try w.sources()
        let runtime = ColdLoadRuntime()
        let manager = ModelResourceManager(registry: .init(models: [rtModel()]), runtimes: [.mlxLM: runtime], memoryBudgetBytes: 1000)
        let adapter = PreconRuntimeInterpreter(manager: manager, textModelID: "text")
        let pipeline = try await adapter.pipeline(store: w.store, project: w.project)
        let observation = CancellationObserved()
        let cancelled = Task {
            let units = try await pipeline.run(sources)
            await observation.mark()
            return units
        }
        await runtime.waitForLoad()
        let liveStarted = RtPause()
        let liveRequest = InferenceRequest(text: "live", requiresStructuredOutput: true)
        let decision = RoutingDecision(requestID: liveRequest.id,
            requirements: .init(category: .reasoning, requiredCapabilities: [.reasoning], inputModalities: [.text]),
            stages: [.init(kind: .reasoning, modelID: "text", backend: .mlxLM, requiredCapabilities: [.reasoning], inputModalities: [.text])], reason: "MOCK live waiter")
        let live = Task { try await manager.execute(decision: decision, request: liveRequest, onEvent: { event in
            if case .stageStarted = event { await liveStarted.signal() }
        }) }
        await liveStarted.wait()
        cancelled.cancel()
        // The load stays suspended; this bound observes prompt cancellation without releasing it to make the test pass.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await observation.returned, "Cancelled page must return before the shared load is released")
        #expect(await runtime.executions == 0)
        #expect(try w.store.interpretation(pipeline.unitID(sources[0], focus: nil), in: w.project) == nil)
        await runtime.release()
        let units = try await cancelled.value
        #expect(units.count == 1 && units[0].status == .deferred)
        _ = try await live.value
        await runtime.waitForCancelledEntry()
        #expect(await runtime.loadCount == 1)
        #expect(await runtime.executions == 1, "Only the live waiter may perform effective inference")
        #expect(await runtime.cancelledEntries == 1, "Manager may enter execute, but cancellation-aware runtime refuses work")
        #expect(try w.store.interpretation(units[0].id, in: w.project) == nil)
    }

    @Test("S23: adapter admits a model fitting only after idle eviction and refuses one exceeding that hint")
    func idleEvictionAdmission() async throws {
        let runtime = RtRuntime()
        var larger = rtModel("too-large"); larger.approximateMemoryBytes = 101
        let manager = rtManager(runtime, models: [rtModel("first"), rtModel("second"), larger], budget: 100)
        _ = try await PreconRuntimeInterpreter(manager: manager, textModelID: "first").interpret(rtRequest())
        let snapshot = await manager.snapshot(totalMemoryBytes: 100)
        #expect(snapshot.availableMemoryBytes == 0 && snapshot.reclaimableMemoryBytes == 100)
        var completed = false
        do { _ = try await PreconRuntimeInterpreter(manager: manager, textModelID: "second").interpret(rtRequest()); completed = true }
        catch { }
        #expect(completed, "Manager must get the opportunity to evict idle first")
        #expect(await manager.snapshot(totalMemoryBytes: 100).loadedModelIDs == ["second"])
        let before = await runtime.calls.count
        do { _ = try await PreconRuntimeInterpreter(manager: manager, textModelID: "too-large").interpret(rtRequest()); Issue.record("must refuse") }
        catch PreconRuntimeError.resourceRefused { }
        #expect(await runtime.calls.count == before)
    }

    @Test("S24: refused evaluation still yields a report with reasons and skipped-page coverage")
    func deferredEvaluationReport() async throws {
        let w = try RtWorkspace(); defer { w.cleanUp() }
        let runtime = RtRuntime()
        let adapter = PreconRuntimeInterpreter(manager: rtManager(runtime, budget: 1), textModelID: "text")
        let cases = ["one", "two"].map { PreconEvaluationCase(id: $0, raster: false, lines: ["12 ft"], expected: ["12 ft"], absent: []) }
        let dataset = PreconEvaluationSet(label: "MOCK", cases: cases)
        let pages = try await dataset.evaluate(adapter: adapter, in: w.root)
        #expect(pages.count == 1 && pages[0].units[0].status == .deferred)
        #expect(!pages[0].units[0].questions.isEmpty)
        let report = try dataset.report(pages, label: "MOCK")
        let file = w.root.appending(path: "report.json")
        try report.write(to: file, options: .withoutOverwriting)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let units = try #require(json["units"] as? [[String: Any]])
        #expect(units[0]["status"] as? String == "deferred")
        let score = try dataset.score(pages, label: "MOCK")
        #expect(score.coverage.pagesInterpreted == 0 && score.coverage.pagesSkipped == 2)
        #expect(score.coverage.chunksSkipped == nil && score.sourceSupport.display == "unavailable")
        #expect(await runtime.calls.isEmpty)
    }
}
