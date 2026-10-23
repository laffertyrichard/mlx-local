import Foundation
import PDFKit

// Phase 3: assisted interpretation. Native PDF text first, then one-image-per-call page OCR, then focused
// vision crops. Every model output is a candidate saved under interpretation/; nothing here can produce
// calibration, geometry, quantities or a revision.

public enum InterpretationStage: String, Codable, Sendable { case nativeText = "native_text", ocr, vision }

public struct InterpretationBudget: Codable, Equatable, Sendable {
    public var maxInputChars: Int
    public var maxChunks: Int
    public var reservedOutputTokens: Int

    public init(maxInputChars: Int = 6_000, maxChunks: Int = 4, reservedOutputTokens: Int = 1_024) {
        self.maxInputChars = maxInputChars; self.maxChunks = maxChunks; self.reservedOutputTokens = reservedOutputTokens
    }
}

/// One bounded model call: either a text chunk or exactly one page/crop image, never a batch.
public struct InterpretationRequest: Sendable {
    public var unitId: String
    public var stage: InterpretationStage
    public var instruction: String
    public var text: String?
    public var image: URL?
    public var maxOutputTokens: Int
    public var isRetry: Bool
}

/// The model seam. Returns raw JSON text; a ModelRuntime adapter goes here once real evaluation is authorized.
public typealias PreconInterpreter = @Sendable (InterpretationRequest) async throws -> String

public struct InterpretationCandidate: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case dimension, room, material, note, sheet }
    public var id: String
    public var kind: Kind
    public var text: String
    @Nullable public var quote: String?
    public var sourceId: String
    public var pageIndex: Int
    @Nullable public var bbox: [Double]?
    @Nullable public var confidence: Double?
    /// Nil: offered for human review. Otherwise the reason it is held and may not be offered.
    @Nullable public var heldReason: String?
}

public struct InterpretationUnit: Codable, Equatable, Sendable {
    /// partial = deterministic budget gap (saved); incomplete/failed/deferred are not saved and rerun on resume.
    public enum Status: String, Codable, Sendable { case complete, held, partial, incomplete, failed, deferred }
    public var id: String
    public var sourceId: String
    public var pageIndex: Int
    public var stage: InterpretationStage
    public var status: Status
    public var candidates: [InterpretationCandidate] = []
    /// Explicit gaps: unread pages, uninterpreted chunks, failures, deferral reasons.
    public var coverage: [String] = []

    var isReusable: Bool { [.complete, .held, .partial].contains(status) }
}

/// A region to read with a vision model, in the stored frame (unrotated media box, top-left, PDF points).
public struct VisionFocus: Sendable {
    public var sourceId: String
    public var rect: [Double] // x, y, width, height

    public init(sourceId: String, rect: [Double]) { self.sourceId = sourceId; self.rect = rect }
}

public struct InterpretationPipeline: Sendable {
    /// Bump when code-side rules change (quote support, OCR checks, chunking). Prompts are digested separately.
    public static let version = "precon-interpret-2"
    public var store: PreconProjectStore
    public var project: URL
    public var interpreter: PreconInterpreter
    public var budget = InterpretationBudget()
    public var profileDigest = "unprofiled"
    public var minimumConfidence = 0.6
    /// Checked before every model call. A non-nil reason (memory, pricing workload) defers the run.
    public var gate: @Sendable () -> String? = { nil }
    /// Part of every unit ID, so a prompt edit can never reuse units produced under the old prompt.
    public var ocrInstruction = Self.defaultOCRInstruction
    public var candidateInstruction = Self.defaultCandidateInstruction

    public init(store: PreconProjectStore, project: URL, interpreter: @escaping PreconInterpreter) {
        self.store = store; self.project = project; self.interpreter = interpreter
    }

