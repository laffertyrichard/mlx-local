import AppKit
import Foundation
import PDFKit

public struct PreconEvaluationCase: Codable, Sendable {
    public var id: String
    public var raster: Bool
    public var lines: [String]
    public var expected: [String]
    public var absent: [String]
    public var widthFeet: Double?
    public var heightFeet: Double?
    public var areaSF: Double?
    public init(id: String, raster: Bool, lines: [String], expected: [String], absent: [String],
                widthFeet: Double? = nil, heightFeet: Double? = nil, areaSF: Double? = nil) {
        self.id = id; self.raster = raster; self.lines = lines; self.expected = expected; self.absent = absent
        self.widthFeet = widthFeet; self.heightFeet = heightFeet; self.areaSF = areaSF
    }
}
public struct PreconEvaluationPage: Sendable {
    public var caseID: String
    public var units: [InterpretationUnit]
    public var nativeText: String
    public init(caseID: String, units: [InterpretationUnit], nativeText: String) {
        self.caseID = caseID; self.units = units; self.nativeText = nativeText
    }
}
public struct PreconEvaluationMetric: Codable, Sendable {
    public var matched: Int?
    public var total: Int?
    public var display: String { guard let matched, let total, total > 0 else { return "unavailable" }; return "\(matched)/\(total)" }
}
public struct PreconEvaluationCoverage: Codable, Sendable {
    public var pagesInterpreted: Int
    public var pagesSkipped: Int
    public var chunksInterpreted: Int?
    public var chunksSkipped: Int?
}
public struct PreconEvaluationScore: Codable, Sendable {
    public var label: String
    public var extraction: PreconEvaluationMetric
    public var sourceSupport: PreconEvaluationMetric
    public var coverage: PreconEvaluationCoverage
    public var quantityAccuracy: PreconEvaluationMetric
    public var absentItemsFound: [String]
    public func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var object = try JSONSerialization.jsonObject(with: encoder.encode(self)) as! [String: Any]
        for (name, metric) in [("extraction",extraction),("sourceSupport",sourceSupport),("quantityAccuracy",quantityAccuracy)] {
            object[name] = ["matched": metric.matched as Any? ?? NSNull(), "total": metric.total as Any? ?? NSNull(), "result":metric.display]
        }
        if coverage.chunksInterpreted == nil { object["chunkCoverage"] = "unavailable" }
        return String(data: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted,.sortedKeys]), encoding:.utf8)!
    }
}
public struct PreconEvaluationSet: Codable, Sendable {
    public var label: String
    public var cases: [PreconEvaluationCase]
    public init(label: String, cases: [PreconEvaluationCase]) { self.label = label; self.cases = cases }
    public static func load(_ url: URL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }

