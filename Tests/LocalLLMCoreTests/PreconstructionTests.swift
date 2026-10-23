import AppKit
import Foundation
import PDFKit
import Testing
@testable import LocalLLMCore

private let package = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Preconstruction")
private let fixtures = package.appending(path: "fixtures")

private func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    try PreconJSON.decoder.decode(type, from: Data(contentsOf: fixtures.appending(path: name)))
}

private struct ExtraGeometry: Decodable {
    struct Route: Decodable { var id: String; var pts: [[Double]]; var closed: Bool }
    struct Count: Decodable { var physicalItemId: String }
    var scale: Double
    var routes: [Route]
    var counts: [Count]
}

/// Temporary data root standing in for PRECONSTRUCTION_WORKSPACE.
private struct Workspace {
    let root: URL
    let store: PreconProjectStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PreconTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try PreconProjectStore(root: root)
    }

    func project(_ name: String = "Alpha") throws -> URL {
        try store.createProject(named: name, template: package.appending(path: "templates/project"))
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

@Suite("Preconstruction deterministic takeoff")
struct PreconstructionTakeoffTests {
    @Test("A05: area-helper plane yields 120 gross, 6 deduction, 114 net SF")
    func syntheticRoomArea() throws {
        let takeoff = try Takeoff.area(try fixture(AreaPlane.self, "area-plane.json"))
        #expect(takeoff.gross == 120)
        #expect(takeoff.deductions == 6)
        #expect(takeoff.net == 114)
        #expect(takeoff.topology == .unavailable, "containment passed but overlap is unchecked, so topology must not read as passed")
    }

    @Test("A06: reversed orientation and large translation keep the same magnitude")
    func orientationAndTranslation() throws {
        let square = [[0.0, 0], [18, 0], [18, 18], [0, 18]]
        let far = square.reversed().map { [$0[0] + 1e7, $0[1] + 1e7] }
        #expect(abs(Takeoff.signedArea(square)) == abs(Takeoff.signedArea(far)))
    }

    @Test("A07: invalid geometry is rejected before totals", arguments: [
        [[0.0, 0], [10, 10], [10, 0], [0, 10]],
        [[0.0, 0], [10, 0], [10, 0], [0, 10]],
        [[0.0, 0], [.nan, 0], [10, 10]],
        [[0.0, 0], [5, 0], [10, 0]],
    ])
    func rejectsInvalidPolygon(points: [[Double]]) {
        #expect(throws: TakeoffError.self) { try Takeoff.validatePolygon("BAD", points) }
    }

    @Test("A07: invalid scale, sign and duplicate IDs are rejected")
    func rejectsInvalidPlane() throws {
        var plane = try fixture(AreaPlane.self, "area-plane.json")
        var bad = plane; bad.scale = 0
        #expect(throws: TakeoffError.invalidScale) { try Takeoff.area(bad) }
        bad = plane; bad.polys[1].sign = 0
        #expect(throws: TakeoffError.invalidSign("D01")) { try Takeoff.area(bad) }
        plane.polys[1].id = "G01"
        #expect(throws: TakeoffError.duplicateID("G01")) { try Takeoff.area(plane) }
    }

    @Test("A08: a protruding deduction fails topology even though arithmetic still runs")
    func protrudingDeduction() throws {
        var plane = try fixture(AreaPlane.self, "area-plane.json")
        plane.polys[1].pts = [[300, 360], [336, 360], [336, 414], [300, 414]]
        let takeoff = try Takeoff.area(plane)
        #expect(takeoff.topology == .failed)
        #expect(takeoff.topologyNotes.first?.contains("D01") == true)
        #expect(throws: TakeoffError.self) {
            try plane.revisionRecords(sourceId: "S01", calibrationId: "CAL01", planeId: "PLAN-FLOOR", quantityId: "QTY01",
                                      physicalItemId: "FLOOR01", trade: "flooring", location: "Room Alpha")
        }
    }

    @Test("A09: X 18 and Y 20 points/ft is a conflict with no averaged scale")
    func calibrationConflict() {
        let checks = [CalibrationCheck(axis: .x, coordinateLength: 216, realLength: 12, datum: "x witness"),
                      CalibrationCheck(axis: .y, coordinateLength: 200, realLength: 10, datum: "y witness")]
        let result = Calibration.evaluate(checks)
        #expect(result.status == .conflict)
        #expect(result.scale == nil)
    }

    @Test("A09: matching independent X/Y checks give a candidate, one axis alone does not")
    func calibrationCandidate() {
        let x = CalibrationCheck(axis: .x, coordinateLength: 216, realLength: 12, datum: "x witness")
        let y = CalibrationCheck(axis: .y, coordinateLength: 180, realLength: 10, datum: "y witness")
        #expect(Calibration.evaluate([x, y]).scale == 18)
        #expect(Calibration.evaluate([x, y]).status == .candidate)
        #expect(Calibration.evaluate([x]).status == .unestablished)
    }

    @Test("A12/A13: open 12 + 10 ft route is 22 LF and repeated views count 2 EA")
    func routeAndCounts() throws {
        let extra = try fixture(ExtraGeometry.self, "extra-geometry.json")
        let route = extra.routes[0]
        #expect(!route.closed)
        #expect(try Takeoff.length(route.id, route.pts, scale: extra.scale, closed: route.closed) == 22)
        #expect(Takeoff.physicalCount(extra.counts.map(\.physicalItemId)) == 2)
    }

    @Test("A14/A15: retained work stays out of new totals and unknown stays null")
    func totalsAndUnknowns() throws {
        let revision = try fixture(PreconRevision.self, "revision.json")
        #expect(revision.provisionalTotal(.SF, trade: "flooring") == 114)
        #expect(revision.releasedTotal(.SF, trade: "flooring") == nil)
        #expect(revision.quantities.first { $0.id == "QTY03" }?.value == nil)
        #expect(revision.unfinishedMeasurements.map(\.id) == ["U01"])
        let encoded = String(decoding: try PreconJSON.encoder.encode(revision.quantities[2]), as: UTF8.self)
        #expect(encoded.contains("\"value\" : null"), "unknown must serialize as explicit null, as the schema requires")
        var withUnknown = revision
        withUnknown.quantities[2].scopeState = .provisional
        #expect(withUnknown.provisionalTotal(.SF) == nil, "an unknown component makes the subtotal unknown, not 114")
    }

    @Test("A16/A39: release is blocked by the open conflict, pending checks and missing approvals")
    func releaseHeld() throws {
        let revision = try fixture(PreconRevision.self, "revision.json")
        let blockers = try revision.releaseBlockers()
        #expect(blockers.contains("Q01 is open"))
        #expect(blockers.contains("U01 is unfinished"))
        #expect(blockers.contains("QTY03 quantity is unestablished"))
        #expect(blockers.contains { $0.hasPrefix("scope_release approval missing") })
    }

    @Test("approval binds the snapshot digest and goes stale when the revision changes")
    func approvalBinding() throws {
        var revision = PreconRevision(revisionId: "R1")
        let calibration = Calibration(id: "CAL01", sourceId: "S01", frameId: "F", planeId: "PLAN-FLOOR",
                                      coordinateUnit: .pdfPoints, lengthUnit: .ft, scale: 18, status: .reviewed, checks: [])
        revision.calibrations = [calibration]
        let digest = try revision.snapshotDigest()
        revision.approvals = [.reviewedGeometry, .scopeRelease].map {
            ApprovalRecord(gate: $0, status: .approved, snapshotSha256: digest, actor: "reviewer", at: "2026-10-19")
        }
        #expect(try revision.releaseBlockers().isEmpty)
        revision.calibrations[0].scale = 20
        #expect(try revision.releaseBlockers().count == 2)
    }

    @Test("area-plane adapter produces a candidate calibration and provisional 114 SF row")
    func adapter() throws {
        let (calibration, quantity) = try fixture(AreaPlane.self, "area-plane.json")
            .revisionRecords(sourceId: "S01", calibrationId: "CAL01", planeId: "PLAN-FLOOR", quantityId: "QTY01",
                             physicalItemId: "FLOOR01", trade: "flooring", location: "Room Alpha")
        #expect(calibration.status == .candidate)
        #expect(calibration.scale == 18)
        #expect(quantity.value == 114)
        #expect(quantity.scopeState == .provisional)
        #expect(quantity.geometryRefs == ["G01", "D01"])
        #expect(!quantity.installedTotalEligible)
    }

    @Test("scope preview is labeled, plain ASCII, states 114 SF and never turns unknown into zero")
    func scopePreview() throws {
        let text = ScopePreview.render(try fixture(PreconRevision.self, "revision.json"))
        #expect(text.hasPrefix("SCOPE PREVIEW - DETERMINISTIC TEMPLATE - NOT MODEL GENERATED - NOT RELEASED"))
        let ascii = text.unicodeScalars.allSatisfy(\.isASCII)
        #expect(ascii)
        #expect(text.contains("-QTY01 Room Alpha flooring install: 114 SF - provisional."))
        #expect(text.contains("40 SF - existing retained, reference only, not new work."))
        #expect(text.contains("-QTY03 Room Alpha tile install: not established (SF)"))
        #expect(!text.contains("120 SF"))
        #expect(!text.contains("$"))
    }
}

