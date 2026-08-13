import Foundation

/// Fast, claim-level validation for multi-image dimension arithmetic. It abstains unless it can
/// parse every area claim it touches; the existing model validator remains the fallback.
public enum DeterministicClaimValidator {
    public static func validateMultiImage(_ artifacts: [PipelineArtifact]) -> PipelineArtifact? {
        guard let synthesis = artifacts.last(where: { $0.kind == .finalResponse || $0.kind == .markdown || $0.kind == .text || $0.kind == .visionObservations }),
              artifacts.flatMap(\.sourceURLs).uniqued.count >= 2 else { return nil }
        if let structured = validateStructuredConstruction(synthesis.content, sourceURLs: artifacts.flatMap(\.sourceURLs).uniqued) {
            return structured
        }
        let pattern = #"(?i)(\d{1,3})(?:\s*['’]\s*[-–]?\s*(\d{1,2})?\s*(?:[\"”])?)?\s*(?:x|×|by)\s*(\d{1,3})(?:\s*['’]\s*[-–]?\s*(\d{1,2})?\s*(?:[\"”])?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let text = synthesis.content
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }
        var corrections: [(NSRange, String)] = []
        var checks: [String] = []
        let areaRegex = try? NSRegularExpression(pattern: #"(?i)(\d+(?:\.\d+)?)\s*(?:sq\.?\s*ft|square\s*feet|ft²)"#)
        for match in matches {
            func number(_ index: Int) -> Double {
                guard match.range(at: index).location != NSNotFound else { return 0 }
                return Double(ns.substring(with: match.range(at: index))) ?? 0
            }
            let width = number(1) + number(2) / 12
            let height = number(3) + number(4) / 12
            guard width > 0, height > 0 else { return nil }
            let expected = width * height
            let searchStart = match.range.location + match.range.length
            let searchLength = min(100, ns.length - searchStart)
            if searchLength > 0, let area = areaRegex?.firstMatch(in: text, range: NSRange(location: searchStart, length: searchLength)) {
                let valueRange = area.range(at: 1)
                let observed = Double(ns.substring(with: valueRange)) ?? -1
                if abs(observed - expected) > 0.51 {
                    let formatted = expected.rounded() == expected ? String(Int(expected)) : String(format: "%.2f", expected)
                    corrections.append((valueRange, formatted))
                }
            }
            checks.append("\(width) × \(height) = \(expected) sq ft")
        }
        let mutable = NSMutableString(string: text)
        for (range, replacement) in corrections.sorted(by: { $0.0.location > $1.0.location }) { mutable.replaceCharacters(in: range, with: replacement) }
        var metadata = synthesis.metadata
        metadata["execution"] = "deterministic"
        metadata["validator"] = "dimension-arithmetic-v1"
        metadata["claims_checked"] = String(checks.count)
        metadata["corrections"] = String(corrections.count)
        metadata["validation_scope"] = "area_arithmetic_only"
        return PipelineArtifact(kind: .finalResponse, content: mutable as String,
            sourceURLs: artifacts.flatMap(\.sourceURLs).uniqued, confidence: nil, metadata: metadata)
    }
    private static func validateStructuredConstruction(_ text: String, sourceURLs: [URL]) -> PipelineArtifact? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            let lines = candidate.split(separator: "\n", omittingEmptySubsequences: false)
            guard lines.count >= 3 else { return nil }
            candidate = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        guard let data = candidate.data(using: .utf8), let raw = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var rooms: [[String: Any]] = []
        var normalizedObject: [String: Any]
        if let object = raw as? [String: Any], let values = object["rooms"] as? [[String: Any]] {
            rooms = values; normalizedObject = object
        } else if let list = raw as? [[String: Any]] {
            rooms = list.filter { $0["source_image"] != nil }
            normalizedObject = ["rooms": rooms,
                "comparison": list.first(where: { $0["comparison"] != nil })?["comparison"] ?? NSNull()]
        } else { return nil }
        guard rooms.count >= 2, sourceURLs.count >= rooms.count else { return nil }
        var corrections = 0
        for index in rooms.indices {
            guard let sourceIndex = (rooms[index]["source_image"] as? NSNumber)?.intValue,
                  (1...sourceURLs.count).contains(sourceIndex),
                  let label = rooms[index]["label"] as? String,
                  !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 256,
                  rooms[index].keys.contains("uncertainty"),
                  let width = (rooms[index]["width_ft"] as? NSNumber)?.doubleValue,
                  let length = (rooms[index]["length_ft"] as? NSNumber)?.doubleValue,
                  width.isFinite, length.isFinite, width > 0, length > 0, width < 100_000, length < 100_000 else { return nil }
            let expected = width * length
            guard expected.isFinite, expected < 10_000_000_000 else { return nil }
            let observed = (rooms[index]["area_sq_ft"] as? NSNumber)?.doubleValue
            if observed == nil || !observed!.isFinite || abs(observed! - expected) > 0.01 {
                rooms[index]["area_sq_ft"] = expected; corrections += 1
            }
        }
        normalizedObject["rooms"] = rooms
        guard let output = try? JSONSerialization.data(withJSONObject: normalizedObject, options: [.sortedKeys]),
              let content = String(data: output, encoding: .utf8) else { return nil }
        return PipelineArtifact(kind: .finalResponse, content: content, sourceURLs: sourceURLs,
            metadata: ["execution": "deterministic", "validator": "construction-json-arithmetic-v1",
                       "validation_scope": "area_arithmetic_only", "claims_checked": String(rooms.count),
                       "corrections": String(corrections)])
    }
}

private extension Array where Element == URL {
    var uniqued: [URL] { var seen = Set<URL>(); return filter { seen.insert($0).inserted } }
}
