import Foundation

// Deterministic takeoff arithmetic. Arithmetic and topology are reported separately; neither implies source fidelity.

public enum TakeoffError: Error, Equatable, LocalizedError {
    case invalidScale
    case duplicateID(String)
    case invalidSign(String)
    case invalidGeometry(String, String)

    public var errorDescription: String? {
        switch self {
        case .invalidScale: "Scale must be a finite positive number."
        case .duplicateID(let id): "Duplicate geometry ID \(id)."
        case .invalidSign(let id): "Polygon \(id) sign must be 1 or -1."
        case .invalidGeometry(let id, let reason): "Geometry \(id) rejected: \(reason)."
        }
    }
}

public extension Calibration {
    /// Independent X and Y witness checks; contradictory checks are a conflict, never an averaged scale.
    static func evaluate(_ checks: [CalibrationCheck]) -> (scale: Double?, status: Status) {
        let scales = checks.map(\.scale)
        let axes = Set(checks.map(\.axis))
        guard axes == [.x, .y], scales.allSatisfy({ $0.isFinite && $0 > 0 }) else { return (nil, .unestablished) }
        let low = scales.min()!, high = scales.max()!
        // ponytail: fixed 1e-9 relative tolerance absorbs float noise only; a drawing tolerance needs an explicit, recorded rule
        guard (high - low) / high <= 1e-9 else { return (nil, .conflict) }
        return (low, .candidate)
    }
}

public struct AreaTakeoff: Equatable, Sendable {
    public var gross: Double
    public var deductions: Double
    public var net: Double { gross - deductions }
    public var topology: CheckStatus
    public var topologyNotes: [String]
}

public enum Takeoff {
    public static func area(_ plane: AreaPlane) throws -> AreaTakeoff {
        try requireScale(plane.scale)
        var seen = Set<String>()
        for poly in plane.polys {
            guard seen.insert(poly.id).inserted else { throw TakeoffError.duplicateID(poly.id) }
            guard poly.sign == 1 || poly.sign == -1 else { throw TakeoffError.invalidSign(poly.id) }
            try validatePolygon(poly.id, poly.pts)
        }
        let squared = plane.scale * plane.scale
        let positives = plane.polys.filter { $0.sign == 1 }
        let gross = positives.reduce(0) { $0 + abs(signedArea($1.pts)) } / squared
        let deductions = plane.polys.filter { $0.sign == -1 }
        let deducted = deductions.reduce(0) { $0 + abs(signedArea($1.pts)) } / squared
        var notes = deductions.compactMap { hole in
            positives.contains { $0.zone == hole.zone && contains(outer: $0.pts, inner: hole.pts) }
                ? nil : "\(hole.id) is not contained by a gross polygon in zone \(hole.zone)"
        }
        let failed = !notes.isEmpty
        // ponytail: overlap between gross polygons or between deductions needs a Boolean polygon engine; reported unavailable, not passed
        notes.append("Overlap between polygons of the same sign is unchecked")
        return AreaTakeoff(gross: gross, deductions: deducted, topology: failed ? .failed : .unavailable, topologyNotes: notes)
    }

    /// Open routes never get an automatic closing segment.
    public static func length(_ id: String, _ points: [[Double]], scale: Double, closed: Bool) throws -> Double {
        try requireScale(scale)
        guard points.count >= 2, points.allSatisfy(isPoint) else { throw TakeoffError.invalidGeometry(id, "route needs two or more finite points") }
        let path = closed ? points + [points[0]] : points
        return zip(path, path.dropFirst()).reduce(0) { $0 + hypot($1.1[0] - $1.0[0], $1.1[1] - $1.0[1]) } / scale
    }

    /// EA counts physical items, not appearances across views.
    public static func physicalCount(_ physicalItemIDs: [String]) -> Int { Set(physicalItemIDs).count }

    public static func signedArea(_ pts: [[Double]]) -> Double {
        // Local origin reduces cancellation for large translated coordinates.
        let o = pts[0]
        return (1..<(pts.count - 1)).reduce(0) { $0 + cross(o, pts[$1], pts[$1 + 1]) } / 2
    }

    public static func validatePolygon(_ id: String, _ pts: [[Double]]) throws {
        guard pts.count >= 3, pts.allSatisfy(isPoint) else { throw TakeoffError.invalidGeometry(id, "needs three or more finite points") }
        guard Set(pts).count == pts.count else { throw TakeoffError.invalidGeometry(id, "repeated vertex") }
        let n = pts.count
        for i in 0..<n {
            for j in (i + 1)..<n where j != i + 1 && !(i == 0 && j == n - 1) {
                if segmentsTouch(pts[i], pts[(i + 1) % n], pts[j], pts[(j + 1) % n]) {
                    throw TakeoffError.invalidGeometry(id, "self-intersecting edges")
                }
            }
        }
        guard signedArea(pts) != 0 else { throw TakeoffError.invalidGeometry(id, "zero area") }
    }

    private static func requireScale(_ scale: Double) throws {
        guard scale.isFinite, scale > 0 else { throw TakeoffError.invalidScale }
    }

    private static func isPoint(_ p: [Double]) -> Bool { p.count == 2 && p.allSatisfy(\.isFinite) }