@Suite("Preconstruction project intake and persistence")
struct PreconstructionProjectTests {
    @Test("A01: new project copies the template registers and holds no quantities")
    func emptyProject() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        #expect(FileManager.default.fileExists(atPath: project.appending(path: "registers/sources.csv").path))
        #expect(FileManager.default.fileExists(atPath: project.appending(path: "checkpoints/checkpoint-template.md").path))
        #expect(throws: PreconProjectError.alreadyExists("Alpha")) { try workspace.project() }
    }

    @Test("A03: unsafe project names are rejected", arguments: ["../escape", "a/b", ".hidden", "", "x..y"])
    func unsafeNames(name: String) throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        #expect(throws: PreconProjectError.invalidName(name)) { try workspace.project(name) }
    }

    @Test("intake copies, hashes and locks the original without changing it")
    func immutableIntake() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let original = fixtures.appending(path: "synthetic-plan.pdf")
        let before = try StableDigest.file(original)
        let records = try workspace.store.importSource(original, into: project, role: .proposed, revision: "SYN-R1",
                                                      sheets: ["A-SYN-1"])
        #expect(records.count == 1)
        #expect(records[0].sha256 == "9b525f51cfb03e77d778ad09b5ec8d288236f13e8402b557decdcd1d57ebaf81")
        #expect(records[0].pageIndex == 0 && records[0].sheet == "A-SYN-1")
        #expect(try StableDigest.file(original) == before)
        let stored = project.appending(path: records[0].path)
        #expect(!FileManager.default.isWritableFile(atPath: stored.path))
        #expect(try workspace.store.importSource(original, into: project, role: .proposed, revision: "SYN-R1") == records.map {
            var unsheeted = $0; unsheeted.sheet = ""; return unsheeted
        })
    }

    @Test("A02: same filename with changed bytes is retained as a second source")
    func sameNameChangedBytes() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let staging = workspace.root.appending(path: "incoming")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let file = staging.appending(path: "note.txt")
        try Data("R1 wood".utf8).write(to: file)
        let first = try workspace.store.importSource(file, into: project, role: .specification, revision: "R1")
        try Data("R2 tile".utf8).write(to: file)
        let second = try workspace.store.importSource(file, into: project, role: .specification, revision: "R2")
        #expect(first[0].id != second[0].id)
        #expect(first[0].path != second[0].path)
        #expect(try String(contentsOf: project.appending(path: first[0].path), encoding: .utf8) == "R1 wood")
    }

    @Test("A03: symlinked sources, non-file URLs and projects escaping the root are refused")
    func refusesEscapes() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let link = workspace.root.appending(path: "link.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixtures.appending(path: "synthetic-plan.pdf"))
        #expect(throws: PreconProjectError.self) { try workspace.store.importSource(link, into: project, role: .proposed, revision: "R1") }
        let remote = URL(string: "https://example.com/plan.pdf")!
        #expect(throws: PreconProjectError.self) { try workspace.store.importSource(remote, into: project, role: .proposed, revision: "R1") }
        let outside = workspace.root.appending(path: "outside-project")
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: FileManager.default.temporaryDirectory)
        #expect(throws: PreconProjectError.self) {
            try workspace.store.importSource(fixtures.appending(path: "synthetic-plan.pdf"), into: outside, role: .proposed, revision: "R1")
        }
    }

    @Test("revisions save once, reopen from a checkpoint and are never overwritten")
    func saveAndResume() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let (project, revision, checkpoint) = try savedRevision(workspace)
        #expect(try workspace.store.resume(from: checkpoint, in: project).0 == revision)
        #expect(throws: PreconProjectError.alreadyExists("R1.json")) { try workspace.store.saveRevision(revision, in: project) }
    }

    @Test("A24: one changed source byte rejects the checkpoint")
    func staleSource() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let (project, revision, checkpoint) = try savedRevision(workspace)
        let stored = project.appending(path: revision.sources[0].path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stored.path)
        var bytes = try Data(contentsOf: stored)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: stored)
        #expect(throws: PreconProjectError.staleCheckpoint(["source \(revision.sources[0].path) changed"])) {
            try workspace.store.resume(from: checkpoint, in: project)
        }
    }

    @Test("A24: a corrupt checkpoint or edited revision is rejected")
    func corruptCheckpoint() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let (project, revision, checkpoint) = try savedRevision(workspace)
        let revisionURL = project.appending(path: "revisions/\(revision.revisionId).json")
        var edited = revision
        edited.calibrations[0].scale = 20
        try PreconJSON.encoder.encode(edited).write(to: revisionURL)
        #expect(throws: PreconProjectError.staleCheckpoint(["revision R1 changed"])) {
            try workspace.store.resume(from: checkpoint, in: project)
        }
        try Data("{".utf8).write(to: checkpoint)
        #expect(throws: PreconProjectError.staleCheckpoint(["checkpoint unreadable or corrupt"])) {
            try workspace.store.resume(from: checkpoint, in: project)
        }
    }

    private func savedRevision(_ workspace: Workspace) throws -> (URL, PreconRevision, URL) {
        let project = try workspace.project()
        var revision = PreconRevision(revisionId: "R1", synthetic: true)
        revision.sources = try workspace.store.importSource(fixtures.appending(path: "synthetic-plan.pdf"), into: project,
                                                           role: .proposed, revision: "SYN-R1", sheets: ["A-SYN-1"])
        let (calibration, quantity) = try fixture(AreaPlane.self, "area-plane.json")
            .revisionRecords(sourceId: revision.sources[0].id, calibrationId: "CAL01", planeId: "PLAN-FLOOR",
                             quantityId: "QTY01", physicalItemId: "FLOOR01", trade: "flooring", location: "Room Alpha")
        revision.calibrations = [calibration]
        revision.quantities = [quantity]
        _ = try workspace.store.saveRevision(revision, in: project)
        return (project, revision, try workspace.store.saveCheckpoint(for: revision, in: project))
    }
}

