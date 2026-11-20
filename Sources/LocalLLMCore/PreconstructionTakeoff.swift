import Foundation

// Deterministic takeoff arithmetic. Arithmetic and topology are reported separately; neither implies source fidelity.

public enum TakeoffError: Error, Equatable, LocalizedError {
    case invalidScale
    case duplicateID(String)
    case invalidSign(String)
    case invalidGeometry(String, String)
    case unsupportedMixedScale(current: Double, proposed: String)

    public var errorDescription: String? {
        switch self {
        case .invalidScale: "Scale must be a finite positive number."
        case .duplicateID(let id): "Duplicate geometry ID \(id)."
        case .invalidSign(let id): "Polygon \(id) sign must be 1 or -1."
        case .invalidGeometry(let id, let reason): "Geometry \(id) rejected: \(reason)."
        case .unsupportedMixedScale(let current, let proposed):
            "This page's areas and routes were traced at \(String(format: "%.3f", current)) pt/ft; the new witness gives \(proposed). "
                + "A differently scaled detail needs its own plane, which is not supported (A11). Measure it on a separate page, "
                + "or delete this page's areas and routes before recalibrating."
        }
    }
}

public extension Calibration {
    /// Allowance for where a person clicks one witness endpoint, in PDF points (the unit of `coordinateLength`, in the
    /// unrotated page frame). The takeoff view maps a click at 1/1.5 pt resolution and rounds to 0.01 pt, so this is
    /// about 1.5 screen pixels of aim, not float noise.
    static let endpointUncertaintyPoints = 1.0

    /// Independent X and Y witness checks; contradictory checks are a conflict, never an averaged scale.
    /// Two checks agree when their scales differ by no more than their combined click uncertainty: a +/-u error at each
    /// end moves a witness of length L by up to 2u, so its scale is uncertain by scale * 2u / L. Float noise is a
    /// separate 1e-9 relative term. Agreeing checks give the longest witness's scale (least uncertain), not an average.
    static func evaluate(_ checks: [CalibrationCheck],
                         endpointUncertainty: Double = endpointUncertaintyPoints) -> (scale: Double?, status: Status) {
        let axes = Set(checks.map(\.axis))
        guard axes == [.x, .y], checks.allSatisfy({ $0.scale.isFinite && $0.scale > 0 && $0.coordinateLength > 0 }) else {
            return (nil, .unestablished)
        }
        let tolerance = { (c: CalibrationCheck) in c.scale * 2 * endpointUncertainty / c.coordinateLength }
        for a in checks {
            for b in checks where abs(a.scale - b.scale) > tolerance(a) + tolerance(b) + 1e-9 * max(a.scale, b.scale) {
                return (nil, .conflict)
            }
        }
        return (checks.max { $0.coordinateLength < $1.coordinateLength }!.scale, .candidate)
    }
}

public extension LengthUnit {
    /// Feet per one unit. Areas convert with this factor squared.
    var feet: Double {
        switch self {
        case .ft: 1
        case .in: 1.0 / 12
        case .m: 1 / 0.3048
        case .mm: 1 / 304.8
        }
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
        var failures = deductions.compactMap { hole in
            positives.contains { $0.zone == hole.zone && contains(outer: $0.pts, inner: hole.pts) }
                ? nil : "\(hole.id) is not contained by a gross polygon in zone \(hole.zone)"
        }
        // Ownership rule: a positive polygon inside a deduction of its zone is an add-back restoring that region, so
        // its overlap with the gross polygon around it is intended. Any other same-sign overlap double counts, and
        // overlapping deductions have no ownership rule, so both fail. Polygons that only touch share no area.
        let addBacks = positives.filter { p in deductions.contains { $0.zone == p.zone && contains(outer: $0.pts, inner: p.pts) } }
        for group in [positives, deductions] {
            for (i, a) in group.enumerated() {
                for b in group.dropFirst(i + 1) {
                    let pair = [a, b].sorted { $0.id < $1.id }
                    let isAddBack = { (p: AreaPlane.Polygon) in addBacks.contains { $0.id == p.id } }
                    // Only an add-back's overlap with the gross polygon around it is intended; two add-backs never overlap.
                    if let addBack = pair.first(where: isAddBack), let other = pair.first(where: { $0.id != addBack.id }),
                       !isAddBack(other), contains(outer: other.pts, inner: addBack.pts) { continue }
                    if overlaps(a.pts, b.pts) { failures.append("\(pair[0].id) overlaps \(pair[1].id)") }
                }
            }
        }
        let topology: CheckStatus = failures.isEmpty ? .passed : .failed
        return AreaTakeoff(gross: gross, deductions: deducted, topology: topology, topologyNotes: failures)
    }

