import Foundation
import PDFKit

/// Maps between a page as displayed (rotation applied) and the stored geometry frame:
/// PDF points from the media box top-left, x right, y down, original unrotated page.
public struct PageFrame: Equatable, Sendable {
    public let width: Double
    public let height: Double
    /// Clockwise display rotation, as PDF /Rotate.
    public let rotation: Int

    public init(width: Double, height: Double, rotation: Int) {
        self.width = width; self.height = height
        self.rotation = ((rotation % 360) + 360) % 360
    }

    public init(_ page: PDFPage) {
        let box = page.bounds(for: .mediaBox)
        self.init(width: box.width, height: box.height, rotation: page.rotation)
    }

    public var displaySize: CGSize {
        rotation % 180 == 0 ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
    }

    public func toPage(_ p: [Double]) -> [Double] {
        let (x, y) = (p[0], p[1])
        switch rotation {
        case 90: return [y, height - x]
        case 180: return [width - x, height - y]
        case 270: return [width - y, x]
        default: return [x, y]
        }
    }

    public func toDisplay(_ p: [Double]) -> [Double] {
        let (x, y) = (p[0], p[1])
        switch rotation {
        case 90: return [height - y, x]
        case 180: return [width - x, height - y]
        case 270: return [y, width - x]
        default: return [x, y]
        }
    }

    /// Media box as displayed, at exactly displaySize * scale so taps map without letterboxing.
    public static func render(_ page: PDFPage, scale: Double) -> NSImage {
        let size = PageFrame(page).displaySize
        return page.thumbnail(of: CGSize(width: size.width * scale, height: size.height * scale), for: .mediaBox)
    }
}