@Suite("Preconstruction traced measurements")
struct PreconstructionMeasurementTests {
    private func traced(yCoordinateLength: Double = 180) throws -> TakeoffMeasurements {
        let plane = try fixture(AreaPlane.self, "area-plane.json")
        let extra = try fixture(ExtraGeometry.self, "extra-geometry.json")
        var measurements = TakeoffMeasurements(source: SourceRecord(id: "S01", path: "sources/x/synthetic-plan.pdf", sha256: "",
                                                                    revision: "SYN-R1", role: .proposed, pageIndex: 0, sheet: "A-SYN-1"))
        measurements.calibrationChecks = [
            CalibrationCheck(axis: .x, coordinateLength: 216, realLength: 12, datum: "x witness"),
            CalibrationCheck(axis: .y, coordinateLength: yCoordinateLength, realLength: 10, datum: "y witness"),
        ]
        measurements.polys = plane.polys
        measurements.routes = extra.routes.map { .init(id: $0.id, pts: $0.pts, closed: $0.closed) }
        measurements.counts = extra.counts.enumerated().map { .init(id: "C\($0.offset)", physicalItemId: $0.element.physicalItemId, pt: [0, 0]) }
        return measurements
    }

    @Test("A05/A12/A13: traced geometry yields 114 SF, 22 LF and 2 EA under a candidate calibration")
    func tracedQuantities() throws {
        let measurements = try traced()
        #expect(measurements.calibration.status == .candidate)
        #expect(measurements.quantities().map(\.value) == [114, 22, 2])
        #expect(measurements.plane?.zones.map(\.id) == ["Z01"])
        #expect(measurements.checks().map(\.status) == [.passed, .unavailable], "topology is recorded as unavailable, never passed")
    }