    /// Where the boundary of simple polygon `a` runs relative to simple polygon `b`; nil when their edges properly cross.
    /// Each edge of `a` is cut at every vertex of `b` lying on it. With no proper crossing, a piece then lies wholly
    /// along one edge of `b` (both ends on it), wholly inside or wholly outside, so one midpoint test per piece decides
    /// it. That settles touching, overlap and containment without a Boolean polygon engine.
    private static func boundary(of a: [[Double]], against b: [[Double]]) -> (inside: Bool, outside: Bool)? {
        let edgesA = Array(zip(a, a.dropFirst() + [a[0]])), edgesB = Array(zip(b, b.dropFirst() + [b[0]]))
        if edgesA.contains(where: { e in edgesB.contains { properlyCross(e.0, e.1, $0.0, $0.1) } }) { return nil }
        var inside = false, outside = false
        for (p, q) in edgesA {
            let cuts = b.filter { onSegment(p, q, $0) }.sorted { hypot($0[0] - p[0], $0[1] - p[1]) < hypot($1[0] - p[0], $1[1] - p[1]) }
            let points = [p] + cuts + [q]
            for (u, v) in zip(points, points.dropFirst()) where u != v {
                if edgesB.contains(where: { onSegment($0.0, $0.1, u) && onSegment($0.0, $0.1, v) }) { continue }
                if windingContains(b, [(u[0] + v[0]) / 2, (u[1] + v[1]) / 2]) { inside = true } else { outside = true }
            }
        }
        return (inside, outside)
    }

    /// True when two simple polygons share area. A boundary piece of one inside the other, or two boundaries that
    /// coincide everywhere (the same region traced twice), means shared area; touching along walls or corners does not.
    private static func overlaps(_ a: [[Double]], _ b: [[Double]]) -> Bool {
        guard let ab = boundary(of: a, against: b), let ba = boundary(of: b, against: a) else { return true }
        return ab.inside || ba.inside || (!ab.outside && !ba.outside)
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

    /// Which side of the line a-b the point c is on; 0 when c is on the line to within rounding. An exact zero test
    /// misses a point on a diagonal wall with decimal coordinates (the cross product comes out near 1e-13), which let
    /// a real overlap pass.
    // ponytail: a fixed band of 1e-9 of the distance from c to the edge's ends, far below any traced gap. It misjudges
    // only slivers that thin (fuzzing needed an edge over 30,000 units long); exact rationals if traces ever get there.
    private static func side(_ a: [Double], _ b: [Double], _ c: [Double]) -> Double {
        let value = cross(a, b, c)
        let reach = hypot(b[0] - a[0], b[1] - a[1]) * (hypot(c[0] - a[0], c[1] - a[1]) + hypot(c[0] - b[0], c[1] - b[1]))
        return abs(value) <= 1e-9 * reach ? 0 : value
    }

    private static func onSegment(_ p: [Double], _ q: [Double], _ r: [Double]) -> Bool {
        let along = (r[0] - p[0]) * (q[0] - p[0]) + (r[1] - p[1]) * (q[1] - p[1])
        let length2 = (q[0] - p[0]) * (q[0] - p[0]) + (q[1] - p[1]) * (q[1] - p[1])
        return side(p, q, r) == 0 && along >= -1e-9 * length2 && along <= length2 * (1 + 1e-9)
    }

    private static func properlyCross(_ a: [Double], _ b: [Double], _ c: [Double], _ d: [Double]) -> Bool {
        let values = [side(a, b, c), side(a, b, d), side(c, d, a), side(c, d, b)]
        return values.allSatisfy { $0 != 0 } && (values[0] > 0) != (values[1] > 0) && (values[2] > 0) != (values[3] > 0)
    }

    private static func segmentsTouch(_ a: [Double], _ b: [Double], _ c: [Double], _ d: [Double]) -> Bool {
        properlyCross(a, b, c, d) || onSegment(a, b, c) || onSegment(a, b, d) || onSegment(c, d, a) || onSegment(c, d, b)
    }

    /// True when no part of the inner boundary lies outside the outer polygon; touching the outer boundary is allowed.
    private static func contains(outer: [[Double]], inner: [[Double]]) -> Bool {
        boundary(of: inner, against: outer).map { !$0.outside } ?? false
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
        // The plane's area is in lengthUnit squared; SF needs the length factor squared (1 m2 = 10.7639 SF).
        let squareFeet = takeoff.net * unit.feet * unit.feet
        // Helper scale has no witness checks attached, so it stays a candidate until X/Y checks are recorded.
        let calibration = Calibration(id: calibrationId, sourceId: sourceId, frameId: "\(sourceId)-P\(source.pageIndex)",
                                      planeId: planeId, coordinateUnit: .pdfPoints, lengthUnit: unit,
                                      scale: scale, status: .candidate, checks: [])
        let quantity = QuantityRecord(id: quantityId, physicalItemId: physicalItemId, operation: .install, trade: trade,
                                      location: location, material: nil, unit: .SF, value: squareFeet,
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
