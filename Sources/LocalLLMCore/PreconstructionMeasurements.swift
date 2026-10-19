import Foundation

/// User-traced measurements for one source page, in top-left-origin PDF points. This is what the review UI edits;
/// quantities are always recomputed from it, never typed in.
public struct TakeoffMeasurements: Codable, Equatable, Sendable {
    public struct Route: Codable, Equatable, Sendable {
        public var id: String
        public var pts: [[Double]]
        public var closed: Bool

        public init(id: String, pts: [[Double]], closed: Bool = false) {
            self.id = id; self.pts = pts; self.closed = closed
        }
    }

    public struct Count: Codable, Equatable, Sendable {
        public var id: String
        public var physicalItemId: String
        public var pt: [Double]

        public init(id: String, physicalItemId: String, pt: [Double]) {
            self.id = id; self.physicalItemId = physicalItemId; self.pt = pt
        }
    }

    public var source: SourceRecord
    public var location = "Room"
    public var areaTrade = "flooring"
    public var routeTrade = "trim"
    public var countTrade = "fixtures"
    public var calibrationChecks: [CalibrationCheck] = []
    public var calibrationReviewed = false
    public var polys: [AreaPlane.Polygon] = []
    public var routes: [Route] = []
    public var counts: [Count] = []

    public init(source: SourceRecord) { self.source = source }

    public var calibration: Calibration {
        let (scale, status) = Calibration.evaluate(calibrationChecks)
        return Calibration(id: "CAL-\(source.id)", sourceId: source.id, frameId: "\(source.id)-PDF", planeId: "PLAN-FLOOR",
                           coordinateUnit: .pdfPoints, lengthUnit: .ft, scale: scale,
                           status: status == .candidate && calibrationReviewed ? .reviewed : status, checks: calibrationChecks)
    }

    /// Helper-schema plane, written beside the revision so geometry.py can recheck it. Nil without a usable scale.
    public var plane: AreaPlane? {
        guard let scale = calibration.scale, !polys.isEmpty else { return nil }
        return AreaPlane(source: .init(file: source.path, sheet: source.sheet, pageIndex: source.pageIndex, revision: source.revision),
                         lengthUnit: "ft", areaUnit: "SF", scale: scale,
                         zones: [.init(id: "Z01", name: location, finish: nil)], polys: polys)
    }

    public var area: Result<AreaTakeoff, Error>? { plane.map { plane in Result { try Takeoff.area(plane) } } }

    public func routeLength(_ route: Route) throws -> Double? {
        guard let scale = calibration.scale else { return nil }
        return try Takeoff.length(route.id, route.pts, scale: scale, closed: route.closed)
    }

    /// Quantities derived from the traced geometry. Without a non-conflicting calibration every value is unknown, not zero.
    public func quantities() -> [QuantityRecord] {
        let scaleNote = calibration.scale == nil ? "; calibration \(calibration.status.rawValue), value withheld" : ""
        var rows: [QuantityRecord] = []
        if !polys.isEmpty {
            let net = try? area?.get()
            let value = net.flatMap { $0.topology == .failed ? nil : $0.net }
            rows.append(row("QTY-AREA", item: "AREA-\(source.id)", trade: areaTrade, unit: .SF, value: value,
                            basis: "Traced gross minus deductions\(scaleNote)\(net?.topology == .failed ? "; topology failed" : "")",
                            refs: polys.map(\.id)))
        }
        if !routes.isEmpty {
            let lengths = routes.map { try? routeLength($0) }
            let value = lengths.contains { $0 == nil } ? nil : lengths.compactMap { $0 }.reduce(0, +)
            rows.append(row("QTY-ROUTE", item: "ROUTE-\(source.id)", trade: routeTrade, unit: .LF, value: value,
                            basis: "Traced open routes, no closing segment\(scaleNote)", refs: routes.map(\.id)))
        }
        if !counts.isEmpty {
            // Counts are scale independent; physical items are deduplicated across repeated views.
            rows.append(row("QTY-COUNT", item: "COUNT-\(source.id)", trade: countTrade, unit: .EA,
                            value: Double(Takeoff.physicalCount(counts.map(\.physicalItemId))),
                            basis: "Distinct physical items across \(counts.count) marks", refs: counts.map(\.id)))
        }
        return rows
    }

    /// Arithmetic and topology recorded separately; visual, scope and artifact checks are not run in this slice.
    public func checks() -> [CheckRecord] {
        guard let area else {
            return [CheckRecord(id: "CHK-arithmetic", dimension: .arithmetic, status: .pending, evidence: "No usable scale or no area traced")]
        }
        switch area {
        case .success(let takeoff):
            return [CheckRecord(id: "CHK-arithmetic", dimension: .arithmetic, status: .passed,
                                evidence: "gross \(takeoff.gross) - deductions \(takeoff.deductions) = \(takeoff.net) SF"),
                    CheckRecord(id: "CHK-topology", dimension: .topology, status: takeoff.topology,
                                evidence: takeoff.topologyNotes.joined(separator: "; "))]
        case .failure(let error):
            return [CheckRecord(id: "CHK-arithmetic", dimension: .arithmetic, status: .failed, evidence: error.localizedDescription)]
        }
    }

    private func row(_ id: String, item: String, trade: String, unit: QuantityUnit, value: Double?,
                     basis: String, refs: [String]) -> QuantityRecord {
        QuantityRecord(id: id, physicalItemId: item, operation: .install, trade: trade, location: location, material: nil,
                       unit: unit, value: value, scopeState: .provisional, basis: basis, sourceIds: [source.id],
                       geometryRefs: refs, questionIds: [], relatedWorkIds: [], relationship: .selected,
                       installedTotalEligible: false)
    }
}
