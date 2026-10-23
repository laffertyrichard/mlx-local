import AppKit
import Foundation
import PDFKit
import Testing
@testable import LocalLLMCore

// Adversarial regression tests (tests only, coordinator-authored brief F01–F11).
// Expected outcome at the time of writing: most of these fail against the current code — that is the evidence.
// Synthetic data only: PDFs are generated in code inside a fresh temp directory per test.
// Crash-inducing cases are gated behind ADVERSARIAL_CRASH=1 and say so in their names.

private let advPackage = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Preconstruction")

/// Temporary data root standing in for PRECONSTRUCTION_WORKSPACE, plus a scratch directory for generated PDFs.
private struct AdvWorkspace {
    let root: URL
    let store: PreconProjectStore
    /// Scratch area inside the temp root but outside any project, so sources are generated, never copied from disk.
    let generated: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PreconAdv-\(UUID().uuidString)")
        generated = root.appending(path: "generated-docs")
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        store = try PreconProjectStore(root: root)
    }

    func project(_ name: String = "Alpha") throws -> URL {
        try store.createProject(named: name, template: advPackage.appending(path: "templates/project"))
    }

    func cleanUp() {
        // Imported sources are read-only; restore write permission so the temp tree can be removed.
        if let items = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in items {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: path).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}

/// Wipes a scratch directory even when it holds read-only files. Refuses non-temporary paths as a guard.
private func advWipeTemporary(_ directory: URL) {
    guard directory.path.hasPrefix(FileManager.default.temporaryDirectory.path) else { return }
    if let items = FileManager.default.enumerator(atPath: directory.path) {
        for case let path as String in items {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appending(path: path).path)
        }
    }
    try? FileManager.default.removeItem(at: directory)
}

/// A fresh temp directory outside the workspace root, used as a symlink destination.
private func advOutsideDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "PreconAdvOutside-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Relative path -> sha256 for every file and "<dir>" for every directory, so a listing plus content
/// hashes taken before and after an operation can be compared for byte-identity.
private func advFileSnapshot(_ directory: URL) -> [String: String] {
    let subpaths = (try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []
    var snapshot: [String: String] = [:]
    for path in subpaths.sorted() {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.appending(path: path).path, isDirectory: &isDirectory) {
            snapshot[path] = isDirectory.boolValue ? "<dir>"
                : (try? StableDigest.file(directory.appending(path: path))) ?? "<unreadable>"
        }
    }
    return snapshot
}

/// Synthetic one-page-per-call PDF carrying natively extractable text lines.
private func advTextPDF(_ lines: [String], pages: Int = 1, in directory: URL) throws -> URL {
    let url = directory.appending(path: "text-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        let attributed = NSAttributedString(string: lines.joined(separator: "\n"),
                                            attributes: [.font: NSFont.systemFont(ofSize: 24)])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(at: NSPoint(x: 72, y: 700))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
    }
    context.closePDF()
    return url
}

/// Text-free pages, so every page goes to OCR.
private func advBlankPDF(pages: Int, in directory: URL) throws -> URL {
    let url = directory.appending(path: "scan-\(pages)-\(UUID().uuidString).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    for _ in 0..<pages {
        context.beginPDFPage(nil); context.stroke(box.insetBy(dx: 36, dy: 36)); context.endPDFPage()
    }
    context.closePDF()
    return url
}

private func advCandidates(_ items: [(String, String?, Double)]) -> String {
    let rows = items.map { text, quote, confidence in
        #"{"kind": "dimension", "text": "\#(text)", "quote": \#(quote.map { "\"\($0)\"" } ?? "null"), "confidence": \#(confidence)}"#
    }
    return #"{"candidates": [\#(rows.joined(separator: ","))]}"#
}

