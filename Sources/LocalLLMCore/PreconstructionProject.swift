import CoreGraphics
import Foundation

// Project intake and durable revisions under a user-selected data root (PRECONSTRUCTION_WORKSPACE).
// Originals are immutable; revisions and checkpoints are never overwritten.

public enum PreconProjectError: Error, Equatable, LocalizedError {
    case invalidRoot(String)
    case invalidName(String)
    case alreadyExists(String)
    case outsideRoot(String)
    case notARegularFile(String)
    case sourceChanged(String)
    case staleCheckpoint([String])
    /// Bytes that cannot be decoded at all. Distinct from stale: nothing changed underneath, the file itself is bad.
    case corrupt(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRoot(let path): "Project data root is not an existing local directory: \(path)."
        case .invalidName(let name): "Name is not a safe single path component: \(name)."
        case .alreadyExists(let path): "Refusing to overwrite existing \(path)."
        case .outsideRoot(let path): "Path resolves outside the project data root: \(path)."
        case .notARegularFile(let path): "Source must be a local regular file, not a link or directory: \(path)."
        case .sourceChanged(let path): "Stored source bytes no longer match the recorded hash: \(path)."
        case .staleCheckpoint(let reasons): "Checkpoint rejected as stale: \(reasons.joined(separator: "; "))."
        case .corrupt(let path): "File is unreadable or corrupt: \(path)."
        }
    }
}

public struct ProjectCheckpoint: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var revisionId: String
    public var revisionSha256: String
    public var sourceDigests: [String: String]
    public var measurementDigests: [String: String]
    public var createdAt: Date
}

public struct PreconProjectStore: Sendable {
    public let root: URL
    /// Test seam: called with each project-relative path just before `saveRevision(_:measurements:in:)` writes it,
    /// so a test (or the debug app) can fail a save part-way. Nil in normal use.
    public var beforeWrite: (@Sendable (String) throws -> Void)?

    public init(root: URL) throws {
        var isDirectory: ObjCBool = false
        guard root.isFileURL, FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PreconProjectError.invalidRoot(root.absoluteString)
        }
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Copies the read-only package template into a new direct child; never merges into an existing project.
    public func createProject(named name: String, template: URL) throws -> URL {
        try Self.requireSafeName(name)
        let project = root.appending(path: name, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: project.path) else { throw PreconProjectError.alreadyExists(name) }
        try FileManager.default.copyItem(at: template, to: project)
        return project
    }

    /// Hash-addressed immutable copy: same filename with different bytes becomes a separate retained source.
    public func importSource(_ file: URL, into project: URL, role: SourceRole, revision: String,
                             sheets: [String] = []) throws -> [SourceRecord] {
        let project = try contained(project)
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard file.isFileURL, values?.isRegularFile == true, values?.isSymbolicLink == false else {
            throw PreconProjectError.notARegularFile(file.absoluteString)
        }
        let data = try Data(contentsOf: file)
        let digest = StableDigest.sha256(data)
        let relative = "sources/\(digest)/\(file.lastPathComponent)"
        let stored = try contained(project.appending(path: relative))
        if FileManager.default.fileExists(atPath: stored.path) {
            guard try StableDigest.file(stored) == digest else { throw PreconProjectError.sourceChanged(relative) }
        } else {
            try FileManager.default.createDirectory(at: stored.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: stored, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: stored.path)
            guard try StableDigest.file(stored) == digest else { throw PreconProjectError.sourceChanged(relative) }
        }
        let pages = stored.pathExtension.lowercased() == "pdf" ? (CGPDFDocument(stored as CFURL)?.numberOfPages ?? 0) : 1
        guard pages > 0 else { throw PreconProjectError.notARegularFile("\(relative) has no readable pages") }
        // Printed sheet and actual page index are separate; an unknown sheet stays empty, never guessed.
        return (0..<pages).map {
            SourceRecord(id: "S-\(digest.prefix(12))-P\($0)", path: relative, sha256: digest, revision: revision,
                         role: role, pageIndex: $0, sheet: $0 < sheets.count ? sheets[$0] : "")
        }
    }

