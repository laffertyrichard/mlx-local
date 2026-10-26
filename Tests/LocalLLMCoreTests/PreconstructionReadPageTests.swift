import Foundation
import PDFKit
import Testing
@testable import LocalLLMCore

@Suite("Read page presentation and evaluation MOCK")
struct PreconstructionReadPageTests {
    @Test("S12: model choices require capabilities and never select defaults")
    func modelChoices() {
        let text = RegisteredModel(id: "text", backend: .mlxLM, localPath: URL(filePath: "/mock"), family: "mock",
                                   capabilities: [.reasoning], inputModalities: [.text], approximateMemoryBytes: 1, supportsStructuredOutput: true)
        var image = text; image.id = "image"; image.capabilities = [.ocr]; image.inputModalities = [.image]
        var invalid = text; invalid.id = "invalid"; invalid.supportsStructuredOutput = false
        #expect(PreconReadPage.textModels([image, invalid, text]).map(\.id) == ["text"])
        #expect(PreconReadPage.imageModels([text, invalid, image]).map(\.id) == ["image"])
        #expect(PreconReadPage.textModels([]).isEmpty)
    }

    @Test("S13: review state preserves held and stale evidence without promoting quantities")
    func rowState() {
        let candidate = InterpretationCandidate(id: "C", kind: .note, text: "note", quote: nil, sourceId: "S", pageIndex: 0,
                                                bbox: nil, confidence: nil, heldReason: "no source quote")
        #expect(PreconReadPage.reviewState(candidate, review: nil) == .held)
        var offered = candidate; offered.heldReason = nil
        #expect(PreconReadPage.reviewState(offered, review: nil) == .offered)
        let record = CandidateReview(unitId: "U", candidateId: "C", candidateDigest: "hash", decision: .accepted, note: nil)
        #expect(PreconReadPage.reviewState(candidate, review: .init(record: record, stale: false)) == .accepted)
        #expect(PreconReadPage.reviewState(candidate, review: .init(record: record, stale: true)) == .stale)
    }

    @Test("S14: crop math validates stored bounds and rotates all corners", arguments: [0, 90, 180, 270])
    func cropBounds(rotation: Int) throws {
        let frame = PageFrame(width: 600, height: 800, rotation: rotation)
        let rect = try #require(PreconReadPage.cropRect([10,20,30,40], frame: frame, pixelWidth: frame.displaySize.width * 2))
        #expect(rect.width == (rotation % 180 == 0 ? 60 : 80))
        #expect(rect.height == (rotation % 180 == 0 ? 80 : 60))
        for invalid in [[Double.nan,0,10,10], [-1,0,10,10], [590,0,20,10], [0,0,0,10], [1,2]] {
            #expect(PreconReadPage.cropRect(invalid, frame: frame, pixelWidth: 1200) == nil)
        }
        #expect(PreconReadPage.cropRect(nil, frame: frame, pixelWidth: 1200) == nil)
    }