/// Scripted stand-in for a local model: records every call and answers from a closure.
private actor AdvInterpreter {
    private(set) var calls: [InterpretationRequest] = []
    let answer: @Sendable (InterpretationRequest, Int) throws -> String

    init(_ answer: @escaping @Sendable (InterpretationRequest, Int) throws -> String) { self.answer = answer }

    func handle(_ request: InterpretationRequest) throws -> String {
        calls.append(request)
        return try answer(request, calls.count)
    }

    nonisolated var closure: PreconInterpreter { { try await self.handle($0) } }
}

private func advImportedPlan(_ workspace: AdvWorkspace, project: URL, lines: [String] = ["12 ft"]) throws -> [SourceRecord] {
    let pdf = try advTextPDF(lines, in: workspace.generated)
    return try workspace.store.importSource(pdf, into: project, role: .proposed, revision: "R1")
}

@Suite("Preconstruction adversarial")
struct PreconstructionAdversarialTests {

    // MARK: - F01 symlink escape

    /// Invariant: nothing written through a symlink inside a project (measurements/, interpretation/,
    /// sources/<hash>/, or the project directory itself) may escape the data root; every such save/import
    /// must throw and the symlinked outside directory must remain byte-identical.
    @Test("F01: symlinked child directories and project dirs must not let saves escape the data root")
    func symlinkEscape() throws {
        // A. measurements/ is a symlink to an outside temp dir; saveMeasurement must refuse.
        let workspaceA = try AdvWorkspace()
        defer { workspaceA.cleanUp() }
        let outsideA = try advOutsideDirectory("measurements")
        defer { advWipeTemporary(outsideA) }
        let projectA = try workspaceA.project()
        try FileManager.default.removeItem(at: projectA.appending(path: "measurements"))
        try FileManager.default.createSymbolicLink(at: projectA.appending(path: "measurements"),
                                                   withDestinationURL: outsideA)
        let beforeA = advFileSnapshot(outsideA)
        #expect(throws: (any Error).self,
                "F01 invariant: saveMeasurement through a symlinked measurements/ must throw, not write outside") {
            _ = try workspaceA.store.saveMeasurement(Data("{}".utf8), named: "R1-plane.json", in: projectA)
        }
        #expect(advFileSnapshot(outsideA) == beforeA, "the outside directory must stay byte-identical")