    /// Runs sources in order, then focus crops. Saved units are reused; the run stops at the first deferral.
    public func run(_ sources: [SourceRecord], focus: [VisionFocus] = []) async throws -> [InterpretationUnit] {
        for item in focus { try item.validate() }
        let jobs: [(SourceRecord, VisionFocus?)] = try sources.map { ($0, nil) } + focus.map { item in
            guard let source = sources.first(where: { $0.id == item.sourceId }) else {
                throw TakeoffError.invalidGeometry("focus \(item.sourceId)", "names a source that is not in this run")
            }
            return (source, item)
        }
        var units: [InterpretationUnit] = []
        var verified = Set<String>()
        for (source, focus) in jobs {
            try Task.checkCancellation()
            // Current bytes are checked before a saved unit is trusted, not only before a fresh run.
            if verified.insert(source.path).inserted { _ = try sourceURL(source) }
            let id = unitID(source, focus: focus)
            if let saved = try store.interpretation(id, in: project) { units.append(saved); continue }
            let unit = try await interpret(source, focus: focus, id: id)
            units.append(unit)
            if unit.status == .deferred { break }
            if unit.isReusable { try store.saveInterpretation(unit, in: project) }
        }
        return units
    }

    /// Any change to source bytes, page, crop, pipeline, profile or budget yields a new ID, so stale units never match.
    func unitID(_ source: SourceRecord, focus: VisionFocus?) -> String {
        let crop = focus.map { $0.rect.map { String($0) }.joined(separator: ",") } ?? "page"
        let prompts = StableDigest.sha256(Data((ocrInstruction + "\u{0}" + candidateInstruction).utf8))
        let key = [Self.version, prompts, profileDigest, String(minimumConfidence), String(budget.maxInputChars),
                   String(budget.maxChunks), String(budget.reservedOutputTokens), source.sha256,
                   String(source.pageIndex), crop].joined(separator: "|")
        return StableDigest.sha256(Data(key.utf8))
    }

    private func interpret(_ source: SourceRecord, focus: VisionFocus?, id: String) async throws -> InterpretationUnit {
        let document = try loadDocument(source)
        guard let page = document.page(at: source.pageIndex) else {
            throw PreconProjectError.sourceChanged("\(source.path) has no page \(source.pageIndex + 1)")
        }
        let native = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var unit = InterpretationUnit(id: id, sourceId: source.id, pageIndex: source.pageIndex,
                                      stage: focus == nil ? (native.isEmpty ? .ocr : .nativeText) : .vision, status: .complete)
        if let focus {
            let bounds = page.bounds(for: .mediaBox)
            guard focus.rect[0] >= 0, focus.rect[1] >= 0, focus.rect[0] + focus.rect[2] <= bounds.width,
                  focus.rect[1] + focus.rect[3] <= bounds.height else {
                throw TakeoffError.invalidGeometry("focus \(focus.sourceId)", "crop \(focus.rect) is outside the \(bounds.width)x\(bounds.height) page")
            }
            await readVision(page, crop: focus.rect, pageText: native, into: &unit)
            withExtendedLifetime(document) {}
            return unit
        }
        var text = native
        if text.isEmpty {
            guard let ocr = await readOCR(page, into: &unit) else { return unit }
            text = ocr
        }
        await extract(text, independent: !native.isEmpty, into: &unit)
        withExtendedLifetime(document) {}
        return unit
    }

    /// The caller keeps the document alive: a PDFPage whose document is freed renders blank.
    private func loadDocument(_ source: SourceRecord) throws -> PDFDocument {
        let url = try sourceURL(source)
        guard let document = PDFDocument(url: url) else { throw PreconProjectError.sourceChanged("\(source.path) is not a readable PDF") }
        return document
    }

    private func sourceURL(_ source: SourceRecord) throws -> URL {
        let url = try store.contained(project.appending(path: source.path))
        guard try StableDigest.file(url) == source.sha256 else { throw PreconProjectError.sourceChanged(source.path) }
        return url
    }
}

extension VisionFocus {
    /// Shape, finiteness and size before anything indexes or renders the rect; page bounds are checked per page.
    func validate() throws {
        let id = "focus \(sourceId)"
        guard rect.count == 4 else { throw TakeoffError.invalidGeometry(id, "rect needs x, y, width, height; got \(rect.count) numbers") }
        guard rect.allSatisfy(\.isFinite) else { throw TakeoffError.invalidGeometry(id, "rect has a non-finite number") }
        guard rect[2] > 0, rect[3] > 0 else { throw TakeoffError.invalidGeometry(id, "width and height must be positive") }
    }
}

// MARK: - Stages

extension InterpretationPipeline {
    private struct OCRResult: Decodable { var text: String; var confidence: Double? }
    private struct RawCandidates: Decodable { var candidates: [RawCandidate] }
    private struct RawCandidate: Decodable {
        var kind: InterpretationCandidate.Kind
        var text: String
        var quote: String?
        var confidence: Double?
        var bbox: [Double]?
    }