    private static func cross(_ a: [Double], _ b: [Double], _ c: [Double]) -> Double {
        (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    }

    private static func onSegment(_ p: [Double], _ q: [Double], _ r: [Double]) -> Bool {
        cross(p, q, r) == 0 && min(p[0], q[0]) <= r[0] && r[0] <= max(p[0], q[0])
            && min(p[1], q[1]) <= r[1] && r[1] <= max(p[1], q[1])
    }

    private static func properlyCross(_ a: [Double], _ b: [Double], _ c: [Double], _ d: [Double]) -> Bool {
        let values = [cross(a, b, c), cross(a, b, d), cross(c, d, a), cross(c, d, b)]
        return values.allSatisfy { $0 != 0 } && (values[0] > 0) != (values[1] > 0) && (values[2] > 0) != (values[3] > 0)
    }

    private static func segmentsTouch(_ a: [Double], _ b: [Double], _ c: [Double], _ d: [Double]) -> Bool {
        properlyCross(a, b, c, d) || onSegment(a, b, c) || onSegment(a, b, d) || onSegment(c, d, a) || onSegment(c, d, b)
    }

    /// Inner vertices inside or on the outer boundary, and no proper edge crossings.
    // ponytail: misses a hole bridging a concave notch via collinear edges only; Boolean engine is the upgrade path
    private static func contains(outer: [[Double]], inner: [[Double]]) -> Bool {
        let outerEdges = zip(outer, outer.dropFirst() + [outer[0]])
        let innerEdges = zip(inner, inner.dropFirst() + [inner[0]])
        let crosses = innerEdges.contains { e in outerEdges.contains { properlyCross(e.0, e.1, $0.0, $0.1) } }
        return !crosses && inner.allSatisfy { p in
            outerEdges.contains { onSegment($0.0, $0.1, p) } || windingContains(outer, p)
        }
    }

    private static func windingContains(_ poly: [[Double]], _ p: [Double]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a[1] > p[1]) != (b[1] > p[1]), p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0] { inside.toggle() }
            j = i
        }
        return inside
    }
}

public extension AreaPlane {
    /// Explicit adapter from the area-helper plane to revision records. The plane file itself is not modified.
    func revisionRecords(sourceId: String, calibrationId: String, planeId: String, quantityId: String,
                         physicalItemId: String, trade: String, location: String) throws -> (Calibration, QuantityRecord) {
        let takeoff = try Takeoff.area(self)
        guard takeoff.topology != .failed else {
            throw TakeoffError.invalidGeometry(polys.map(\.id).joined(separator: ","), takeoff.topologyNotes.joined(separator: "; "))
        }
        guard let unit = LengthUnit(rawValue: lengthUnit) else { throw TakeoffError.invalidGeometry(source.sheet, "unsupported length unit \(lengthUnit)") }
        // Helper scale has no witness checks attached, so it stays a candidate until X/Y checks are recorded.
        let calibration = Calibration(id: calibrationId, sourceId: sourceId, frameId: "\(sourceId)-P\(source.pageIndex)",
                                      planeId: planeId, coordinateUnit: .pdfPoints, lengthUnit: unit,
                                      scale: scale, status: .candidate, checks: [])
        let quantity = QuantityRecord(id: quantityId, physicalItemId: physicalItemId, operation: .install, trade: trade,
                                      location: location, material: nil, unit: .SF, value: takeoff.net,
                                      scopeState: .provisional, basis: "Area helper plane \(source.sheet): gross minus deductions",
                                      sourceIds: [sourceId], geometryRefs: polys.map(\.id), questionIds: [],
                                      relatedWorkIds: [], relationship: .selected, installedTotalEligible: false)
        return (calibration, quantity)
    }
}

public extension PreconRevision {
    /// Released new-work total. Nil when nothing qualifies or any qualifying value is unknown; retained work never counts.
    func releasedTotal(_ unit: QuantityUnit, trade: String? = nil) -> Double? {
        total(unit, trade: trade) { $0.scopeState == .proposed && $0.installedTotalEligible }
    }

    /// Labeled provisional subtotal for review; never a released figure.
    func provisionalTotal(_ unit: QuantityUnit, trade: String? = nil) -> Double? {
        total(unit, trade: trade) { [.proposed, .provisional].contains($0.scopeState) }
    }

    private func total(_ unit: QuantityUnit, trade: String?, where eligible: (QuantityRecord) -> Bool) -> Double? {
        let rows = quantities.filter {
            $0.unit == unit && $0.operation == .install && [.selected, .component].contains($0.relationship)
                && (trade == nil || $0.trade == trade) && eligible($0)
        }
        guard !rows.isEmpty else { return nil }
        let values = rows.compactMap(\.value)
        return values.count == rows.count ? values.reduce(0, +) : nil
    }

    /// Everything that blocks scope release. Empty means a human may release; it is not compliance or field approval.
    func releaseBlockers() throws -> [String] {
        let digest = try snapshotDigest()
        var blockers = (questions + unfinishedMeasurements).filter(\.isOutstanding).map { "\($0.id) is \($0.status.rawValue)" }
        blockers += calibrations.filter { $0.status != .reviewed }.map { "\($0.id) calibration is \($0.status.rawValue)" }
        blockers += checks.filter { $0.status != .passed }.map { "\($0.id) check is \($0.status.rawValue)" }
        blockers += quantities.filter { $0.relationship == .selected && $0.operation == .install && $0.value == nil }
            .map { "\($0.id) quantity is unestablished" }
        for gate in [ApprovalRecord.Gate.reviewedGeometry, .scopeRelease]
        where !approvals.contains(where: { $0.gate == gate && $0.status == .approved && $0.snapshotSha256 == digest }) {
            blockers.append("\(gate.rawValue) approval missing for snapshot \(digest.prefix(12))")
        }
        return blockers
    }
}