        // B. interpretation/ is a symlink to an outside temp dir; saveInterpretation must refuse.
        let workspaceB = try AdvWorkspace()
        defer { workspaceB.cleanUp() }
        let outsideB = try advOutsideDirectory("interpretation")
        defer { advWipeTemporary(outsideB) }
        let projectB = try workspaceB.project()
        try FileManager.default.createSymbolicLink(at: projectB.appending(path: "interpretation"),
                                                   withDestinationURL: outsideB)
        let beforeB = advFileSnapshot(outsideB)
        let unit = InterpretationUnit(id: "U1", sourceId: "S1", pageIndex: 0, stage: .nativeText, status: .complete)
        #expect(throws: (any Error).self,
                "F01 invariant: saveInterpretation through a symlinked interpretation/ must throw") {
            try workspaceB.store.saveInterpretation(unit, in: projectB)
        }
        #expect(advFileSnapshot(outsideB) == beforeB, "the outside directory must stay byte-identical")

        // C. sources/<hash>/ (pre-created symlink) must not receive imported source bytes.
        let workspaceC = try AdvWorkspace()
        defer { workspaceC.cleanUp() }
        let outsideC = try advOutsideDirectory("sources")
        defer { advWipeTemporary(outsideC) }
        let projectC = try workspaceC.project()
        let pdf = try advTextPDF(["12 ft"], in: workspaceC.generated)
        let digest = StableDigest.sha256(try Data(contentsOf: pdf))
        try FileManager.default.createDirectory(at: projectC.appending(path: "sources"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: projectC.appending(path: "sources/\(digest)"),
                                                   withDestinationURL: outsideC)
        let beforeC = advFileSnapshot(outsideC)
        #expect(throws: (any Error).self,
                "F01 invariant: importSource into a symlinked sources/<hash>/ must throw, not write outside") {
            _ = try workspaceC.store.importSource(pdf, into: projectC, role: .proposed, revision: "R1")
        }
        #expect(advFileSnapshot(outsideC) == beforeC, "the outside directory must stay byte-identical")

        // D. the project directory itself is a symlink out of the root; nothing may be written there.
        let workspaceD = try AdvWorkspace()
        defer { workspaceD.cleanUp() }
        let outsideD = try advOutsideDirectory("project")
        defer { advWipeTemporary(outsideD) }
        try FileManager.default.createSymbolicLink(at: workspaceD.root.appending(path: "Gamma"),
                                                   withDestinationURL: outsideD)
        let beforeD = advFileSnapshot(outsideD)
        let gamma = workspaceD.root.appending(path: "Gamma")
        #expect(throws: (any Error).self, "F01 invariant: a symlinked project directory must be refused") {
            _ = try workspaceD.store.saveMeasurement(Data("{}".utf8), named: "R1-plane.json", in: gamma)
        }
        #expect(throws: (any Error).self) { try workspaceD.store.saveInterpretation(unit, in: gamma) }
        #expect(throws: (any Error).self) {
            _ = try workspaceD.store.importSource(pdf, into: gamma, role: .proposed, revision: "R1")
        }
        #expect(advFileSnapshot(outsideD) == beforeD, "the outside directory must stay byte-identical")
    }

    // MARK: - F02 stale stored source

    /// Invariant: once the stored PDF bytes differ from the recorded hash, a rerun of the pipeline must not
    /// reuse the saved interpretation unit; it must refuse with sourceChanged.
    @Test("F02: a rerun after the stored source bytes changed must throw sourceChanged, not reuse the saved unit")
    func staleStoredSource() async throws {
        let workspace = try AdvWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let sources = try advImportedPlan(workspace, project: project)
        let mock = AdvInterpreter { _, _ in advCandidates([("12 ft", "12 ft", 0.9)]) }
        let pipeline = InterpretationPipeline(store: workspace.store, project: project, interpreter: mock.closure)
        let first = try await pipeline.run(sources)
        #expect(first.count == 1 && first[0].status == .complete)
        let saved = try #require(try workspace.store.interpretation(first[0].id, in: project),
                                 "a completed unit must have been saved")

        // Stored bytes no longer match the recorded hash.
        let stored = project.appending(path: sources[0].path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stored.path)
        var bytes = try Data(contentsOf: stored)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: stored)

        do {
            let rerun = try await pipeline.run(sources)
            #expect(rerun.first != saved, "the saved unit must not be handed back when the stored source changed")
            Issue.record("rerun after the stored source changed returned units instead of throwing sourceChanged")
        } catch let error as PreconProjectError {
            guard case .sourceChanged = error else {
                Issue.record("expected sourceChanged, got \(error)")
                return
            }
        } catch {
            Issue.record("expected PreconProjectError.sourceChanged, got: \(error)")
        }
    }

    // MARK: - F03 cache identity

    /// Invariant per brief: the candidate instruction text is a compile-time constant on
    /// InterpretationPipeline today, so it cannot be configured and therefore is not part of the unit key.
    /// This test documents that gap: any future pipeline instance with a different prompt would silently
    /// share cached units with this one. If the instruction is ever made configurable, unitID must grow a
    /// prompt component and this test must change.
    @Test("F03: the unit key distinguishes prompt variants")
    func cacheIdentityIgnoresInstruction() throws {
        let workspace = try AdvWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let sources = try advImportedPlan(workspace, project: project)
        let first = InterpretationPipeline(store: workspace.store, project: project, interpreter: { _ in "" })
        var variant = first
        variant.candidateInstruction += " (variant)"
        var different = first
        different.budget.maxInputChars = first.budget.maxInputChars + 1

        // Sanity: configuration that does enter the key really changes the identity.
        #expect(first.unitID(sources[0], focus: nil) != different.unitID(sources[0], focus: nil),
                "fields like the budget must change the unit identity")
        // Coordinator update after the fix: the instruction is configurable and digested into the key.
        #expect(first.unitID(sources[0], focus: nil) != variant.unitID(sources[0], focus: nil),
                "unitID must distinguish pipelines by their candidate instruction")
    }

    // MARK: - F04 interrupted save

    /// Invariant: an interrupted revision save (measurement written, revision blocked) must be recoverable
    /// by retrying the identical sequence once permissions allow; identical bytes may not be treated as a
    /// conflict with leftover partial work.
    @Test("F04: retrying an interrupted save with identical bytes must succeed, not collide")
    func interruptedSave() throws {
        let workspace = try AdvWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let measurement = try PreconJSON.encoder.encode(["interrupted": true])
        let name = "R1-plane.json"
        let path = "measurements/\(name)"

        // Block the revision write by making revisions/ unwritable, then fail the save.
        let revisions = project.appending(path: "revisions")
        try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: revisions.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: revisions.path) }
        var revision = PreconRevision(revisionId: "R1")
        revision.quantities = []
        #expect(throws: (any Error).self, "the interrupted save must fail while revisions/ is unwritable") {
            _ = try workspace.store.saveRevision(revision, measurements: [(name, measurement)], in: project)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: revisions.path)

        // Retry the identical sequence with identical bytes: it must succeed.
        var retryError: (any Error)?
        var saved: URL?
        do {
            saved = try workspace.store.saveRevision(revision, measurements: [(name, measurement)], in: project)
        } catch {
            retryError = error
        }
        #expect(retryError == nil,
                "F04 invariant: the identical retry must succeed; got \(retryError.map(String.init(describing:)) ?? "success")")
        let checkpoint = try #require(saved)
        #expect(try workspace.store.resume(from: checkpoint, in: project).1.measurementDigests.keys.sorted() == [path])
    }

    // MARK: - F05 corrupt is not stale

    /// Invariant: a corrupt interpretation unit file and a corrupt checkpoint are corruption, not staleness;
    /// neither may be classified as .staleCheckpoint.
    @Test("F05: corrupt interpretation file and corrupt checkpoint must not be reported as staleCheckpoint")
    func corruptIsNotStale() throws {
        let workspace = try AdvWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        _ = try advImportedPlan(workspace, project: project)

        // Corrupt interpretation unit file.
        let interpretation = project.appending(path: "interpretation")
        try FileManager.default.createDirectory(at: interpretation, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: interpretation.appending(path: "U1.json"))
        do {
            _ = try workspace.store.interpretation("U1", in: project)
            Issue.record("reading a corrupt interpretation file must raise an error")
        } catch let error as PreconProjectError {
            if case .staleCheckpoint = error {
                Issue.record("corruption of interpretation/U1.json must not be classified staleCheckpoint: \(error)")
            }
        } catch { /* any non-staleCheckpoint error classification is acceptable */ }

        // Corrupt checkpoint.
        var revision = PreconRevision(revisionId: "R1")
        revision.sources = try advImportedPlan(workspace, project: project, lines: ["12 ft"])
        _ = try workspace.store.saveRevision(revision, in: project)
        let checkpoint = try workspace.store.saveCheckpoint(for: revision, in: project)
        try Data("{".utf8).write(to: checkpoint)
        do {
            _ = try workspace.store.resume(from: checkpoint, in: project)
            Issue.record("resuming from a corrupt checkpoint must raise an error")
        } catch let error as PreconProjectError {
            if case .staleCheckpoint = error {
                Issue.record("a corrupt checkpoint must not be classified staleCheckpoint: \(error)")
            }
        } catch { /* any non-staleCheckpoint error classification is acceptable */ }
    }

    // MARK: - F06 vision focus rects

    /// Invariant: a malformed or out-of-page vision rect must produce an error/coverage entry on the unit,
    /// never a silent success and never a crash of the process.
    @Test("F06: malformed and out-of-page crop rects produce an error/coverage entry", arguments: [
        ("negative width", [100.0, 100, -50, 50]),
        ("zero width", [100.0, 100, 0, 50]),
        ("fully outside the page", [5000.0, 5000, 100, 100]),
    ])
    func visionRectSafe(label: String, rect: [Double]) async throws {
        let workspace = try AdvWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let sources = try advImportedPlan(workspace, project: project)
        let mock = AdvInterpreter { _, _ in #"{"candidates": []}"# }
        let pipeline = InterpretationPipeline(store: workspace.store, project: project, interpreter: mock.closure)
        let units: [InterpretationUnit]
        do {
            units = try await pipeline.run(sources, focus: [VisionFocus(sourceId: sources[0].id, rect: rect)])
        } catch let error as TakeoffError {
            #expect(!(error.errorDescription ?? "").isEmpty, "(\(label)) refused with a reason: \(error)")
            #expect(await mock.calls.filter { $0.stage == .vision }.isEmpty, "(\(label)) refused before any vision call")
            return
        }
        let focusUnit = try #require(units.last, "the focus crop must produce a unit")
        #expect(!focusUnit.coverage.isEmpty,
                "F06 invariant (\(label)): a bad crop rect must record an error/coverage entry; got coverage \(focusUnit.coverage)")
        #expect(focusUnit.status != .complete, "(\(label)) a malformed crop must not read as a completed read")
    }

    /// ADVERSARIAL_CRASH=1 required: these rects crash the current process (array index out of range for a
    /// 3-number rect; Int(%) conversion traps on NaN and infinity), so they are not safe to run by default.
    @Test("F06 (crashed before the fix): degenerate numeric crop rects must error, not crash",
          arguments: [
        ("rect with 3 numbers", [100.0, 100, 150]),
        ("NaN rect", [Double.nan, 100, 100, 100]),
        ("infinity rect", [100.0, 100, Double.infinity, 100]),
    ])
    func visionRectCrash(label: String, rect: [Double]) async throws {
        let workspace = try AdvWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let sources = try advImportedPlan(workspace, project: project)
        let mock = AdvInterpreter { _, _ in #"{"candidates": []}"# }
        let pipeline = InterpretationPipeline(store: workspace.store, project: project, interpreter: mock.closure)
        let units: [InterpretationUnit]
        do {
            units = try await pipeline.run(sources, focus: [VisionFocus(sourceId: sources[0].id, rect: rect)])
        } catch let error as TakeoffError {
            #expect(!(error.errorDescription ?? "").isEmpty, "(\(label)) refused with a reason: \(error)")
            #expect(await mock.calls.filter { $0.stage == .vision }.isEmpty, "(\(label)) refused before any vision call")
            return
        }
        let focusUnit = try #require(units.last, "the focus crop must produce a unit")
        #expect(!focusUnit.coverage.isEmpty,
                "F06 invariant (\(label)): a degenerate numeric rect must record an error/coverage entry; got coverage \(focusUnit.coverage)")
        #expect(focusUnit.status != .complete, "(\(label)) a degenerate rect must not read as a completed read")
    }

    // MARK: - F07 unit conversion

    /// Invariant: a 1x1 square in the plane's own length unit must surface as that area expressed in SF
    /// (10.7639 m^2-style conversion), and an unsupported unit string must throw, never silently emit SF.
    @Test("F07: revision SF quantities must convert the plane length unit; unknown units must throw", arguments: [
        ("m", 10.7639104167), ("in", 1.0 / 144.0), ("mm", 10.7639104167e-6),
    ])
    func unitConversion(lengthUnit: String, sfArea: Double) throws {
        let workspace = try AdvWorkspace()
        defer { workspace.cleanUp() }
        let plane = AreaPlane(source: .init(file: "synthetic", sheet: "A-1", pageIndex: 0, revision: "R1"),
                              lengthUnit: lengthUnit, areaUnit: "SF", scale: 1,
                              zones: [.init(id: "Z01", name: "Room", finish: nil)],
                              polys: [.init(id: "G01", zone: "Z01", sign: 1,
                                            pts: [[0, 0], [1, 0], [1, 1], [0, 1]])])
        let (calibration, quantity) = try plane.revisionRecords(
            sourceId: "S1", calibrationId: "CAL1", planeId: "PLAN1", quantityId: "QTY1",
            physicalItemId: "I1", trade: "flooring", location: "Room")
        #expect(quantity.value != nil, "a valid plane must establish the quantity value")
        #expect(quantity.unit == .SF)
        let value = try #require(quantity.value)
        let relative = abs(value - sfArea) / max(abs(sfArea), 1e-300)
        #expect(relative <= 1e-9, "F07 invariant: 1x1 square in \(lengthUnit) must be \(sfArea) SF, got \(value)")
        #expect(calibration.lengthUnit == LengthUnit(rawValue: lengthUnit))
    }

    @Test("F07: unsupported length units must throw, never emit SF", arguments: ["yd", "furlong"])
    func unknownUnitThrows(lengthUnit: String) throws {
        let plane = AreaPlane(source: .init(file: "synthetic", sheet: "A-1", pageIndex: 0, revision: "R1"),
                              lengthUnit: lengthUnit, areaUnit: "SF", scale: 1,
                              zones: [.init(id: "Z01", name: "Room", finish: nil)],
                              polys: [.init(id: "G01", zone: "Z01", sign: 1,
                                            pts: [[0, 0], [1, 0], [1, 1], [0, 1]])])
        #expect(throws: TakeoffError.self,
                "unknown unit \(lengthUnit) must throw instead of producing an SF quantity") {
            try plane.revisionRecords(sourceId: "S1", calibrationId: "CAL1", planeId: "PLAN1", quantityId: "QTY1",
                                      physicalItemId: "I1", trade: "flooring", location: "Room")
        }
    }

    // MARK: - F08 duplicate fixtures across pages

    /// Invariant: per-page quantity rows summed into one revision must collapse the same physical item seen
    /// on two pages (1 fixture, 2 views -> 2 EA means F01 counted once... must total 2 with F02), while two
    /// distinct physical items at the identical point on different pages stay distinct (2 EA).
    @Test("F08: provisional EA totals across pages must count physical items, not page appearances")
    func duplicatesAcrossPages() throws {
        func pageCounting(_ sourceId: String, pageIndex: Int, itemIds: [String]) throws -> TakeoffMeasurements {
            var measurements = TakeoffMeasurements(
                source: SourceRecord(id: sourceId, path: "sources/x/plan.pdf", sha256: "", revision: "R1",
                                     role: .proposed, pageIndex: pageIndex, sheet: ""))
            measurements.counts = itemIds.enumerated().map {
                .init(id: "C\($0.offset + 1)", physicalItemId: $0.element, pt: [100, 100])
            }
            return measurements
        }

        // Page 1 counts F01, F02; page 2 counts F01 again: F01 is one physical item seen twice -> 2 EA.
        let first = try pageCounting("S1", pageIndex: 0, itemIds: ["F01", "F02"])
        let second = try pageCounting("S1-P1", pageIndex: 1, itemIds: ["F01"])
        var revision = PreconRevision(revisionId: "R1")
        revision.quantities = TakeoffMeasurements.quantities(across: [first, second])
        #expect(revision.provisionalTotal(.EA) == 2,
                "F08 invariant: the same physical item on two pages counts once, total 2 EA")

        // Two different physical IDs at identical points on two pages are distinct fixtures -> 2 EA.
        let distinctA = try pageCounting("S2", pageIndex: 0, itemIds: ["F01"])
        let distinctB = try pageCounting("S2-P1", pageIndex: 1, itemIds: ["F02"])
        var distinct = PreconRevision(revisionId: "R2")
        distinct.quantities = TakeoffMeasurements.quantities(across: [distinctA, distinctB])
        #expect(distinct.provisionalTotal(.EA) == 2,
                "distinct fixtures that look identical at the same point on two pages must not be collapsed")
    }

    // MARK: - F09 quote support

    /// Invariant: a quote that happens to appear on the page but does not support the candidate text must
    /// not count as verification ("Room Beta" quoted by "12 ft" stays held; a bare-word quote like "ft" for
    /// text "12 ft" stays held); a quote that genuinely covers the text is offered.
    @Test("F09: unrelated or non-covering quotes must not pass verification")
    func quoteSupport() async throws {
        let workspace = try AdvWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let sources = try advImportedPlan(workspace, project: project, lines: ["Room Beta", "12 ft"])
        let document = try #require(PDFDocument(url: project.appending(path: sources[0].path)))
        let pageText = document.page(at: 0)?.string ?? ""
        #expect(pageText.contains("12 ft") && pageText.contains("Room Beta"),
                "sanity: the synthetic page must carry the text; fix the generator if PDFKit reformats it")

        let mock = AdvInterpreter { _, _ in
            advCandidates([("Room Beta", "12 ft", 0.95), ("12 ft", "ft", 0.95), ("12 ft", "12 ft", 0.95)])
        }
        let pipeline = InterpretationPipeline(store: workspace.store, project: project, interpreter: mock.closure)
        let units = try await pipeline.run(sources)
        let candidates = try #require(units.first?.candidates, "candidates must have been produced")
        #expect(candidates.count == 3)
        // The third candidate is the control: an exact quote for matching text is genuinely supported.
        #expect(candidates[0].heldReason != nil,
                "F09 invariant: quote \"12 ft\" does not support text \"Room Beta\" and the candidate must be held")
        #expect(candidates[1].heldReason != nil,
                "F09 invariant: a bare-word quote \"ft\" (not covering \"12 ft\") must leave the candidate held")
        #expect(candidates[2].heldReason == nil,
                "control: text \"12 ft\" quoted exactly must be offered, not blocked")
        #expect(units[0].status == .held)
    }

    // MARK: - F10 OCR is not verification

    /// Invariant: on a page with no native text, OCR output is model output like any other; a candidate quote
    /// matched against the OCR transcript must not count as independent verification, so the candidate stays
    /// held.
    @Test("F10: a candidate quoted from OCR output must stay held")
    func ocrIsNotVerification() async throws {
        let workspace = try AdvWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let pdf = try advBlankPDF(pages: 1, in: workspace.generated)
        let sources = try workspace.store.importSource(pdf, into: project, role: .proposed, revision: "R1")
        let document = try #require(PDFDocument(url: project.appending(path: sources[0].path)))
        #expect(document.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                "sanity: the synthetic scan page must have no native text")

        let mock = AdvInterpreter { request, _ in
            request.stage == .ocr ? #"{"text": "12 ft", "confidence": 0.9}"# : advCandidates([("12 ft", "12 ft", 0.9)])
        }
        let pipeline = InterpretationPipeline(store: workspace.store, project: project, interpreter: mock.closure)
        let units = try await pipeline.run(sources)
        let unit = try #require(units.first)
        #expect(unit.stage == .ocr, "a textless page must run through OCR")
        #expect(!unit.candidates.isEmpty)
        #expect(unit.candidates.allSatisfy { $0.heldReason != nil },
                "F10 invariant: OCR transcript is not independent verification; every candidate must be held")
        #expect(unit.status == .held)
    }

    // MARK: - Duplicate unit file

    /// Invariant: saving the identical interpretation unit a second time must refuse without touching the
    /// first saved file; the original stays intact and decodable.
    @Test("F11: saving the same interpretation unit twice must not corrupt the first save")
    func duplicateUnitFile() throws {
        let workspace = try AdvWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let unit = InterpretationUnit(id: "U1", sourceId: "S1", pageIndex: 0, stage: .nativeText, status: .complete)
        try workspace.store.saveInterpretation(unit, in: project)
        #expect(throws: (any Error).self, "the second identical save must be refused, not overwrite") {
            try workspace.store.saveInterpretation(unit, in: project)
        }
        let stored = try #require(try workspace.store.interpretation("U1", in: project),
                                  "the first save must survive untouched and decode")
        #expect(stored == unit)
    }
}
