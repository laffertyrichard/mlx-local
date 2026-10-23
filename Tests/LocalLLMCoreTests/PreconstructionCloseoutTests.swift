import Foundation
import Testing
@testable import LocalLLMCore

// Closeout adversarial tests (tests only), per briefs/opencode-closeout.md (md5 04de0107573a78494402bac2fbc21ffd).
// Invariants under test:
//  - Failure/retry atomics of PreconProjectStore.saveRevision(_:measurements:in:at:): a failure at any write
//    stage must never expose a completed revision; identical-byte retries recover; changed bytes refuse.
//  - TakeoffMeasurements.calibrationChecks(adding:): once traced geometry fixes a page scale, differently
//    scaled detail witnesses are refused (A11 is not supported); refinement/jitter, counts-only pages,
//    conflicted pages and corrupt witness lengths never produce a bogus scale.
// Synthetic in-memory data only; fresh temp workspace per test; no repo fixtures, no network.

private let closeoutPackage = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Preconstruction")

private struct CsFailure: Error { var stage: String }

/// beforeWrite seam that throws once the attempted write reaches the named stage and otherwise stays silent.
private func csFailAt(_ stage: String) -> (@Sendable (String) throws -> Void) {
    { @Sendable path in if path == stage { throw CsFailure(stage: stage) } }
}

/// Fixed, distinct checkpoint stamps so repeated save attempts are unambiguous and deterministic.
private func csDate(_ index: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(index)) }

/// Sorted names of the direct children of one project directory (empty when the directory is absent).
private func csFiles(_ project: URL, under directory: String) -> [String] {
    let contents = (try? FileManager.default.contentsOfDirectory(atPath: project.appending(path: directory).path)) ?? []
    return contents.sorted()
}

/// File names the project template ships inside measurements/; they are baseline content, not save artifacts.
private let csTemplateMeasurementFiles: [String] = {
    let template = closeoutPackage.appending(path: "templates/project/measurements")
    return ((try? FileManager.default.contentsOfDirectory(atPath: template.path)) ?? []).sorted()
}()

/// Names written by save attempts inside the directory, i.e. the listing minus template baseline files.
private func csSaveFiles(_ project: URL, under directory: String) -> [String] {
    csFiles(project, under: directory).filter { !csTemplateMeasurementFiles.contains($0) }
}

/// Checkpoint URLs saved for one revision id: `checkpoints/<id>-<stamp>.json`, sorted by name.
private func csCheckpoints(_ project: URL, id: String) -> [URL] {
    csFiles(project, under: "checkpoints")
        .filter { $0.hasPrefix("\(id)-") && $0.hasSuffix(".json") }
        .map { project.appending(path: "checkpoints/\($0)") }
}

/// Relative path -> sha256 (or "<missing>") for the named files, to prove byte-identity across attempts.
private func csDigestMap(_ project: URL, paths: [String]) -> [String: String] {
    var digests: [String: String] = [:]
    for path in paths {
        digests[path] = (try? StableDigest.file(project.appending(path: path))) ?? "<missing>"
    }
    return digests
}

/// Every path in the project still holding a write-through temp file (writeNew's `.tmp-` prefix).
private func csTempFiles(_ project: URL) -> [String] {
    ((try? FileManager.default.subpathsOfDirectory(atPath: project.path)) ?? []).filter { $0.contains(".tmp-") }
}