    @Test("S11: held-out synthetic set reports four separate MOCK metrics")
    func mockEvaluation() async throws {
        let dataset = try PreconEvaluationSet.load(Bundle.module.url(forResource: "expected", withExtension: "json", subdirectory: "precon-eval")!)
        #expect(dataset.cases.count == 5 && dataset.cases.filter(\.raster).count == 1)
        let root = FileManager.default.temporaryDirectory.appending(path: "PreconEval-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PreconProjectStore(root: root)
        let project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var results: [PreconEvaluationPage] = []
        for item in dataset.cases {
            let pdf = try dataset.generate(item, in: root)
            let document = try #require(PDFDocument(url: pdf))
            let native = document.page(at: 0)?.string ?? ""
            #expect(item.raster ? native.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : native.contains(item.lines[0]))
            let sources = try store.importSource(pdf, into: project, role: .proposed, revision: "EVAL")
            let interpreter: PreconInterpreter = { request in
                if request.stage == .ocr { return String(data: try JSONSerialization.data(withJSONObject: ["text":item.lines.joined(separator:"\n"),"confidence":1]), encoding:.utf8)! }
                let candidates = item.expected.map { ["kind":"note", "text":$0,"quote":$0,"confidence":1] as [String:Any] }
                return String(data: try JSONSerialization.data(withJSONObject:["candidates":candidates]), encoding:.utf8)!
            }
            let pipeline = InterpretationPipeline(store: store, project: project, interpreter: interpreter)
            let units = try await pipeline.run(sources)
            results.append(PreconEvaluationPage(caseID: item.id, units: units, nativeText: native))
        }
        let score = try dataset.score(results, label: "MOCK")
        print(try score.json())
        #expect(score.label == "MOCK")
        #expect(score.extraction.matched == score.extraction.total && score.absentItemsFound.isEmpty)
        #expect(score.sourceSupport.matched! < score.sourceSupport.total!) // OCR text is not independent support.
        #expect(score.coverage.pagesInterpreted == 5 && score.coverage.pagesSkipped == 0)
        #expect(score.coverage.chunksInterpreted == 5 && score.coverage.chunksSkipped == 0)
        #expect(score.quantityAccuracy.matched == 2 && score.quantityAccuracy.total == 2)
        let unavailable = try PreconEvaluationSet(label: "empty", cases: []).score([], label: "MOCK")
        #expect(unavailable.extraction.display == "unavailable" && unavailable.quantityAccuracy.display == "unavailable")
    }

    @Test("S15: deferred pages and absent claims cannot improve evaluation scores")
    func negativeEvaluation() throws {
        let item = PreconEvaluationCase(id: "case", raster: false, lines: ["oak"], expected: ["oak"], absent: ["marble"])
        let candidate = InterpretationCandidate(id: "C", kind: .material, text: "marble", quote: "marble", sourceId: "S", pageIndex: 0,
                                                bbox: nil, confidence: 1, heldReason: "unsupported")
        var unit = InterpretationUnit(id: "U", sourceId: "S", pageIndex: 0, stage: .nativeText, status: .deferred, candidates: [candidate])
        unit.plannedChunks = 2; unit.interpretedChunks = 1
        let set = PreconEvaluationSet(label: "negative", cases: [item])
        let score = try set.score([.init(caseID: "case", units: [unit], nativeText: "oak")], label: "MOCK")
        #expect(score.extraction.matched == 0 && score.absentItemsFound == ["case: marble"])
        #expect(score.sourceSupport.matched == 0 && score.quantityAccuracy.display == "unavailable")
        #expect(score.coverage.pagesSkipped == 1 && score.coverage.chunksSkipped == 1)
    }

    @Test("S16: evaluation authorization rejects missing selections and unknown flags")
    func runnerAuthorization() throws {
        #expect(throws: (any Error).self) { _ = try PreconEvaluationOptions.parse([]) }
        #expect(throws: (any Error).self) { _ = try PreconEvaluationOptions.parse(["--text-model","model","--output","out"]) }
        #expect(throws: (any Error).self) { _ = try PreconEvaluationOptions.parse(["--authorized","--text-model","model","--output","out","--download"]) }
        let options = try PreconEvaluationOptions.parse(["--authorized","--text-model","model","--output","out"])
        #expect(options.textModelID == "model" && options.imageModelID == nil)
    }

    @Test("S17: thumbnails use source hashes and never invent missing crops")
    func sourceThumbnail() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PreconCrop-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PreconProjectStore(root: root), project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let item = PreconEvaluationCase(id: "crop", raster: false, lines: ["12 ft"], expected: ["12 ft"], absent: [])
        let dataset = PreconEvaluationSet(label: "MOCK", cases: [item])
        let pdf = try dataset.generate(item, in: root)
        let source = try #require(store.importSource(pdf, into: project, role: .proposed, revision: "TEST").first)
        var candidate = InterpretationCandidate(id: "C", kind: .dimension, text: "12 ft", quote: "12 ft", sourceId: source.id,
                                                pageIndex: 0, bbox: nil, confidence: nil, heldReason: nil)
        #expect(try PreconReadPage.thumbnail(candidate, source: source, store: store, project: project) == nil)
        candidate.bbox = [30,40,150,60]
        #expect(try PreconReadPage.thumbnail(candidate, source: source, store: store, project: project)?.isEmpty == false)
        let path = project.appending(path: source.path)
        try FileManager.default.setAttributes([.posixPermissions:0o644], ofItemAtPath:path.path)
        try Data("tampered".utf8).write(to:path)
        #expect(throws: PreconProjectError.self) {
            _ = try PreconReadPage.thumbnail(candidate, source: source, store: store, project: project)
        }
    }

    @Test("S18: chunk coverage counts actual extraction work and budget gaps")
    func chunkCoverage() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PreconChunks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PreconProjectStore(root:root), project = root.appending(path:"project")
        try FileManager.default.createDirectory(at:project,withIntermediateDirectories:true)
        let item = PreconEvaluationCase(id:"chunks",raster:false,lines:["oak", "tile", "brick"],expected:["oak"],absent:[])
        let dataset = PreconEvaluationSet(label:"MOCK",cases:[item])
        let pdf = try dataset.generate(item,in:root)
        let source = try store.importSource(pdf,into:project,role:.proposed,revision:"EVAL")
        var pipeline = InterpretationPipeline(store:store,project:project,interpreter:{ _ in #"{"candidates":[]}"# })
        pipeline.budget.maxInputChars = 5; pipeline.budget.maxChunks = 1
        let units = try await pipeline.run(source)
        #expect(units[0].status == .partial && units[0].plannedChunks == 3 && units[0].interpretedChunks == 1)
        let score = try dataset.score([.init(caseID:item.id,units:units,nativeText:"oak\ntile\nbrick")],label:"MOCK")
        #expect(score.coverage.pagesSkipped == 1 && score.coverage.chunksInterpreted == 1 && score.coverage.chunksSkipped == 2)
    }

    @Test("S22/C4-02: a unit verifies and opens one document and renders one page for many crops")
    func batchThumbnails() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PreconBatch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PreconProjectStore(root: root), project = root.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let item = PreconEvaluationCase(id: "batch", raster: false, lines: ["12 ft"], expected: ["12 ft"], absent: [])
        let pdf = try PreconEvaluationSet(label: "MOCK", cases: [item]).generate(item, in: root)
        let source = try #require(store.importSource(pdf, into: project, role: .proposed, revision: "TEST").first)
        let candidates = (0..<12).map { index in
            InterpretationCandidate(id: "C\(index)", kind: .dimension, text: "12 ft", quote: "12 ft", sourceId: source.id,
                                    pageIndex: 0, bbox: [30,40,150,60], confidence: nil, heldReason: nil)
        }
        let events = ThumbnailEvents()
        let result = try await PreconReadPage.thumbnails(candidates, source: source, store: store, project: project,
                                                       observe: { events.record($0) })
        #expect(result.count == 12 && result.values.allSatisfy { !$0.isEmpty })
        #expect(events.counts == ["hash":1,"open":1,"render":1,"crop":12])
        #expect(!events.usedMainThread)
        let pause = ThumbnailPause()
        let work = Task {
            try await PreconReadPage.thumbnails(candidates, source: source, store: store, project: project,
                beforeCandidate: { await pause.hold() })
        }
        await pause.waitForStart(); work.cancel(); await pause.release()
        do { _ = try await work.value; Issue.record("Cancelled hydration must not publish thumbnails") }
        catch is CancellationError {}
        let stored = project.appending(path: source.path)
        try FileManager.default.setAttributes([.posixPermissions:0o644], ofItemAtPath:stored.path)
        try Data("changed".utf8).write(to:stored)
        await #expect(throws: PreconProjectError.self) {
            _ = try await PreconReadPage.thumbnails(candidates, source:source, store:store, project:project)
        }
    }
}

private final class ThumbnailEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String:Int] = [:]
    private var main = false
    func record(_ event: String) { lock.lock(); defer { lock.unlock() }; events[event, default:0] += 1; main = main || Thread.isMainThread }
    var counts: [String:Int] { lock.lock(); defer { lock.unlock() }; return events }
    var usedMainThread: Bool { lock.lock(); defer { lock.unlock() }; return main }
}
private actor ThumbnailPause {
    var started = false
    var start: CheckedContinuation<Void,Never>?
    var finish: CheckedContinuation<Void,Never>?
    func hold() async { await withCheckedContinuation { finish = $0; started = true; start?.resume(); start = nil } }
    func waitForStart() async { if !started { await withCheckedContinuation { start = $0 } } }
    func release() { finish?.resume(); finish = nil }
}