    public func saveRevision(_ revision: PreconRevision, in project: URL) throws -> URL {
        try Self.requireSafeName(revision.revisionId)
        let project = try contained(project)
        return try writeNew(try PreconJSON.encoder.encode(revision), to: project.appending(path: "revisions/\(revision.revisionId).json"))
    }

    /// Writes a new measurement file (plane or traced geometry); returns its project-relative path.
    public func saveMeasurement(_ data: Data, named name: String, in project: URL) throws -> String {
        try Self.requireSafeName(name)
        let project = try contained(project)
        _ = try writeNew(data, to: project.appending(path: "measurements/\(name)"))
        return "measurements/\(name)"
    }

    /// An unused ID is safe, as is a retry whose on-disk files are an identical subset of this bundle.
    /// Extra files (including files removed from the draft) mean changed work must get a fresh ID.
    public func canReuseRevisionID(_ revision: PreconRevision, measurements: [(name: String, data: Data)],
                                   in project: URL) throws -> Bool {
        try Self.requireSafeName(revision.revisionId)
        let project = try contained(project)
        var expected = ["revisions/\(revision.revisionId).json": try PreconJSON.encoder.encode(revision)]
        for item in measurements {
            try Self.requireSafeName(item.name)
            expected["measurements/\(item.name)"] = item.data
        }
        let id = revision.revisionId
        for directory in ["measurements", "revisions", "checkpoints"] {
            let folder = try contained(project.appending(path: directory))
            guard FileManager.default.fileExists(atPath: folder.path) else { continue }
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            for name in names where directory == "revisions" ? name == "\(id).json" : name.hasPrefix("\(id)-") {
                let path = "\(directory)/\(name)"
                let url = try contained(project.appending(path: path))
                // A checkpoint is a completed-save marker, not a partial bundle file to reuse.
                guard let data = expected[path], try Data(contentsOf: url) == data else { return false }
            }
        }
        return true
    }

    /// One save: measurement files, then the revision, then the checkpoint last. Only a checkpoint marks a revision
    /// complete, so a failure part-way never exposes a completed result. A retry with identical bytes reuses what the
    /// failed attempt already wrote; different bytes under an existing name still refuse (the caller picks a new ID).
    public func saveRevision(_ revision: PreconRevision, measurements: [(name: String, data: Data)], in project: URL,
                             at date: Date = Date()) throws -> URL {
        try Self.requireSafeName(revision.revisionId)
        let project = try contained(project)
        var paths: [String] = []
        for item in measurements {
            try Self.requireSafeName(item.name)
            try beforeWrite?("measurements/\(item.name)")
            try writeOnce(item.data, to: project.appending(path: "measurements/\(item.name)"))
            paths.append("measurements/\(item.name)")
        }
        try beforeWrite?("revisions/\(revision.revisionId).json")
        try writeOnce(try PreconJSON.encoder.encode(revision), to: project.appending(path: "revisions/\(revision.revisionId).json"))
        try beforeWrite?("checkpoints/\(revision.revisionId)")
        return try saveCheckpoint(for: revision, in: project, measurements: paths, at: date)
    }

    private func writeOnce(_ data: Data, to target: URL) throws {
        let url = try contained(target)
        if let existing = try? Data(contentsOf: url) {
            guard existing == data else { throw PreconProjectError.alreadyExists(url.lastPathComponent) }
            return
        }
        _ = try writeNew(data, to: url)
    }

    /// Saves a finished interpretation unit under interpretation/<unit id>.json; never overwrites.
    public func saveInterpretation(_ unit: InterpretationUnit, in project: URL) throws {
        try Self.requireSafeName(unit.id)
        _ = try writeNew(try PreconJSON.encoder.encode(unit), to: try contained(project).appending(path: "interpretation/\(unit.id).json"))
    }