    @Test("A09: a calibration conflict withholds every scaled value instead of averaging")
    func conflictWithholdsValues() throws {
        let measurements = try traced(yCoordinateLength: 200)
        #expect(measurements.calibration.status == .conflict)
        #expect(measurements.plane == nil)
        let values = measurements.quantities().map(\.value)
        #expect(values[0] == nil && values[1] == nil)
        #expect(values[2] == 2, "counts do not depend on scale")
    }

    @Test("reviewing calibration only promotes a candidate, never a conflict")
    func reviewOnlyPromotesCandidate() throws {
        var conflict = try traced(yCoordinateLength: 200)
        conflict.calibrationReviewed = true
        #expect(conflict.calibration.status == .conflict)
        var candidate = try traced()
        candidate.calibrationReviewed = true
        #expect(candidate.calibration.status == .reviewed)
    }

    @Test("A24: editing a saved measurement file rejects the checkpoint")
    func staleMeasurement() throws {
        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let measurements = try traced()
        let path = try workspace.store.saveMeasurement(try PreconJSON.encoder.encode(measurements.plane), named: "R1-plane.json", in: project)
        var revision = PreconRevision(revisionId: "R1")
        revision.quantities = measurements.quantities()
        _ = try workspace.store.saveRevision(revision, in: project)
        let checkpoint = try workspace.store.saveCheckpoint(for: revision, in: project, measurements: [path])
        #expect(try workspace.store.resume(from: checkpoint, in: project).1.measurementDigests.keys.sorted() == [path])
        try Data("{}".utf8).write(to: project.appending(path: path))
        #expect(throws: PreconProjectError.staleCheckpoint(["measurement \(path) changed"])) {
            try workspace.store.resume(from: checkpoint, in: project)
        }
    }

    @Test("two traced pages keep distinct quantity and check IDs and per-page measurement files")
    func perPageDrafts() throws {
        let first = try traced()
        var second = try traced()
        second.source.id = "S01-P1"
        second.source.pageIndex = 1
        let quantities = [first, second].flatMap { $0.quantities() }
        let checks = [first, second].flatMap { $0.checks() }
        #expect(Set(quantities.map(\.id)).count == quantities.count && quantities.count == 6)
        #expect(Set(checks.map(\.id)).count == checks.count)
        #expect(quantities.map(\.value) == [114, 22, 2, 114, 22, 2])

        let workspace = try Workspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let paths = try [first, second].map {
            try workspace.store.saveMeasurement(try PreconJSON.encoder.encode($0), named: "R12-\($0.source.id)-measurements.json", in: project)
        }
        #expect(paths == ["measurements/R12-S01-measurements.json", "measurements/R12-S01-P1-measurements.json"])
    }
}