    public static let defaultOCRInstruction = #"Transcribe all text in this single image. Return only JSON: {"text": string, "confidence": number 0-1}."#
    public static let defaultCandidateInstruction = """
        List dimensions, rooms, materials, notes and sheet IDs stated in the input. Do not infer anything not written. \
        Return only JSON: {"candidates": [{"kind": "dimension|room|material|note|sheet", "text": string, \
        "quote": exact source text, "confidence": number 0-1, "bbox": [x, y, w, h] or null}]}.
        """

    /// Returns nil and marks the unit when the page can't be read; an unread page is never empty text.
    private func readOCR(_ page: PDFPage, into unit: inout InterpretationUnit) async -> String? {
        let label = "page \(unit.pageIndex + 1)"
        let result: OCRResult?
        do {
            result = try await withImage(page, crop: nil) { image in
                try await ask(OCRResult.self, unit: unit, stage: .ocr, instruction: ocrInstruction, text: nil, image: image)
            }
        } catch {
            mark(&unit, error, label: "\(label) OCR")
            return nil
        }
        guard let result else { unit.status = .failed; unit.coverage.append("\(label) OCR: malformed output after retry"); return nil }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = text.isEmpty ? "no text read" : (result.confidence ?? 0) < minimumConfidence ? "low confidence"
            : Self.isRepetitive(text) ? "repeated output" : nil
        if let problem { unit.status = .incomplete; unit.coverage.append("\(label) OCR unreadable: \(problem)"); return nil }
        return text
    }

    /// Bounded chunks in order; whatever exceeds the budget is recorded as uninterpreted, never dropped silently.
    private func extract(_ text: String, independent: Bool, into unit: inout InterpretationUnit) async {
        let chunks = Self.chunks(text, max: budget.maxInputChars)
        for (index, chunk) in chunks.prefix(budget.maxChunks).enumerated() {
            let raw: RawCandidates?
            do {
                raw = try await ask(RawCandidates.self, unit: unit, stage: .nativeText, instruction: candidateInstruction,
                                    text: chunk, image: nil)
            } catch { mark(&unit, error, label: "page \(unit.pageIndex + 1) chunk \(index + 1)"); return }
            guard let raw else {
                unit.status = .failed; unit.coverage.append("page \(unit.pageIndex + 1) chunk \(index + 1): malformed output after retry")
                return
            }
            accept(raw.candidates, verifiedAgainst: text, independent: independent, into: &unit)
        }
        if chunks.count > budget.maxChunks {
            unit.status = .partial
            unit.coverage.append("page \(unit.pageIndex + 1): \(chunks.count - budget.maxChunks) of \(chunks.count) text chunks not interpreted (input budget)")
        }
    }

    private func readVision(_ page: PDFPage, crop: [Double], pageText: String, into unit: inout InterpretationUnit) async {
        let label = "page \(unit.pageIndex + 1) crop \(crop.map { String(Int($0)) }.joined(separator: ","))"
        do {
            let raw = try await withImage(page, crop: crop) { image in
                try await ask(RawCandidates.self, unit: unit, stage: .vision, instruction: candidateInstruction, text: nil, image: image)
            }
            guard let raw else { unit.status = .failed; unit.coverage.append("\(label): malformed output after retry"); return }
            accept(raw.candidates, verifiedAgainst: pageText, independent: !pageText.isEmpty, into: &unit)
        } catch { mark(&unit, error, label: label) }
    }

    /// `independent` is false when the only text is model OCR: a quote checked against output from the same kind of
    /// model proves nothing, so every such candidate stays held until a person checks it against the source image.
    private func accept(_ raw: [RawCandidate], verifiedAgainst text: String, independent: Bool,
                        into unit: inout InterpretationUnit) {
        let sourceTokens = Self.tokens(text)
        for item in raw {
            let quote = item.quote?.trimmingCharacters(in: .whitespacesAndNewlines)
            let quoteTokens = Self.tokens(quote ?? "")
            let reason: String? = quoteTokens.isEmpty ? "no source quote"
                : !independent ? "no independent text layer (scanned page); verify the quote against the source image"
                : !Self.containsRun(sourceTokens, quoteTokens) ? "quote not found in source text"
                : !Set(Self.tokens(item.text)).isSubset(of: quoteTokens) ? "candidate text not supported by its quote"
                : (item.confidence ?? 0) < minimumConfidence ? "low confidence" : nil
            let id = "C-\(unit.id.prefix(8))-\(String(format: "%03d", unit.candidates.count + 1))"
            unit.candidates.append(InterpretationCandidate(id: id, kind: item.kind, text: item.text, quote: quote,
                                                           sourceId: unit.sourceId, pageIndex: unit.pageIndex, bbox: item.bbox,
                                                           confidence: item.confidence, heldReason: reason))
            if reason != nil, unit.status == .complete { unit.status = .held }
        }
    }