    /// A saved unit, nil if none. A file that doesn't decode to the same ID is reported, not rerun over.
    public func interpretation(_ id: String, in project: URL) throws -> InterpretationUnit? {
        try Self.requireSafeName(id)
        let url = try contained(try contained(project).appending(path: "interpretation/\(id).json"))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let unit = try? PreconJSON.decoder.decode(InterpretationUnit.self, from: Data(contentsOf: url)), unit.id == id else {
            throw PreconProjectError.corrupt("interpretation/\(id).json")
        }
        return unit
    }

    /// Binds the saved revision bytes (calibration included), every source hash and the listed measurement files.
    public func saveCheckpoint(for revision: PreconRevision, in project: URL, measurements: [String] = [],
                               at date: Date = Date()) throws -> URL {
        let project = try contained(project)
        let revisionURL = try contained(project.appending(path: "revisions/\(revision.revisionId).json"))
        guard try PreconJSON.decoder.decode(PreconRevision.self, from: Data(contentsOf: revisionURL)) == revision else {
            throw PreconProjectError.sourceChanged("revisions/\(revision.revisionId).json differs from the revision being checkpointed")
        }
        var sources: [String: String] = [:]
        for source in revision.sources {
            guard try StableDigest.file(try contained(project.appending(path: source.path))) == source.sha256 else {
                throw PreconProjectError.sourceChanged(source.path)
            }
            sources[source.path] = source.sha256
        }
        var measured: [String: String] = [:]
        for path in measurements { measured[path] = try StableDigest.file(try contained(project.appending(path: path))) }
        let checkpoint = ProjectCheckpoint(schemaVersion: revision.schemaVersion, revisionId: revision.revisionId,
                                           revisionSha256: try StableDigest.file(revisionURL), sourceDigests: sources,
                                           measurementDigests: measured, createdAt: date)
        let stamp = Int(date.timeIntervalSince1970 * 1000)
        return try writeNew(try PreconJSON.encoder.encode(checkpoint), to: project.appending(path: "checkpoints/\(revision.revisionId)-\(stamp).json"))
    }

    /// Rejects corrupt checkpoints and any changed schema, revision or source bytes; never silently reuses stale work.
    public func resume(from checkpointURL: URL, in project: URL) throws -> (PreconRevision, ProjectCheckpoint) {
        let project = try contained(project)
        guard let checkpoint = try? PreconJSON.decoder.decode(ProjectCheckpoint.self,
                                                              from: Data(contentsOf: try contained(checkpointURL))) else {
            throw PreconProjectError.corrupt(checkpointURL.lastPathComponent)
        }
        var stale: [String] = []
        if checkpoint.schemaVersion != PreconRevision.currentSchemaVersion { stale.append("schema \(checkpoint.schemaVersion)") }
        let revisionURL = try contained(project.appending(path: "revisions/\(checkpoint.revisionId).json"))
        if (try? StableDigest.file(revisionURL)) != checkpoint.revisionSha256 { stale.append("revision \(checkpoint.revisionId) changed") }
        for (path, digest) in checkpoint.sourceDigests.sorted(by: { $0.key < $1.key }) {
            let current = try? StableDigest.file(try contained(project.appending(path: path)))
            if current != digest { stale.append("source \(path) changed") }
        }
        for (path, digest) in checkpoint.measurementDigests.sorted(by: { $0.key < $1.key }) {
            let current = try? StableDigest.file(try contained(project.appending(path: path)))
            if current != digest { stale.append("measurement \(path) changed") }
        }
        guard stale.isEmpty else { throw PreconProjectError.staleCheckpoint(stale) }
        return (try PreconJSON.decoder.decode(PreconRevision.self, from: Data(contentsOf: revisionURL)), checkpoint)
    }