@Suite("Preconstruction page frame")
struct PreconstructionPageFrameTests {
    /// One-page PDF with an offset media box and an 8 pt black mark centred at `mark` in the stored top-left frame.
    private func markedPage(rotation: Int, mark: [Double], in directory: URL) throws -> PDFDocument {
        var box = CGRect(x: 50, y: 100, width: 612, height: 792)
        let raw = directory.appending(path: "raw.pdf")
        let context = try #require(CGContext(raw as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: box.minX + mark[0] - 4, y: box.maxY - mark[1] - 4, width: 8, height: 8))
        context.endPDFPage()
        context.closePDF()
        let document = try #require(PDFDocument(url: raw))
        document.page(at: 0)?.rotation = rotation
        let rotated = directory.appending(path: "rotated-\(rotation).pdf")
        #expect(document.write(to: rotated))
        return try #require(PDFDocument(url: rotated))
    }

    @Test("A10: rotated, offset media box maps a rendered mark back to its stored point", arguments: [0, 90, 180, 270])
    func renderedMarkRoundTrips(rotation: Int) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PageFrame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mark = [100.0, 200.0]
        let document = try markedPage(rotation: rotation, mark: mark, in: directory)
        let page = try #require(document.page(at: 0))
        let frame = PageFrame(page)
        #expect(frame.rotation == rotation)
        #expect(frame.toPage(frame.toDisplay(mark)) == mark)

