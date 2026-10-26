import Foundation
import PDFKit

public enum CandidateReviewLabel: String, Sendable { case offered, held, accepted, rejected, stale }

public enum PreconReadPage {
    public static func textModels(_ models: [RegisteredModel]) -> [RegisteredModel] {
        models.filter { $0.capabilities.contains(.reasoning) && $0.inputModalities.contains(.text) && $0.supportsStructuredOutput }
            .sorted { $0.id < $1.id }
    }
    public static func imageModels(_ models: [RegisteredModel]) -> [RegisteredModel] {
        models.filter { !$0.capabilities.isDisjoint(with: [.ocr, .vision]) && $0.inputModalities.contains(.image) && $0.supportsStructuredOutput }
            .sorted { $0.id < $1.id }
    }
    public static func reviewState(_ candidate: InterpretationCandidate, review: CandidateReviewState?) -> CandidateReviewLabel {
        guard let review else { return candidate.heldReason == nil ? .offered : .held }
        if review.stale { return .stale }
        return review.record.decision == .accepted ? .accepted : .rejected
    }
    public static func cropRect(_ bbox: [Double]?, frame: PageFrame, pixelWidth: Double) -> CGRect? {
        guard let bbox, bbox.count == 4, bbox.allSatisfy(\.isFinite), pixelWidth.isFinite, pixelWidth > 0,
              frame.width > 0, frame.height > 0, bbox[0] >= 0, bbox[1] >= 0, bbox[2] > 0, bbox[3] > 0,
              bbox[0] + bbox[2] <= frame.width, bbox[1] + bbox[3] <= frame.height else { return nil }
        let corners = [[bbox[0],bbox[1]], [bbox[0]+bbox[2],bbox[1]],
                       [bbox[0],bbox[1]+bbox[3]], [bbox[0]+bbox[2],bbox[1]+bbox[3]]].map(frame.toDisplay)
        let x = corners.map { $0[0] }, y = corners.map { $0[1] }
        let scale = pixelWidth / frame.displaySize.width
        return CGRect(x: x.min()! * scale, y: y.min()! * scale,
                      width: (x.max()! - x.min()!) * scale, height: (y.max()! - y.min()!) * scale).integral
    }
    public static func thumbnail(_ candidate: InterpretationCandidate, source: SourceRecord,
                                 store: PreconProjectStore, project: URL) throws -> Data? {
        guard candidate.bbox != nil else { return nil }
        let url = try store.contained(project.appending(path: source.path))
        guard try StableDigest.file(url) == source.sha256, candidate.sourceId == source.id,
              candidate.pageIndex == source.pageIndex, let document = PDFDocument(url: url),
              let page = document.page(at: source.pageIndex) else { throw PreconProjectError.sourceChanged(source.path) }
        defer { withExtendedLifetime(document) {} }
        let image = PageFrame.render(page, scale: 1)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let rect = cropRect(candidate.bbox, frame: PageFrame(page), pixelWidth: Double(cg.width)),
              let crop = cg.cropping(to: rect) else { return nil }
        return NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:])
    }
}