    /// One call plus one constrained retry. Nil means malformed both times; interpreter errors propagate.
    private func ask<T: Decodable>(_ type: T.Type, unit: InterpretationUnit, stage: InterpretationStage, instruction: String,
                                   text: String?, image: URL?) async throws -> T? {
        for attempt in 0..<2 {
            if let reason = gate() { throw Deferral(reason: reason) }
            let request = InterpretationRequest(unitId: unit.id, stage: stage, instruction: instruction, text: text, image: image,
                                                maxOutputTokens: budget.reservedOutputTokens, isRetry: attempt > 0)
            let output = try await interpreter(request)
            if let decoded = try? PreconJSON.decoder.decode(T.self, from: Data(output.utf8)) { return decoded }
        }
        return nil
    }

    private struct Deferral: Error { var reason: String }

    private func mark(_ unit: inout InterpretationUnit, _ error: Error, label: String) {
        if let deferral = error as? Deferral {
            unit.status = .deferred; unit.coverage.append("\(label) deferred: \(deferral.reason)")
        } else {
            unit.status = .incomplete; unit.coverage.append("\(label) failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Helpers

extension InterpretationPipeline {
    /// Renders one page or crop to a transient PNG, removed after the call whatever happens.
    private func withImage<T>(_ page: PDFPage, crop: [Double]?, _ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: "PreconInterpret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "image.png")
        try Self.png(page, crop: crop).write(to: url)
        return try await body(url)
    }

    static func png(_ page: PDFPage, crop: [Double]?) throws -> Data {
        let frame = PageFrame(page)
        let scale = min(2.0, 2200 / max(frame.displaySize.width, frame.displaySize.height))
        guard var image = PageFrame.render(page, scale: scale).cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw PreconProjectError.sourceChanged("page \(page.label ?? "?") could not be rendered")
        }
        if let crop {
            let corners = [frame.toDisplay([crop[0], crop[1]]), frame.toDisplay([crop[0] + crop[2], crop[1] + crop[3]])]
            let pixels = Double(image.width) / frame.displaySize.width
            let rect = CGRect(x: min(corners[0][0], corners[1][0]) * pixels, y: min(corners[0][1], corners[1][1]) * pixels,
                              width: abs(corners[0][0] - corners[1][0]) * pixels, height: abs(corners[0][1] - corners[1][1]) * pixels)
            guard let cropped = image.cropping(to: rect.integral) else { throw PreconProjectError.sourceChanged("crop outside page") }
            image = cropped
        }
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw PreconProjectError.sourceChanged("page image could not be encoded")
        }
        return data
    }

    /// Lowercased alphanumeric runs: "12'-6\" CLR" -> ["12", "6", "clr"]. Matching on whole tokens stops "ft" matching "left".
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// The quote's tokens appear consecutively in the source.
    static func containsRun(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { Array(haystack[$0..<($0 + needle.count)]) == needle }
    }

    /// Line-bounded chunks of at most `max` characters; overlong lines are split hard.
    static func chunks(_ text: String, max: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n") {
            var rest = Substring(line)
            while !rest.isEmpty {
                let piece = rest.prefix(max); rest = rest.dropFirst(piece.count)
                if !current.isEmpty, current.count + 1 + piece.count > max { chunks.append(current); current = "" }
                current += current.isEmpty ? piece : "\n" + piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // ponytail: one line repeated as half of 4+ lines; catches the common OCR loop, not subtler degeneration.
    static func isRepetitive(_ text: String) -> Bool {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let top = Dictionary(grouping: lines, by: { $0 }).values.map(\.count).max() ?? 0
        return lines.count >= 4 && top * 2 >= lines.count
    }
}