        let scale = 1.5
        let image = PageFrame.render(page, scale: scale)
        let rep = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let pixelsPerPoint = Double(rep.pixelsWide) / image.size.width
        #expect(abs(image.size.width - frame.displaySize.width * scale) < 1 && abs(image.size.height - frame.displaySize.height * scale) < 1)
        var (sx, sy, n) = (0.0, 0.0, 0.0)
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.5 {
            sx += Double(x) + 0.5; sy += Double(y) + 0.5; n += 1
        } }
        #expect(n > 0)
        let display = [sx / n / pixelsPerPoint / scale, sy / n / pixelsPerPoint / scale]
        let found = frame.toPage(display)
        #expect(abs(found[0] - mark[0]) < 1 && abs(found[1] - mark[1]) < 1, "rotation \(rotation): display \(display) -> \(found)")
    }
}

/// Scripted stand-in for a local model: records every call and answers from a closure.
private actor MockInterpreter {
    private(set) var calls: [InterpretationRequest] = []
    private(set) var imagesExisted: [Bool] = []
    let answer: @Sendable (InterpretationRequest, Int) throws -> String

    init(_ answer: @escaping @Sendable (InterpretationRequest, Int) throws -> String) { self.answer = answer }

    func handle(_ request: InterpretationRequest) throws -> String {
        calls.append(request)
        imagesExisted.append(request.image.map { FileManager.default.fileExists(atPath: $0.path) } ?? true)
        return try answer(request, calls.count)
    }

    nonisolated var closure: PreconInterpreter { { try await self.handle($0) } }
}

private struct MockFailure: Error {}

private func candidates(_ items: [(String, String?, Double)]) -> String {
    let rows = items.map { text, quote, confidence in
        #"{"kind": "dimension", "text": "\#(text)", "quote": \#(quote.map { "\"\($0)\"" } ?? "null"), "confidence": \#(confidence)}"#
    }
    return #"{"candidates": [\#(rows.joined(separator: ","))]}"#
}

/// Text-free pages, so every page goes to OCR.
private func blankPDF(pages: Int, in directory: URL) throws -> URL {
    let url = directory.appending(path: "scan-\(pages).pdf")
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
    for _ in 0..<pages {
        context.beginPDFPage(nil); context.stroke(box.insetBy(dx: 36, dy: 36)); context.endPDFPage()
    }
    context.closePDF()
    return url
}

@Suite("Preconstruction assisted interpretation")
struct PreconstructionInterpretationTests {
    private func plan(_ workspace: Workspace) throws -> (URL, [SourceRecord]) {
        let project = try workspace.project()
        return (project, try workspace.store.importSource(fixtures.appending(path: "synthetic-plan.pdf"), into: project,
                                                           role: .proposed, revision: "SYN-R1", sheets: ["A-SYN-1"]))
    }

    private func scan(_ workspace: Workspace, pages: Int) throws -> (URL, [SourceRecord]) {
        let project = try workspace.project()
        return (project, try workspace.store.importSource(try blankPDF(pages: pages, in: workspace.root), into: project,
                                                           role: .proposed, revision: "R1"))
    }