    /// Input text is drawn at fixed positions; the scan case embeds pixels only, never a hidden text layer.
    public func generate(_ item: PreconEvaluationCase, in directory: URL) throws -> URL {
        let url = directory.appending(path: StableDigest.sha256(Data(item.id.utf8)) + ".pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        let draw = {
            NSColor.white.setFill(); NSBezierPath(rect: box).fill()
            for (index,line) in item.lines.enumerated() {
                NSAttributedString(string: line, attributes: [.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.black])
                    .draw(at: NSPoint(x:36,y:720-index*36))
            }
        }
        NSGraphicsContext.saveGraphicsState()
        if item.raster {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:612, pixelsHigh:792, bitsPerSample:8,
                                               samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB,
                                               bytesPerRow:0, bitsPerPixel:0), let graphics = NSGraphicsContext(bitmapImageRep:bitmap) else {
                throw CocoaError(.fileWriteUnknown)
            }
            NSGraphicsContext.current = graphics; draw()
            if let image = bitmap.cgImage { context.draw(image, in: box) }
        } else { NSGraphicsContext.current = NSGraphicsContext(cgContext:context, flipped:false); draw() }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        return url
    }

    public func evaluate(adapter: PreconRuntimeInterpreter, in workspace: URL) async throws -> [PreconEvaluationPage] {
        let store = try PreconProjectStore(root: workspace), project = workspace.appending(path: "project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var pages: [PreconEvaluationPage] = []
        for item in cases {
            try Task.checkCancellation()
            let pdf = try generate(item, in: workspace)
            let sources = try store.importSource(pdf, into: project, role: .proposed, revision: "EVAL")
            let pipeline = try await adapter.pipeline(store: store, project: project)
            let units = try await pipeline.run(sources)
            let document = PDFDocument(url: pdf)
            let native = document?.page(at: 0)?.string ?? ""
            withExtendedLifetime(document) {}
            pages.append(.init(caseID: item.id, units: units, nativeText: native))
            if units.contains(where: { $0.status == .deferred }) { break }
        }
        return pages
    }

    public func report(_ pages: [PreconEvaluationPage], label: String) throws -> Data {
        let score = try score(pages, label: label)
        return try JSONSerialization.data(withJSONObject: [
            "metrics": JSONSerialization.jsonObject(with: Data(score.json().utf8)),
            "units": JSONSerialization.jsonObject(with: PreconJSON.encoder.encode(pages.flatMap(\.units)))
        ], options: [.prettyPrinted, .sortedKeys])
    }

    public func score(_ pages: [PreconEvaluationPage], label: String) throws -> PreconEvaluationScore {
        guard Set(cases.map(\.id)).count == cases.count, Set(pages.map(\.caseID)).count == pages.count,
              Set(pages.map(\.caseID)).isSubset(of: Set(cases.map(\.id))) else { throw CocoaError(.validationMissingMandatoryProperty) }
        var found = 0, expected = 0, supported = 0, candidates = 0, interpreted = 0, chunks = 0, skipped = 0
        var knownChunks = true, quantities = 0, correctQuantities = 0
        var absent: [String] = []
        for item in cases {
            expected += item.expected.count
            let page = pages.first { $0.caseID == item.id }
            let units = page?.units ?? []
            let items = units.flatMap(\.candidates)
            found += item.expected.filter { value in items.contains { $0.text == value } }.count
            absent += item.absent.filter { value in items.contains { $0.text == value } }.map { "\(item.id): \($0)" }
            candidates += items.count
            supported += items.filter { candidate in
                guard !item.raster, let quote = candidate.quote, !quote.isEmpty else { return false }
                return (page?.nativeText ?? "").contains(quote)
            }.count
            if !units.isEmpty && units.allSatisfy({ [.complete,.held].contains($0.status) }) { interpreted += 1 }
            if units.isEmpty { knownChunks = false }
            for unit in units {
                if let planned = unit.plannedChunks, let done = unit.interpretedChunks {
                    chunks += done; skipped += max(0,planned-done)
                } else { knownChunks = false }
            }
            if let width = item.widthFeet, let height = item.heightFeet, let area = item.areaSF {
                let plane = AreaPlane(source:.init(file:item.id,sheet:"synthetic",pageIndex:0,revision:"EVAL"),
                                      lengthUnit:"ft",areaUnit:"SF",scale:1,zones:[.init(id:"Z",name:"Known geometry",finish:nil)],
                                      polys:[.init(id:"P",zone:"Z",sign:1,pts:[[0,0],[width,0],[width,height],[0,height]])])
                let result = try Takeoff.area(plane)
                quantities += 1
                if abs(result.net-area) < 0.000001 { correctQuantities += 1 }
            }
        }
        return PreconEvaluationScore(label:label,
            extraction:.init(matched:expected == 0 ? nil : found,total:expected == 0 ? nil : expected),
            sourceSupport:.init(matched:candidates == 0 ? nil : supported,total:candidates == 0 ? nil : candidates),
            coverage:.init(pagesInterpreted:interpreted,pagesSkipped:cases.count-interpreted,
                           chunksInterpreted:knownChunks ? chunks : nil,chunksSkipped:knownChunks ? skipped : nil),
            quantityAccuracy:.init(matched:quantities == 0 ? nil : correctQuantities,total:quantities == 0 ? nil : quantities),
            absentItemsFound:absent)
    }
}

public struct PreconEvaluationOptions: Sendable {
    public var textModelID: String
    public var imageModelID: String?
    public var output: String
    public var dataset: String
    public static let usage = "Refused without authorization. Usage: PreconEvaluation --authorized --text-model <installed-id> [--image-model <installed-id>] --output <new-report.json> [--dataset <expected.json>]"
    public static func parse(_ arguments: [String]) throws -> Self {
        var values: [String:String] = [:], authorized = false, index = 0
        while index < arguments.count {
            let key = arguments[index]; index += 1
            if key == "--authorized" { guard !authorized else { throw CocoaError(.validationMissingMandatoryProperty) }; authorized = true; continue }
            guard ["--text-model","--image-model","--output","--dataset"].contains(key), values[key] == nil,
                  index < arguments.count, !arguments[index].isEmpty, !arguments[index].hasPrefix("--") else {
                throw CocoaError(.validationMissingMandatoryProperty)
            }
            values[key] = arguments[index]; index += 1
        }
        guard authorized, let model = values["--text-model"], let output = values["--output"] else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        return Self(textModelID:model,imageModelID:values["--image-model"],output:output,
                    dataset:values["--dataset"] ?? "Tests/LocalLLMCoreTests/Fixtures/precon-eval/expected.json")
    }
}
