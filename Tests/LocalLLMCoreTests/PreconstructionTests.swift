import Foundation
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
        #expect(try workspace.store.resume(from: checkpoint, in: project) == revision)
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