    private func fileDigests(_ directory: URL) -> [String: String] {
        let paths = (FileManager.default.enumerator(atPath: directory.path)?.allObjects as? [String]) ?? []
        return Dictionary(uniqueKeysWithValues: paths.compactMap { path in
            (try? StableDigest.file(directory.appending(path: path))).map { (path, $0) }
        })
    }

    @Test("A17: native text first; unquoted, invented and low-confidence candidates are held and nothing else is written")
    func heldCandidates() async throws {
        let workspace = try Workspace(); defer { workspace.cleanUp() }
        let (project, sources) = try plan(workspace)
        var revision = PreconRevision(revisionId: "R1", synthetic: true)
        revision.sources = sources
        _ = try workspace.store.saveRevision(revision, in: project)
        _ = try workspace.store.saveMeasurement(Data("{}".utf8), named: "R1-plane.json", in: project)
        let checkpoint = try workspace.store.saveCheckpoint(for: revision, in: project, measurements: ["measurements/R1-plane.json"])
        let before = (fileDigests(project.appending(path: "revisions")), fileDigests(project.appending(path: "measurements")))
        let mock = MockInterpreter { _, _ in
            candidates([("12 ft", "12 ft - finished faces", 0.9), ("Room Beta", "ROOM BETA", 0.95),
                        ("14 ft", nil, 0.9), ("10 ft", "10 ft", 0.3)])
        }
        let units = try await InterpretationPipeline(store: workspace.store, project: project, interpreter: mock.closure).run(sources)
        #expect(units.map(\.stage) == [.nativeText] && units[0].status == .held)
        #expect(await mock.calls.allSatisfy { $0.image == nil && $0.text != nil })
        #expect(units[0].candidates.map(\.heldReason) == [nil, "quote not found in source text", "no source quote", "low confidence"])
        #expect(fileDigests(project.appending(path: "revisions")) == before.0)
        #expect(fileDigests(project.appending(path: "measurements")) == before.1)
        #expect(!before.0.isEmpty && !before.1.isEmpty)
        #expect(try workspace.store.resume(from: checkpoint, in: project).0 == revision)
    }

    @Test("A18/A19: one image per OCR call; failed and repeating pages stay incomplete with no candidates; IDs survive resume")
    func sequentialOCR() async throws {
        let workspace = try Workspace(); defer { workspace.cleanUp() }
        let (project, sources) = try scan(workspace, pages: 3)
        // Answers keyed by unit: the pipeline visits pages in order, so map unit IDs to pages first.
        var pipeline = InterpretationPipeline(store: workspace.store, project: project, interpreter: { _ in "" })
        let ids = sources.map { pipeline.unitID($0, focus: nil) }
        let scripted = MockInterpreter { request, _ in
            if request.stage != .ocr { return candidates([("12 ft", "12 ft", 0.9)]) }
            switch ids.firstIndex(of: request.unitId) {
            case 0: return #"{"text": "ROOM ALPHA\n12 ft", "confidence": 0.9}"#
            case 1: throw MockFailure()
            default: return #"{"text": "12 ft\n12 ft\n12 ft\n12 ft", "confidence": 0.9}"#
            }
        }
        pipeline.interpreter = scripted.closure
        let units = try await pipeline.run(sources)
        #expect(units.map(\.status) == [.complete, .incomplete, .incomplete])
        #expect(units[1].candidates.isEmpty && units[2].candidates.isEmpty)
        #expect(units[1].coverage.first?.hasPrefix("page 2 OCR failed") == true)
        #expect(units[2].coverage == ["page 3 OCR unreadable: repeated output"])
        let ocrCalls = await scripted.calls.filter { $0.stage == .ocr }
        #expect(ocrCalls.count == 3 && ocrCalls.allSatisfy { $0.image != nil && $0.text == nil })
        #expect(await scripted.imagesExisted.allSatisfy { $0 })
        #expect(ocrCalls.allSatisfy { !FileManager.default.fileExists(atPath: $0.image!.deletingLastPathComponent().path) })
        let again = try await pipeline.run(sources)
        #expect(again[0].candidates.map(\.id) == units[0].candidates.map(\.id))
        #expect(await scripted.calls.count == 4 + 2) // page 1 reused; pages 2 and 3 retried once each
    }

