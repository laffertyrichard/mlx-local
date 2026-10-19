import Foundation

// Records mirror Preconstruction/schemas/revision.schema.json (schema_version 0.1).
// Unknown is nil, never zero. Model output never writes these directly.

public enum PreconJSON {
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

/// Encodes nil as an explicit JSON null: the schema requires unknown fields present, not omitted.
@propertyWrapper
public struct Nullable<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public var wrappedValue: Value?

    public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}

public enum SourceRole: String, Codable, Sendable { case existing, proposed, record, specification, decision }
public enum CoordinateUnit: String, Codable, Sendable { case pdfPoints = "pdf_points", pixels, cadUnits = "cad_units" }
public enum LengthUnit: String, Codable, Sendable { case ft, `in`, m, mm }

public struct SourceRecord: Codable, Equatable, Sendable {
    public var id: String
    public var path: String
    public var sha256: String
    public var revision: String
    public var role: SourceRole
    public var pageIndex: Int
    public var sheet: String
}

public struct CalibrationCheck: Codable, Equatable, Sendable {
    public enum Axis: String, Codable, Sendable { case x, y }
    public var axis: Axis
    public var coordinateLength: Double
    public var realLength: Double
    public var datum: String

    public var scale: Double { coordinateLength / realLength }
}

public struct Calibration: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case unestablished, candidate, reviewed, conflict }
    public var id: String
    public var sourceId: String
    public var frameId: String
    public var planeId: String
    public var coordinateUnit: CoordinateUnit
    public var lengthUnit: LengthUnit
    @Nullable public var scale: Double?
    public var status: Status
    public var checks: [CalibrationCheck]
}

public enum QuantityUnit: String, Codable, Sendable { case SF, LF, EA, CY }

public struct QuantityRecord: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case reference, remove, relocate, install, restore }
    public enum ScopeState: String, Codable, Sendable {
        case existingRetained = "existing_retained", removal, relocation, proposed, provisional
        case excluded, byOthers = "by_others", option, unresolved
    }
    public enum Relationship: String, Codable, Sendable { case selected, component, alternative, informational }

    public var id: String
    public var physicalItemId: String
    public var operation: Operation
    public var trade: String
    public var location: String
    @Nullable public var material: String?
    public var unit: QuantityUnit
    @Nullable public var value: Double?
    public var scopeState: ScopeState
    public var basis: String
    public var sourceIds: [String]
    public var geometryRefs: [String]
    public var questionIds: [String]
    public var relatedWorkIds: [String]
    public var relationship: Relationship
    public var installedTotalEligible: Bool
}

public struct IssueRecord: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case open, answered, partiallyAnswered = "partially_answered", superseded, unfinished, completed
    }
    public var id: String
    public var quantityIds: [String]
    public var sourceIds: [String]
    public var description: String
    public var status: Status

    public var isOutstanding: Bool { [.open, .partiallyAnswered, .unfinished].contains(status) }
}

public enum CheckStatus: String, Codable, Sendable { case passed, failed, skipped, unavailable, pending }

public struct CheckRecord: Codable, Equatable, Sendable {
    public enum Dimension: String, Codable, Sendable {
        case arithmetic, topology, visual, scope, artifact, codeBasis = "code_basis"
    }
    public var id: String
    public var dimension: Dimension
    public var status: CheckStatus
    @Nullable public var evidence: String?
}

public struct ApprovalRecord: Codable, Equatable, Sendable {
    public enum Gate: String, Codable, Sendable {
        case reviewedGeometry = "reviewed_geometry", design, scopeRelease = "scope_release"
        case field, fabrication, procurement, engineering, codeBasisReview = "code_basis_review"
    }
    public enum Status: String, Codable, Sendable { case pending, approved, rejected, stale }
    public var gate: Gate
    public var status: Status
    @Nullable public var snapshotSha256: String?
    @Nullable public var actor: String?
    @Nullable public var at: String?
}

public struct PreconRevision: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = "0.1"
    public var schemaVersion: String = Self.currentSchemaVersion
    public var synthetic: Bool
    public var revisionId: String
    public var sources: [SourceRecord] = []
    public var calibrations: [Calibration] = []
    public var quantities: [QuantityRecord] = []
    public var questions: [IssueRecord] = []
    public var unfinishedMeasurements: [IssueRecord] = []
    public var checks: [CheckRecord] = []
    public var approvals: [ApprovalRecord] = []

    public init(revisionId: String, synthetic: Bool = false) {
        self.revisionId = revisionId
        self.synthetic = synthetic
    }

    /// Digest an approval must bind to. Approvals themselves are excluded so recording one doesn't invalidate it.
    public func snapshotDigest() throws -> String {
        var unapproved = self
        unapproved.approvals = []
        return StableDigest.sha256(try PreconJSON.encoder.encode(unapproved))
    }
}

/// The existing area-helper plane schema (skills/plan-area-takeoff). Kept as-is; adapted, never rewritten.
public struct AreaPlane: Codable, Equatable, Sendable {
    public struct Source: Codable, Equatable, Sendable {
        public var file: String
        public var sheet: String
        public var pageIndex: Int
        public var revision: String
    }
    public struct Polygon: Codable, Equatable, Sendable {
        public var id: String
        public var zone: String
        public var sign: Int
        public var pts: [[Double]]
        public var note: String?
    }
    public var source: Source
    public var lengthUnit: String
    public var areaUnit: String
    public var scale: Double
    public var polys: [Polygon]
}