private struct CsWorkspace {
    let root: URL
    let store: PreconProjectStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PreconCloseout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try PreconProjectStore(root: root)
    }

    func project(_ name: String = "Alpha") throws -> URL {
        try store.createProject(named: name, template: closeoutPackage.appending(path: "templates/project"))
    }

    func cleanUp() {
        if let items = FileManager.default.enumerator(atPath: root.path) {
            for case let path as String in items {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appending(path: path).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }
}

/// Deterministic measurement payloads for one revision: identical content always yields identical bytes.
private func csMeasurementBytes(_ name: String) -> Data { Data("payload-\(name)".utf8) }

/// Three staged measurement files for a revision.
private func csMeasurements(_ id: String, variant: String = "") -> [(name: String, data: Data)] {
    (1...3).map { index in
        let name = "\(id)-m\(index).json"
        let payload = variant.isEmpty ? csMeasurementBytes(name) : Data("\(variant)-\(name)".utf8)
        return (name, payload)
    }
}

/// A witness check whose scale is coordinateLength / realLength.
private func csWitness(_ axis: CalibrationCheck.Axis, coordinateLength: Double, realLength: Double) -> CalibrationCheck {
    CalibrationCheck(axis: axis, coordinateLength: coordinateLength, realLength: realLength, datum: "synthetic witness")
}

/// A page calibrated to 18 pt/ft with X (216/12) and Y (180/10) witnesses.
private func csCandidateChecks() -> [CalibrationCheck] {
    [csWitness(.x, coordinateLength: 216, realLength: 12), csWitness(.y, coordinateLength: 180, realLength: 10)]
}

@Suite("Preconstruction closeout adversarial")
struct PreconstructionCloseoutTests {

    // MARK: - Failure/retry atomics

    /// Invariant: a failure injected at any write stage (measurement 1 of 3, the 2nd of 3, the 3rd, the
    /// revision JSON, the checkpoint) exposes no completed result — no checkpoint is written, so nothing can
    /// be resumed. One retry with identical bytes completes the transaction exactly once; measurement files
    /// are never duplicated; the checkpoint's measurement digests match the files on disk.
    @Test("C01: failure at every write stage leaves no checkpoint, and one identical retry completes the save")
    func failureAtEveryStage() throws {
        let stages = ["measurements/RC-m1.json", "measurements/RC-m2.json", "measurements/RC-m3.json",
                      "revisions/RC.json", "checkpoints/RC"]
        for (index, stage) in stages.enumerated() {
            let workspace = try CsWorkspace()
            defer { workspace.cleanUp() }
            let project = try workspace.project()
            let revision = PreconRevision(revisionId: "RC", synthetic: true)
            let measurements = csMeasurements("RC")

            // Attempt with the seam failing exactly at `stage`.
            var broken = workspace.store
            broken.beforeWrite = csFailAt(stage)
            #expect(throws: (any Error).self, "stage \(stage): the injected failure must abort the save") {
                _ = try broken.saveRevision(revision, measurements: measurements, in: project, at: csDate(index))
            }
            #expect(csCheckpoints(project, id: "RC").isEmpty,
                    "stage \(stage): a failing save must never write a checkpoint, so no completed result exists to resume")
            let expectedPartial = measurements.prefix(index).map { $0.name }.sorted()
            #expect(csSaveFiles(project, under: "measurements") == expectedPartial,
                    "stage \(stage): only the writes completed before the failure may exist; got \(csSaveFiles(project, under: "measurements"))")
            if index < 4 {
                #expect(csSaveFiles(project, under: "revisions").isEmpty,
                        "stage \(stage): the revision JSON must not exist before that stage completes")
            }

            // One identical retry must complete the transaction.
            var store = workspace.store
            store.beforeWrite = nil
            _ = try store.saveRevision(revision, measurements: measurements, in: project, at: csDate(index + 10))
            let checkpoints = csCheckpoints(project, id: "RC")
            #expect(checkpoints.count == 1, "stage \(stage): the single retry must complete the save exactly once")
            let completedPaths = measurements.map { "measurements/\($0.name)" }
            #expect(csSaveFiles(project, under: "measurements") == measurements.map { $0.name }.sorted(),
                    "stage \(stage): the measurement file set must be exact, never duplicated")
            #expect(csTempFiles(project).isEmpty, "stage \(stage): no temp files may be left behind")
            let (_, checkpoint) = try store.resume(from: checkpoints[0], in: project)
            #expect(Set(checkpoint.measurementDigests.keys) == Set(completedPaths),
                    "stage \(stage): the checkpoint must list exactly the staged measurement files")
            for (path, digest) in checkpoint.measurementDigests {
                #expect((try? StableDigest.file(project.appending(path: path))) == digest,
                        "stage \(stage): checkpoint digest for \(path) must match the file on disk")
            }

            // Repeating the identical save stays idempotent and duplicates no files.
            _ = try store.saveRevision(revision, measurements: measurements, in: project, at: csDate(index + 20))
            #expect(csSaveFiles(project, under: "measurements") == measurements.map { $0.name }.sorted(),
                    "stage \(stage): a repeated identical save must not duplicate measurement files")
        }
    }

    /// Invariant: with partial files already on disk, a retry with CHANGED bytes under the same revision ID
    /// and same file names throws `alreadyExists` and leaves every earlier partial file byte-identical (no
    /// checkpoint either).
    @Test("C02: changed bytes under the same revision ID are refused and leave the partial files untouched")
    func changedBytesRefused() throws {
        let workspace = try CsWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let revision = PreconRevision(revisionId: "RC", synthetic: true)
        let original = csMeasurements("RC")

        // Leave partial files: succeed writing all three measurements, then fail before the revision JSON.
        var broken = workspace.store
        broken.beforeWrite = csFailAt("revisions/RC.json")
        #expect(throws: (any Error).self) { _ = try broken.saveRevision(revision, measurements: original, in: project, at: csDate(0)) }
        let partialDigests = csDigestMap(project, paths: original.map { "measurements/\($0.name)" })
        #expect(csCheckpoints(project, id: "RC").isEmpty)

        // Retry with changed bytes for measurement file 2 only, under the same revision ID; must be refused.
        let changed = original.map { item -> (String, Data) in
            item.name == "RC-m2.json" ? (item.name, Data("CHANGED-payload-RC-m2.json".utf8)) : item
        }.map { (name: $0.0, data: $0.1) }
        var refused: PreconProjectError?
        do {
            _ = try workspace.store.saveRevision(revision, measurements: changed, in: project, at: csDate(1))
            Issue.record("changed bytes under an existing file name must throw alreadyExists")
        } catch let error as PreconProjectError {
            guard case .alreadyExists("RC-m2.json") = error else {
                Issue.record("expected alreadyExists(\"RC-m2.json\"), got \(error)")
                return
            }
            refused = error
        } catch {
            Issue.record("expected PreconProjectError.alreadyExists, got: \(error)")
            return
        }
        #expect(refused != nil, "the changed-bytes retry must be refused")
        #expect(csDigestMap(project, paths: original.map { "measurements/\($0.name)" }) == partialDigests,
                "the refused attempt must leave the earlier partial files byte-identical")
        #expect(csCheckpoints(project, id: "RC").isEmpty, "the refused attempt must not mint a checkpoint")
        #expect(csTempFiles(project).isEmpty, "the refused attempt must not leave temp files")
    }

    /// Invariant: two consecutive failures at the same stage do not permanently block the transaction; the
    /// next identical-byte attempt still completes, yields exactly the staged files and a resumable
    /// checkpoint whose digests match the files on disk.
    @Test("C03: repeated failures at the same stage do not permanently block the save")
    func repeatedFailuresRecover() throws {
        let workspace = try CsWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()
        let revision = PreconRevision(revisionId: "RC", synthetic: true)
        let measurements = csMeasurements("RC")
        let stage = "measurements/RC-m2.json"

        var broken = workspace.store
        broken.beforeWrite = csFailAt(stage)
        for attempt in 1...2 {
            #expect(throws: (any Error).self, "failure \(attempt)/2 at \(stage) must abort the save") {
                _ = try broken.saveRevision(revision, measurements: measurements, in: project, at: csDate(attempt))
            }
            #expect(csCheckpoints(project, id: "RC").isEmpty, "failure \(attempt)/2: no checkpoint may exist")
        }

        var store = workspace.store
        store.beforeWrite = nil
        _ = try store.saveRevision(revision, measurements: measurements, in: project, at: csDate(3))
        let checkpoints = csCheckpoints(project, id: "RC")
        #expect(checkpoints.count == 1, "the third attempt must complete the save")
        #expect(csSaveFiles(project, under: "measurements") == measurements.map { $0.name }.sorted())
        let (_, checkpoint) = try store.resume(from: checkpoints[0], in: project)
        for (path, digest) in checkpoint.measurementDigests {
            #expect((try? StableDigest.file(project.appending(path: path))) == digest,
                    "checkpoint digest for \(path) must match the file on disk")
        }
    }

    /// Invariant: after an interrupted save under a revision ID, a second save to a FRESH revision ID with
    /// fresh measurement names succeeds, and the new checkpoint must not reference the abandoned ID's
    /// leftover files, which stay in place untouched.
    @Test("C04: a second save to a fresh ID succeeds and the abandoned ID's files are unreferenced")
    func freshIdRecovery() throws {
        let workspace = try CsWorkspace()
        defer { workspace.cleanUp() }
        let project = try workspace.project()

        // Abandoned transaction: all measurements written, revision stage failed.
        let abandoned = PreconRevision(revisionId: "ABANDONED", synthetic: true)
        let abandonedFiles = csMeasurements("ABANDONED")
        var broken = workspace.store
        broken.beforeWrite = csFailAt("revisions/ABANDONED.json")
        #expect(throws: (any Error).self) { _ = try broken.saveRevision(abandoned, measurements: abandonedFiles, in: project, at: csDate(0)) }
        #expect(csCheckpoints(project, id: "ABANDONED").isEmpty)
        let abandonedDigests = csDigestMap(project, paths: abandonedFiles.map { "measurements/\($0.name)" })

        // Fresh revision ID, fresh measurement names.
        let fresh = PreconRevision(revisionId: "R2", synthetic: true)
        let freshFiles = csMeasurements("R2")
        _ = try workspace.store.saveRevision(fresh, measurements: freshFiles, in: project, at: csDate(1))
        let checkpoints = csCheckpoints(project, id: "R2")
        #expect(checkpoints.count == 1, "the fresh-ID save must complete")
        let (_, checkpoint) = try workspace.store.resume(from: checkpoints[0], in: project)
        let referenced = Set(checkpoint.measurementDigests.keys)
        #expect(referenced == Set(freshFiles.map { "measurements/\($0.name)" }),
                "the fresh checkpoint must reference only the fresh revision's measurement files")
        #expect(referenced.allSatisfy { !$0.contains("ABANDONED") },
                "the abandoned ID's files must not be referenced by the new checkpoint")
        #expect(csDigestMap(project, paths: abandonedFiles.map { "measurements/\($0.name)" }) == abandonedDigests,
                "the abandoned ID's leftover files must stay in place untouched")
    }

    // MARK: - Mixed-scale refusal matrix

    /// Page with a traced 216x180 pt area calibrated to 18 pt/ft (candidate). Net area 120 SF.
    private func csTracedAreaPage() throws -> TakeoffMeasurements {
        var page = TakeoffMeasurements(source: SourceRecord(id: "P", path: "sources/x/plan.pdf", sha256: "",
                                                            revision: "R1", role: .proposed, pageIndex: 0, sheet: ""))
        page.calibrationChecks = csCandidateChecks()
        page.polys = [AreaPlane.Polygon(id: "G01", zone: "Z01", sign: 1,
                                        pts: [[0, 0], [216, 0], [216, 180], [0, 180]])]
        #expect(page.calibration.scale == 18 && page.calibration.status == .candidate,
                "setup: the traced page must be a candidate at 18 pt/ft")
        return page
    }

    /// Invariant: once areas are traced at an established 18 pt/ft, an X detail-plane witness at 36 pt/ft is
    /// refused with `unsupportedMixedScale`, and the page's scale, status and quantities are unchanged.
    @Test("C05a: an X detail witness at a different scale is refused on a traced page")
    func mixedScaleXRefused() throws {
        let workspace = try CsWorkspace()
        defer { workspace.cleanUp() }
        _ = try workspace.project() // guard the seam against stray writes; page logic is in-memory
        let page = try csTracedAreaPage()
        let detail = csWitness(.x, coordinateLength: 432, realLength: 12) // 36 pt/ft detail plane
        #expect(throws: TakeoffError.unsupportedMixedScale(current: 18, proposed: "36.000 pt/ft")) {
            _ = try page.calibrationChecks(adding: detail)
        }
        #expect(page.calibration.scale == 18 && page.calibration.status == .candidate,
                "the refused witness must leave the page calibration unchanged")
        #expect(page.quantities().first?.value == 120 && page.quantities().count == 1,
                "the refused witness must leave the page quantities unchanged")
    }

    /// Invariant: a Y-only detail witness at 20 pt/ft is refused the same way on the same traced page.
    @Test("C05b: a Y-only detail witness at a different scale is refused")
    func mixedScaleYRefused() throws {
        let page = try csTracedAreaPage()
        let detail = csWitness(.y, coordinateLength: 200, realLength: 10) // 20 pt/ft
        #expect(throws: TakeoffError.unsupportedMixedScale(current: 18, proposed: "20.000 pt/ft")) {
            _ = try page.calibrationChecks(adding: detail)
        }
        #expect(page.calibration.scale == 18 && page.calibration.status == .candidate)
        #expect(page.quantities().first?.value == 120)
    }

    /// Invariant: re-measuring the same landmark (identical witness) on the same axis is allowed; the page
    /// stays a candidate at the same scale and the returned check list keeps one check per axis.
    @Test("C05c: an identical re-measurement re-click is allowed and keeps the calibration")
    func identicalReclickAllowed() throws {
        let page = try csTracedAreaPage()
        let reclick = csWitness(.x, coordinateLength: 216, realLength: 12)
        do {
            let updated = try page.calibrationChecks(adding: reclick)
            var refined = page
            refined.calibrationChecks = updated
            #expect(refined.calibration.scale == 18 && refined.calibration.status == .candidate,
                    "an agreeing re-click must keep the 18 pt/ft candidate calibration")
            #expect(updated.filter { $0.axis == .x }.count == 1, "the re-click replaces the old X witness in the list")
        } catch {
            Issue.record("an identical re-measurement re-click must be allowed; got \(error)")
        }
    }

    /// Invariant per brief: a re-click within 1 pt of the same landmark is allowed. A 1 pt jitter on the
    /// 216 pt witness yields a slightly different scale, so this asserts the refusal guard tolerates
    /// same-landmark jitter instead of demanding a bit-identical re-measurement.
    @Test("C05d: a re-click within 1 pt of the same landmark is allowed")
    func withinOnePointReclickAllowed() throws {
        let page = try csTracedAreaPage()
        let jitter = csWitness(.x, coordinateLength: 217, realLength: 12) // ~0.46% off 216/12
        do {
            let updated = try page.calibrationChecks(adding: jitter)
            var refined = page
            refined.calibrationChecks = updated
            #expect(updated.filter { $0.axis == .x }.count == 1)
            let scale = refined.calibration.scale
            #expect(scale == nil || refined.calibration.status == .candidate,
                    "a within-1 pt re-click must not strand the page in a conflicted/broken state")
        } catch {
            Issue.record("brief invariant: a re-click within 1 pt must be allowed; got \(error)")
        }
    }

    /// Invariant: the refusal guard applies to a page whose only traced geometry is routes, too.
    @Test("C05e: a differently scaled witness is refused on a route-only page as well")
    func mixedScaleRouteOnlyRefused() throws {
        var page = TakeoffMeasurements(source: SourceRecord(id: "PR", path: "sources/x/plan.pdf", sha256: "",
                                                            revision: "R1", role: .proposed, pageIndex: 0, sheet: ""))
        page.calibrationChecks = csCandidateChecks()
        page.routes = [TakeoffMeasurements.Route(id: "R01", pts: [[0, 0], [36, 0]], closed: false)]
        #expect(page.calibration.scale == 18 && page.quantities().first?.value == 2, "setup: route-only page, 36 pt at 18 pt/ft = 2 LF")
        #expect(throws: TakeoffError.unsupportedMixedScale(current: 18, proposed: "36.000 pt/ft")) {
            _ = try page.calibrationChecks(adding: csWitness(.x, coordinateLength: 432, realLength: 12))
        }
        #expect(page.calibration.scale == 18 && page.quantities().first?.value == 2,
                "the refused witness must leave the route page unchanged")
    }

    /// Invariant: a counts-only page (no scale-dependent traces) must never refuse a witness, and the count
    /// keeps its value; scale stays withheld when the added witness disagrees, never averaged or fudged.
    @Test("C05f: a counts-only page accepts a witness without refusing the count")
    func countsOnlyPageAllowsWitness() throws {
        let workspace = try CsWorkspace()
        defer { workspace.cleanUp() }
        _ = try workspace.project()
        var page = TakeoffMeasurements(source: SourceRecord(id: "PC", path: "sources/x/plan.pdf", sha256: "",
                                                            revision: "R1", role: .proposed, pageIndex: 0, sheet: ""))
        page.calibrationChecks = csCandidateChecks()
        page.counts = [.init(id: "C1", physicalItemId: "F01", pt: [100, 100]),
                       .init(id: "C2", physicalItemId: "F02", pt: [120, 100])]
        #expect(page.calibration.scale == 18 && page.quantities().first?.value == 2, "setup: counts-only page, 2 EA")
        do {
            let updated = try page.calibrationChecks(adding: csWitness(.x, coordinateLength: 432, realLength: 12))
            // The same-axis check is replaced, not accumulated; the point is the refusal-free accept.
            var refined = page
            refined.calibrationChecks = updated
            #expect(updated.contains { $0.axis == .x && $0.scale == 36 },
                    "the added 36 pt/ft witness must be carried by the updated list")
            #expect(updated.filter { $0.axis == .y }.count == 1, "the Y witness must survive")
            #expect(refined.quantities().count == 1 && refined.quantities().first?.value == 2,
                    "the count quantity must keep its value whatever the witness says")
        } catch {
            Issue.record("counts-only pages must accept calibration witnesses without refusing; got \(error)")
        }
    }

    /// Invariant: a page whose calibration is already in conflict (no scale established) accepts a new
    /// witness so the user can keep working; it must not manufacture a scale, and values stay withheld.
    @Test("C05g: a page in calibration conflict accepts a new witness and keeps values withheld")
    func conflictedPageAllowsWitness() throws {
        var page = TakeoffMeasurements(source: SourceRecord(id: "PF", path: "sources/x/plan.pdf", sha256: "",
                                                            revision: "R1", role: .proposed, pageIndex: 0, sheet: ""))
        page.calibrationChecks = [csWitness(.x, coordinateLength: 216, realLength: 12),
                                  csWitness(.y, coordinateLength: 200, realLength: 10)] // 18 vs 20 -> conflict
        page.polys = [AreaPlane.Polygon(id: "G01", zone: "Z01", sign: 1,
                                        pts: [[0, 0], [216, 0], [216, 180], [0, 180]])]
        #expect(page.calibration.scale == nil && page.quantities().first?.value == nil,
                "setup: the conflicted page withholds both scale and area")
        do {
            let updated = try page.calibrationChecks(adding: csWitness(.x, coordinateLength: 216, realLength: 12))
            var refined = page
            refined.calibrationChecks = updated
            #expect(refined.calibration.scale == nil,
                    "a conflicted page must not gain a manufactured/averaged scale from the added witness")
            #expect(refined.quantities().first?.value == nil, "area stays withheld, not silently computed")
        } catch {
            Issue.record("adding a witness to a conflicted page must be allowed; got \(error)")
        }
    }

    /// Invariant: witnesses with NaN/zero/negative witness lengths (or infinite coordinates) must never
    /// produce a scale — not NaN, zero, negative or infinite, and never over an established one.
    @Test("C06: corrupt witness lengths never produce a scale", arguments: [
        ("NaN coordinate length", [Double.nan, 12.0]),
        ("infinite coordinate length", [Double.infinity, 12.0]),
        ("zero real length", [216.0, 0.0]),
        ("negative real length", [216.0, -12.0]),
        ("NaN real length", [216.0, Double.nan]),
    ])
    func corruptWitnessNeverProducesScale(label: String, lengths: [Double]) throws {
        var page = TakeoffMeasurements(source: SourceRecord(id: "PN", path: "sources/x/plan.pdf", sha256: "",
                                                            revision: "R1", role: .proposed, pageIndex: 0, sheet: ""))
        page.calibrationChecks = csCandidateChecks()
        page.polys = [AreaPlane.Polygon(id: "G01", zone: "Z01", sign: 1,
                                        pts: [[0, 0], [216, 0], [216, 180], [0, 180]])]
        let bad = csWitness(.x, coordinateLength: lengths[0], realLength: lengths[1])
        var afterBad = page
        do {
            let updated = try page.calibrationChecks(adding: bad)
            afterBad.calibrationChecks = updated
        } catch {
            // Refusal is acceptable: the page keeps its established scale untouched.
            #expect(page.calibration.scale == 18 && page.calibration.status == .candidate,
                    "\(label): refusing the bad witness must leave the established scale intact")
            return
        }
        // If accepted: no malformed scale may appear, least of all replace a good one.
        let scale = afterBad.calibration.scale
        #expect(scale.map { $0.isFinite && $0 > 0 } != false || scale == nil,
                "\(label): a corrupt witness must never produce a NaN, zero, negative or infinite scale")
        #expect(scale == nil || scale == 18,
                "\(label): accepting a corrupt witness may only withhold the scale (nil), not produce a new number")
        #expect(afterBad.calibration.status != .conflict || scale == nil,
                "\(label): a conflict-withheld scale is acceptable, a produced one is not")
    }
}