    @Test("A20: text over budget is chunked and the remainder is recorded as uninterpreted")
    func inputBudget() async throws {
        let workspace = try Workspace(); defer { workspace.cleanUp() }
        let (project, sources) = try plan(workspace)
        let mock = MockInterpreter { _, _ in candidates([]) }
        var pipeline = InterpretationPipeline(store: workspace.store, project: project, interpreter: mock.closure)
        pipeline.budget = InterpretationBudget(maxInputChars: 80, maxChunks: 2, reservedOutputTokens: 256)
        let units = try await pipeline.run(sources)
        let calls = await mock.calls
        #expect(calls.count == 2 && calls.allSatisfy { ($0.text?.count ?? 0) <= 80 && $0.maxOutputTokens == 256 })
        #expect(units[0].status == .partial)
        #expect(units[0].coverage.first?.contains("text chunks not interpreted (input budget)") == true)
    }

    @Test("A21/A23: a busy machine defers before any call; resume reruns only unfinished units")
    func deferAndResume() async throws {
        let workspace = try Workspace(); defer { workspace.cleanUp() }
        let (project, sources) = try scan(workspace, pages: 2)
        let mock = MockInterpreter { request, _ in
            request.stage == .ocr ? #"{"text": "12 ft", "confidence": 0.9}"# : candidates([("12 ft", "12 ft", 0.9)])
        }
        let allowed = Counter()
        var pipeline = InterpretationPipeline(store: workspace.store, project: project, interpreter: mock.closure)
        pipeline.gate = { allowed.next() <= 2 ? nil : "pricing workload active" }
        let first = try await pipeline.run(sources)
        #expect(first.map(\.status) == [.complete, .deferred])
        #expect(first[1].coverage == ["page 2 OCR deferred: pricing workload active"])
        #expect(await mock.calls.count == 2)
        pipeline.gate = { nil }
        let second = try await pipeline.run(sources)
        #expect(second.map(\.status) == [.complete, .complete] && second[0] == first[0])
        #expect(await mock.calls.count == 4)
    }

    @Test("A22: malformed output after one constrained retry fails the unit without saving or a third call")
    func malformedOutput() async throws {
        let workspace = try Workspace(); defer { workspace.cleanUp() }
        let (project, sources) = try plan(workspace)
        let mock = MockInterpreter { _, _ in "Sure! Here are the dimensions: 12 ft" }
        let pipeline = InterpretationPipeline(store: workspace.store, project: project, interpreter: mock.closure)
        let units = try await pipeline.run(sources)
        #expect(units[0].status == .failed && units[0].candidates.isEmpty)
        #expect(await mock.calls.map(\.isRetry) == [false, true])
        #expect(try workspace.store.interpretation(units[0].id, in: project) == nil)
    }

    @Test("focused vision reads one crop and holds candidates whose quote is not on the page")
    func visionFocus() async throws {
        let workspace = try Workspace(); defer { workspace.cleanUp() }
        let (project, sources) = try plan(workspace)
        let mock = MockInterpreter { request, _ in
            request.stage == .vision ? candidates([("10 ft", "10 ft", 0.9), ("14 ft", "14 ft", 0.9)]) : candidates([])
        }
        let pipeline = InterpretationPipeline(store: workspace.store, project: project, interpreter: mock.closure)
        let focus = VisionFocus(sourceId: sources[0].id, rect: [100, 100, 200, 150])
        let units = try await pipeline.run(sources, focus: [focus])
        #expect(units.map(\.stage) == [.nativeText, .vision])
        #expect(units[1].candidates.map(\.heldReason) == [nil, "quote not found in source text"])
        let document = try #require(PDFDocument(url: project.appending(path: sources[0].path)))
        let crop = try InterpretationPipeline.png(try #require(document.page(at: 0)), crop: focus.rect)
        let size = try #require(NSBitmapImageRep(data: crop)).size
        #expect(abs(size.width / size.height - 200.0 / 150.0) < 0.02)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