    /// Resolves symlinks in every existing ancestor, not only the path as given: `resolvingSymlinksInPath` leaves a
    /// path whose leaf doesn't exist yet untouched, so a symlinked `measurements/` would otherwise pass. An existing leaf
    /// that is itself a symlink is refused outright.
    // ponytail: check-then-write, not openat/O_NOFOLLOW; a concurrent local attacker swapping a directory between the
    // check and the rename is out of scope for a single-user data root.
    func contained(_ url: URL) throws -> URL {
        guard url.isFileURL else { throw PreconProjectError.outsideRoot(url.absoluteString) }
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while (try? FileManager.default.attributesOfItem(atPath: existing.path)) == nil, existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        if (try? FileManager.default.attributesOfItem(atPath: existing.path)[.type] as? FileAttributeType) == .typeSymbolicLink,
           existing.resolvingSymlinksInPath() == existing {
            throw PreconProjectError.outsideRoot(url.path) // dangling link: its target can't be checked
        }
        let resolved = missing.reduce(existing.resolvingSymlinksInPath()) { $0.appending(path: $1) }.standardizedFileURL
        guard resolved.path.hasPrefix(root.path + "/") else { throw PreconProjectError.outsideRoot(url.path) }
        return resolved
    }

    private static func requireSafeName(_ name: String) throws {
        guard name.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._ -]{0,63}/) != nil, !name.contains("..") else {
            throw PreconProjectError.invalidName(name)
        }
    }

    /// Atomic write through a temp file, then a rename that fails rather than replace an existing file.
    /// The target is re-contained here so no caller can write through a symlinked child directory.
    private func writeNew(_ data: Data, to target: URL) throws -> URL {
        let url = try contained(target)
        guard (try? FileManager.default.attributesOfItem(atPath: url.path)) == nil else {
            throw PreconProjectError.alreadyExists(url.lastPathComponent)
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try contained(directory) == directory else { throw PreconProjectError.outsideRoot(directory.path) }
        let temporary = directory.appending(path: ".tmp-\(UUID().uuidString)")
        try data.write(to: temporary, options: .atomic)
        do { try FileManager.default.moveItem(at: temporary, to: url) } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw PreconProjectError.alreadyExists(url.lastPathComponent)
        }
        return url
    }
}

/// Plain-text preview from a fixed template. Not model generated, not released, no pricing.
public enum ScopePreview {
    public static func render(_ revision: PreconRevision) -> String {
        var lines = ["SCOPE PREVIEW - DETERMINISTIC TEMPLATE - NOT MODEL GENERATED - NOT RELEASED",
                     "Revision \(revision.revisionId)", ""]
        for q in revision.quantities {
            let amount = q.value.map { "\(number($0)) \(q.unit.rawValue)" } ?? "not established (\(q.unit.rawValue))"
            let state = q.scopeState == .existingRetained ? "existing retained, reference only, not new work"
                : q.scopeState.rawValue.replacingOccurrences(of: "_", with: " ")
            var line = "-\(q.id) \(q.location) \(q.trade) \(q.operation.rawValue): \(amount) - \(state). Basis: \(q.basis)."
            if !q.sourceIds.isEmpty { line += " Sources: \(q.sourceIds.joined(separator: ", "))." }
            if !q.questionIds.isEmpty { line += " Open: \(q.questionIds.joined(separator: ", "))." }
            lines += [line, ""]
        }
        for (title, issues) in [("Open questions", revision.questions), ("Unfinished measurement", revision.unfinishedMeasurements)] {
            let open = issues.filter(\.isOutstanding)
            guard !open.isEmpty else { continue }
            lines.append("\(title):")
            lines += open.map { "-\($0.id) \($0.description)" }
            lines.append("")
        }
        lines.append("No pricing or markup included.")
        return plain(lines.joined(separator: "\n"))
    }

    private static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    /// ASCII only; unmapped characters become "?" so loss is visible rather than silent.
    // ponytail: no 4000-char line-item split yet; that belongs to the phase 4/5 proposal exporter
    private static func plain(_ text: String) -> String {
        let map: [Character: String] = ["\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\"",
                                        "\u{2013}": "-", "\u{2014}": "-", "\u{00D7}": "x", "\u{2212}": "-"]
        return String(text.flatMap { $0.isASCII ? String($0) : (map[$0] ?? "?") })
    }
}
