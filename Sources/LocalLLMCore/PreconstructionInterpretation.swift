import Foundation
import PDFKit

// Phase 3: assisted interpretation. Native PDF text first, then one-image-per-call page OCR, then focused
// vision crops. Every model output is a candidate saved under interpretation/; nothing here can produce
// calibration, geometry, quantities or a revision.

public enum InterpretationStage: String, Codable, Sendable { case nativeText = "native_text", ocr, vision }

public struct InterpretationBudget: Codable, Equatable, Sendable {
    public var maxInputChars: Int
    public var maxInputLines: Int
    public var maxChunks: Int
    public var reservedOutputTokens: Int

    /// A drawing page is many short strings, and each becomes one candidate, so output grows with the line count, not
    /// the character count. The defaults keep one chunk's candidates inside the output allowance on dense sheets.
    public init(maxInputChars: Int = 1_500, maxInputLines: Int = 60, maxChunks: Int = 12, reservedOutputTokens: Int = 3_072) {
        self.maxInputChars = maxInputChars; self.maxInputLines = maxInputLines
        self.maxChunks = maxChunks; self.reservedOutputTokens = reservedOutputTokens
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

/// The model seam returns raw JSON; runtime-backed calls still yield candidates only.
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
    public var questions: [String] = []
    public var plannedChunks: Int?
    public var interpretedChunks: Int?

    public init(id: String, sourceId: String, pageIndex: Int, stage: InterpretationStage, status: Status,
                candidates: [InterpretationCandidate] = [], coverage: [String] = [], questions: [String] = []) {
        self.id = id; self.sourceId = sourceId; self.pageIndex = pageIndex; self.stage = stage; self.status = status
        self.candidates = candidates; self.coverage = coverage; self.questions = questions
    }
    private enum CodingKeys: String, CodingKey { case id, sourceId, pageIndex, stage, status, candidates, coverage, questions, plannedChunks, interpretedChunks }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id); sourceId = try values.decode(String.self, forKey: .sourceId)
        pageIndex = try values.decode(Int.self, forKey: .pageIndex); stage = try values.decode(InterpretationStage.self, forKey: .stage)
        status = try values.decode(Status.self, forKey: .status)
        candidates = try values.decode([InterpretationCandidate].self, forKey: .candidates)
        coverage = try values.decode([String].self, forKey: .coverage)
        questions = try values.decodeIfPresent([String].self, forKey: .questions) ?? []
        plannedChunks = try values.decodeIfPresent(Int.self, forKey: .plannedChunks)
        interpretedChunks = try values.decodeIfPresent(Int.self, forKey: .interpretedChunks)
    }

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
    public static let version = "precon-interpret-9"
    public var store: PreconProjectStore
    public var project: URL
    public var interpreter: PreconInterpreter
    public var budget = InterpretationBudget()
    public var profileDigest = "unprofiled"
    public var minimumConfidence = 0.6
    /// Checked before every model call. A non-nil reason (memory, pricing workload) defers the run.
    public var gate: @Sendable () async -> String? = { nil }
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
            // Current bytes are checked before a saved unit is trusted, not only before a fresh run.
            if verified.insert(source.path).inserted { _ = try sourceURL(source) }
            let id = unitID(source, focus: focus)
            if let saved = try store.interpretation(id, in: project) { units.append(saved); continue }
            var unit = try await interpret(source, focus: focus, id: id)
            unit.questions = unit.coverage + unit.candidates.compactMap(\.heldReason)
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
                   String(budget.maxInputLines), String(budget.maxChunks), String(budget.reservedOutputTokens), source.sha256,
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
        // The title block and the sheet ID are read from the PDF itself; a scan has only its OCR text to go on.
        let repeated = native.isEmpty ? [] : Self.repeatedLines(in: document)
        let sheets = native.isEmpty ? Self.sheetIDs(in: text) : Self.sheetIDs(on: page, text: native)
        await extract(text, skipping: repeated, sheets: sheets, independent: !native.isEmpty, into: &unit)
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
    /// A candidate the schema can't hold (an unknown kind, a number for text) is counted and skipped, not allowed to
    /// fail the whole answer.
    private struct RawCandidates: Decodable {
        var candidates: [RawCandidate] = []
        var unreadable = 0
        private enum CodingKeys: CodingKey { case candidates }
        private struct Element: Decodable {
            var value: RawCandidate?
            init(from decoder: Decoder) throws { value = try? RawCandidate(from: decoder) }
        }
        init(from decoder: Decoder) throws {
            let elements = try decoder.container(keyedBy: CodingKeys.self).decode([Element].self, forKey: .candidates)
            candidates = elements.compactMap(\.value); unreadable = elements.count - candidates.count
        }
    }
    private struct RawCandidate: Decodable {
        var kind: InterpretationCandidate.Kind
        var text: String
        var quote: String?
        var confidence: Double?
        var bbox: [Double]?
    }

    public static let defaultOCRInstruction = #"Transcribe all text in this single image. Return only JSON: {"text": string, "confidence": number 0-1}."#
    /// Values in the worked example must stay out of both evaluation fixtures (tested), so a parroted example can't score.
    /// No quote is requested: on a line holding ten dimensions the model repeats the whole line ten times, which overran
    /// the output budget on a real dimension plan. Each candidate is checked against the source by its own text.
    static let candidateExample = """
        Example input:
        Room Willow
        Depth 6 ft 2 in
        Trim cherry
        HOLD for owner approval
        AREA | TRIM
        Yew | nickel
        Example output: {"candidates":[{"kind":"room","text":"Willow"},{"kind":"dimension","text":"6 ft 2 in"},\
        {"kind":"material","text":"cherry"},{"kind":"note","text":"HOLD for owner approval"},{"kind":"room","text":"Yew"},\
        {"kind":"material","text":"nickel"}]}
        """
    public static let defaultCandidateInstruction = """
        List the rooms, materials, dimensions and notes written in the input. Do not infer, compute or combine anything.
        - room: the name only, without a label such as "Room", "RM" or "Space".
        - material: the material only, without the surface it is on, such as "Finish", "Floor", "Wall", "Base" or "Ceiling".
        - dimension: the value with its units exactly as written, without a label such as "Width" or "Height".
        - note: a whole instruction, exclusion or status line, word for word. Join a note that wraps over several lines.
        One candidate per item. Skip sheet numbers, titles, table column headers, lone numbers and list markers. In a \
        table, list each cell by what its column holds.
        Return only JSON on one line with no extra whitespace: \
        {"candidates":[{"kind":"dimension|room|material|note","text":string}]}.
        \(candidateExample)
        Now the input:
        """

    /// Returns nil and marks the unit when the page can't be read; an unread page is never empty text.
    private func readOCR(_ page: PDFPage, into unit: inout InterpretationUnit) async -> String? {
        let label = "page \(unit.pageIndex + 1)"
        let result: OCRResult
        do {
            result = try await withImage(page, crop: nil) { image in
                try await ask(OCRResult.self, unit: unit, stage: .ocr, instruction: ocrInstruction, text: nil, image: image)
            }
        } catch {
            mark(&unit, error, label: "\(label) OCR")
            return nil
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let problem = text.isEmpty ? "no text read" : (result.confidence ?? 0) < minimumConfidence ? "low confidence"
            : Self.isRepetitive(text) ? "repeated output" : nil
        if let problem { unit.status = .incomplete; unit.coverage.append("\(label) OCR unreadable: \(problem)"); return nil }
        return text
    }

    /// Bounded chunks in order; whatever exceeds the budget is recorded as uninterpreted, never dropped silently.
    private func extract(_ text: String, skipping repeated: Set<String>, sheets: [String], independent: Bool,
                         into unit: inout InterpretationUnit) async {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let skipped = lines.filter(repeated.contains).count
        if skipped > 0 {
            unit.coverage.append("page \(unit.pageIndex + 1): \(skipped) lines repeated on nearly every sheet (title block) not interpreted")
        }
        // The sheet ID is already read from the page, so its line is not sent to the model either. Each distinct line
        // is sent once: repeated input lines set the model repeating one answer until the output budget ran out on
        // real sheets (sending all but back-to-back repeats lost 4 of 17 sheets, against 1).
        // ponytail: a wrapped note whose last line also ended an earlier note reaches the model without that line.
        let readable = lines.filter { !repeated.contains($0) && !sheets.contains($0) }
        var sent = Set<String>()
        let content = readable.filter { sent.insert($0).inserted }
        if content.count < readable.count {
            unit.coverage.append("page \(unit.pageIndex + 1): \(readable.count - content.count) repeats of a line already sent were not sent again")
        }
        var cutOff = false
        let chunks = Self.chunks(content.joined(separator: "\n"), max: budget.maxInputChars, maxLines: budget.maxInputLines)
        unit.plannedChunks = chunks.count; unit.interpretedChunks = 0
        for (index, chunk) in chunks.prefix(budget.maxChunks).enumerated() {
            var raw: RawCandidates, cutHere = false
            do {
                raw = try await ask(RawCandidates.self, unit: unit, stage: .nativeText, instruction: candidateInstruction,
                                    text: chunk, image: nil)
            } catch let cut as Malformed where cut.cutOff {
                // The page still fails, but the candidates the answer finished are kept and later chunks are read:
                // a model stuck repeating one candidate has usually listed the others first.
                cutOff = true; cutHere = true
                unit.coverage.append("page \(unit.pageIndex + 1) chunk \(index + 1): output cut off at the \(budget.reservedOutputTokens)-token output budget")
                guard let kept = Self.decodeBeforeCut(RawCandidates.self, from: cut.output) else { continue }
                raw = kept
            } catch {
                mark(&unit, error, label: "page \(unit.pageIndex + 1) chunk \(index + 1)")
                addSheets(sheets, independent: independent, into: &unit) // read without the model, so kept when it fails
                return
            }
            // Checked against the page without its title block: a line the model never saw supports nothing.
            accept(raw.candidates, verifiedAgainst: (readable + sheets).joined(separator: "\n"), independent: independent, into: &unit)
            if cutHere { continue }
            if raw.unreadable > 0 {
                unit.coverage.append("page \(unit.pageIndex + 1) chunk \(index + 1): \(raw.unreadable) candidates of an unknown kind or shape ignored")
            }
            unit.interpretedChunks = (unit.interpretedChunks ?? 0) + 1 // a cut-off chunk is not counted
        }
        addSheets(sheets, independent: independent, into: &unit)
        if cutOff { unit.status = .failed; return }
        if chunks.count > budget.maxChunks {
            unit.status = .partial
            unit.coverage.append("page \(unit.pageIndex + 1): \(chunks.count - budget.maxChunks) of \(chunks.count) text chunks not interpreted (input budget)")
        }
    }

    /// Sheet IDs are read from the page itself: a label or pattern is more reliable here than asking a model.
    private func addSheets(_ sheets: [String], independent: Bool, into unit: inout InterpretationUnit) {
        for id in sheets where !unit.candidates.contains(where: { $0.kind == .sheet && $0.text == id }) {
            let number = String(format: "%03d", unit.candidates.count + 1)
            unit.candidates.append(InterpretationCandidate(id: "C-\(unit.id.prefix(8))-\(number)", kind: .sheet, text: id, quote: id,
                                                           sourceId: unit.sourceId, pageIndex: unit.pageIndex, bbox: nil,
                                                           confidence: nil, heldReason: independent ? nil : Self.scannedPageHold))
            if !independent, unit.status == .complete { unit.status = .held }
        }
    }

    private func readVision(_ page: PDFPage, crop: [Double], pageText: String, into unit: inout InterpretationUnit) async {
        unit.plannedChunks = 1; unit.interpretedChunks = 0
        let label = "page \(unit.pageIndex + 1) crop \(crop.map { String(Int($0)) }.joined(separator: ","))"
        do {
            let raw = try await withImage(page, crop: crop) { image in
                try await ask(RawCandidates.self, unit: unit, stage: .vision, instruction: candidateInstruction, text: nil, image: image)
            }
            accept(raw.candidates, verifiedAgainst: pageText, independent: !pageText.isEmpty, into: &unit)
            unit.interpretedChunks = 1
        } catch { mark(&unit, error, label: label) }
    }

    /// `independent` is false when the only text is model OCR: a quote checked against output from the same kind of
    /// model proves nothing, so every such candidate stays held until a person checks it against the source image.
    private func accept(_ raw: [RawCandidate], verifiedAgainst text: String, independent: Bool,
                        into unit: inout InterpretationUnit) {
        let source = Self.normalized(text)
        let sourceLines = text.split(separator: "\n").map { Self.normalized(String($0)) }.filter { !$0.isEmpty }
        for item in raw {
            // A candidate that states no quote is checked against the source by its own text, which must sit on one
            // line or be whole consecutive lines (a wrapped note): words from neighbouring lines don't make a dimension.
            let stated = item.quote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // The same kind, text and quote again adds nothing to review.
            if unit.candidates.contains(where: { $0.kind == item.kind && $0.text == item.text && ($0.quote ?? "") == stated }) { continue }
            let quote = stated.isEmpty ? item.text.trimmingCharacters(in: .whitespacesAndNewlines) : stated
            let quoteWords = Self.normalized(quote).split(separator: " ")
            let found = stated.isEmpty ? Self.onOneLineOrWholeLines(Self.normalized(quote), in: sourceLines)
                : Self.containsBounded(source, Self.normalized(quote))
            let reason: String? = quoteWords.isEmpty ? "no source quote"
                : !independent ? Self.scannedPageHold
                : !found ? (stated.isEmpty ? "text not found on a source line" : "quote not found in source text")
                : !Self.isSubsequence(Self.normalized(item.text).split(separator: " "), of: quoteWords)
                    ? "candidate text not supported by its quote"
                : item.confidence.map { $0 < minimumConfidence } == true ? "low confidence" : nil
            let id = "C-\(unit.id.prefix(8))-\(String(format: "%03d", unit.candidates.count + 1))"
            unit.candidates.append(InterpretationCandidate(id: id, kind: item.kind, text: item.text, quote: stated.isEmpty ? nil : stated,
                                                           sourceId: unit.sourceId, pageIndex: unit.pageIndex, bbox: item.bbox,
                                                           confidence: item.confidence, heldReason: reason))
            if reason != nil, unit.status == .complete { unit.status = .held }
        }
    }

    /// One call plus one retry. Throws `Malformed` when neither decodes; interpreter errors propagate.
    private func ask<T: Decodable>(_ type: T.Type, unit: InterpretationUnit, stage: InterpretationStage, instruction: String,
                                   text: String?, image: URL?) async throws -> T {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            if let reason = await gate() { throw Deferral(reason: reason) }
            let request = InterpretationRequest(unitId: unit.id, stage: stage, instruction: instruction, text: text, image: image,
                                                maxOutputTokens: budget.reservedOutputTokens, isRetry: attempt > 0)
            let output = try await interpreter(request)
            try Task.checkCancellation()
            if let decoded = Self.decode(T.self, from: output) { return decoded }
            // Asking again at temperature 0 returns the same overlong answer.
            if Self.isCutOff(output) { throw Malformed(cutOff: true, output: output) }
        }
        throw Malformed(cutOff: false)
    }

    private struct Deferral: Error { var reason: String }
    private struct Malformed: Error { var cutOff: Bool; var output = "" }

    /// The elements a cut-off answer completed: everything up to its last closed object, with the array and object closed.
    static func decodeBeforeCut<T: Decodable>(_ type: T.Type, from output: String) -> T? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        return try? PreconJSON.decoder.decode(T.self, from: Data((output[start...end] + "]}").utf8))
    }

    /// The whole output, or failing that the outermost JSON object in it (models wrap JSON in fences or a sentence).
    static func decode<T: Decodable>(_ type: T.Type, from output: String) -> T? {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = try? PreconJSON.decoder.decode(T.self, from: Data(text.utf8)) { return decoded }
        guard let start = text.firstIndex(of: "{") else { return nil }
        if let end = text.lastIndex(of: "}"), start < end,
           let decoded = try? PreconJSON.decoder.decode(T.self, from: Data(text[start...end].utf8)) { return decoded }
        // A complete answer that only lost its closing brace (seen from a real model) is still read.
        return text.hasSuffix("]") ? try? PreconJSON.decoder.decode(T.self, from: Data((text[start...] + "}").utf8)) : nil
    }

    /// True when JSON stops inside a string, object or array: the model ran out of output tokens. An answer that
    /// closes its array and object is complete however badly its strings are quoted, so that one is asked for again.
    static func isCutOff(_ output: String) -> Bool {
        let compact = output.filter { !$0.isWhitespace }
        if compact.hasSuffix("]}") || compact.hasSuffix("]}```") { return false }
        var depth = 0, inString = false, escaped = false, started = false
        for character in output {
            if escaped { escaped = false; continue }
            if inString { if character == "\\" { escaped = true } else if character == "\"" { inString = false }; continue }
            switch character {
            case "\"": inString = true
            case "{": depth += 1; started = true
            case "[": depth += 1
            case "}", "]": depth -= 1
            default: break
            }
        }
        return started && (inString || depth > 0)
    }

    private func mark(_ unit: inout InterpretationUnit, _ error: Error, label: String) {
        if let malformed = error as? Malformed {
            unit.status = .failed
            unit.coverage.append(malformed.cutOff ? "\(label): output cut off at the \(budget.reservedOutputTokens)-token output budget"
                                 : "\(label): malformed output after retry")
        } else if let deferral = error as? Deferral {
            unit.status = .deferred; unit.coverage.append("\(label) deferred: \(deferral.reason)")
        } else if error is CancellationError {
            unit.status = .deferred; unit.coverage.append("\(label) cancelled")
        } else if let runtime = error as? PreconRuntimeError {
            unit.status = .deferred; unit.coverage.append("\(label) deferred: \(runtime.localizedDescription)")
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

    /// Lowercased with whitespace runs collapsed. Punctuation is kept: "1/2" and "1.2" are different dimensions.
    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Literal match that starts and ends on a word boundary, so "ft" never matches inside "left", and never splits a
    /// number: "2 in" is not in "1/2 in" or ".2 in", "1" is not in "1.2" or "1,200".
    static func containsBounded(_ haystack: String, _ needle: String) -> Bool {
        guard let first = needle.first, let last = needle.last else { return false }
        let text = Array(haystack), word = Array(needle)
        let joins = { (c: Character) in c.isLetter || c.isNumber }
        let numberGlue: Set<Character> = ["/", ".", ","]
        guard word.count <= text.count else { return false }
        for start in 0...(text.count - word.count) where Array(text[start..<(start + word.count)]) == word {
            let end = start + word.count
            let before = start > 0 ? text[start - 1] : nil
            let after = end < text.count ? text[end] : nil, beyondAfter = end + 1 < text.count ? text[end + 1] : nil
            // A glue mark right before a digit is a decimal point or fraction bar even with no whole part (".5").
            let splitsBefore = before.map(joins) ?? false || (first.isNumber && before.map(numberGlue.contains) == true)
            let splitsAfter = after.map(joins) ?? false
                || (last.isNumber && after.map(numberGlue.contains) == true && beyondAfter?.isNumber == true)
            if !splitsBefore && !splitsAfter { return true }
        }
        return false
    }

    static let scannedPageHold = "no independent text layer (scanned page); verify the quote against the source image"

    // Computed, not stored: Regex is not Sendable.
    private static var sheetLabel: Regex<(Substring, Substring)> { #/^SHEET(?:\s+(?:NO\.?|NUMBER|#))?\s*:?\s*(.*)$/#.ignoresCase() }
    private static var sheetToken: Regex<Substring> { #/^[A-Z]{1,8}[.-]?\d{1,3}(?:\.\d{1,2})?$/# }

    /// Sheet IDs from text alone: the token beside a "SHEET:" label, on its line or the next. Without any label, an ID
    /// that starts a line and looks like A101, A-101, S2.1 or A1.01.
    // ponytail: with no label, a door or equipment tag alone on a line (D104) still matches and IDs inside a sentence
    // are skipped. A labelled page never falls back to the pattern, because code references (R314 ...) match it too;
    // so a label whose ID is not on its line or the next gives no ID from text alone. No ID beats a wrong one.
    static func sheetIDs(in text: String) -> [String] {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var found: [String] = [], labelled = false
        for (index, line) in lines.enumerated() {
            guard let match = line.wholeMatch(of: sheetLabel) else { continue }
            let rest = match.output.1.trimmingCharacters(in: .whitespaces)
            let token = rest.isEmpty ? (index + 1 < lines.count ? lines[index + 1] : "") : rest
            guard rest.isEmpty || token.wholeMatch(of: sheetToken) != nil else { continue } // "SHEET INDEX" is not a label
            labelled = true
            if token.wholeMatch(of: sheetToken) != nil, !found.contains(token) { found.append(token) }
        }
        if labelled { return found }
        for line in lines {
            guard let match = line.firstMatch(of: #/^[A-Z]{1,2}-?(?:\d{3}|\d{1,2}\.\d{1,2})(?![A-Za-z0-9.\/-])/#) else { continue }
            if !found.contains(String(match.output)) { found.append(String(match.output)) }
        }
        return found
    }

    /// On a PDF page the ID is the ID-shaped line nearest the "SHEET:" label: a text layer lists title-block strings in
    /// drawing order, so the label and its value are often far apart in the text but next to each other on the sheet.
    /// A label is a line holding nothing else ("SHEET:", "SHEET NUMBER"); "SEE SHEET: A-501" in a note is not one.
    // ponytail: the ID must sit within a tenth of the page's long side of its label; anything else falls back to text.
    static func sheetIDs(on page: PDFPage, text: String) -> [String] {
        let whole = (page.string ?? "") as NSString
        var labels: [CGRect] = [], tokens: [(id: String, bounds: CGRect)] = []
        whole.enumerateSubstrings(in: NSRange(location: 0, length: whole.length), options: .byLines) { line, range, _, _ in
            guard let line = line?.trimmingCharacters(in: .whitespaces),
                  let bounds = page.selection(for: range)?.bounds(for: page) else { return }
            if line.wholeMatch(of: sheetToken) != nil { tokens.append((line, bounds)) }
            else if let label = line.wholeMatch(of: sheetLabel), label.output.1.isEmpty { labels.append(bounds) }
        }
        let box = page.bounds(for: .mediaBox), reach = max(box.width, box.height) / 10
        var found: [String] = []
        for label in labels {
            let near = tokens.map { (id: $0.id, distance: hypot($0.bounds.midX - label.midX, $0.bounds.midY - label.midY)) }
                .filter { $0.distance <= reach }.min { $0.distance < $1.distance }
            if let near, !found.contains(near.id) { found.append(near.id) }
        }
        return found.isEmpty ? sheetIDs(in: text) : found
    }

    /// Lines printed on at least four of every five sheets of a set are title block, not that page's content. A room
    /// name or finish that recurs on the plans sharing one base drawing stays under that share (on the real set
    /// measured, every title-block line was on 14 or more of 17 sheets and nothing else on more than 6).
    // ponytail: exact-line match, rescanned for every page read. A title-block line that wraps differently on some
    // sheets survives, and set-wide status notes are dropped with the rest; cache per document if sets get large.
    static let titleBlockMinimumPages = 5
    static func repeatedLines(in document: PDFDocument) -> Set<String> {
        guard document.pageCount >= titleBlockMinimumPages else { return [] }
        var pagesWithLine: [String: Int] = [:]
        for index in 0..<document.pageCount {
            let lines = (document.page(at: index)?.string ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            for line in Set(lines) where !line.isEmpty { pagesWithLine[line, default: 0] += 1 }
        }
        return Set(pagesWithLine.filter { $0.value * 5 >= document.pageCount * 4 }.keys)
    }

    /// True when the text sits inside one line, or is exactly a run of whole consecutive lines.
    static func onOneLineOrWholeLines(_ text: String, in lines: [String]) -> Bool {
        if lines.contains(where: { containsBounded($0, text) }) { return true }
        for start in lines.indices where text.hasPrefix(lines[start]) {
            var joined = lines[start], next = start + 1
            while joined.count < text.count, next < lines.count { joined += " " + lines[next]; next += 1 }
            if joined == text { return true }
        }
        return false
    }

    /// Every candidate word appears in the quote, in the same order: "10 ft x 12 ft" is not "12 ft x 10 ft".
    static func isSubsequence(_ words: [Substring], of quote: [Substring]) -> Bool {
        var rest = quote[...]
        for word in words {
            guard let index = rest.firstIndex(of: word) else { return false }
            rest = rest[rest.index(after: index)...]
        }
        return !words.isEmpty
    }

    /// Line-bounded chunks of at most `max` characters; overlong lines are split hard.
    static func chunks(_ text: String, max: Int, maxLines: Int = .max) -> [String] {
        var chunks: [String] = []
        var current = "", lines = 0
        for line in text.split(separator: "\n") {
            var rest = Substring(line)
            while !rest.isEmpty {
                let piece = rest.prefix(max); rest = rest.dropFirst(piece.count)
                if !current.isEmpty, current.count + 1 + piece.count > max || lines >= maxLines { chunks.append(current); current = ""; lines = 0 }
                current += current.isEmpty ? piece : "\n" + piece
                lines += 1
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
