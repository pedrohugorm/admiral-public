import XCTest
@testable import AdmiralCore

/// A white glyph on a light tile (yellow, a pale custom color) was barely visible. White stays
/// only where it reaches 3:1 contrast, WCAG's minimum for icons.
final class GlyphContrastTests: XCTestCase {
    /// `#RRGGBB` → linear sRGB, the space luminance is computed in.
    private func whiteReads(_ hex: UInt32) -> Bool {
        func linear(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return GlyphContrast.whiteReads(linearRed: linear(16), linearGreen: linear(8), linearBlue: linear(0))
    }

    func testWhiteStaysOnTheDeeperSwatches() {
        for hex: UInt32 in [0x6C5CE7, 0x2F6BFF, 0x2BA84A, 0xE5484D, 0xEC4899, 0x8E8E93] {
            XCTAssertTrue(whiteReads(hex), String(hex, radix: 16))
        }
    }

    func testTheLightSwatchesAndPaleColorsLoseWhite() {
        for hex: UInt32 in [0x12B5C9, 0xF4C20D, 0xE8912D, 0xFDE68A, 0xA7F3D0, 0xBFDBFE] {
            XCTAssertFalse(whiteReads(hex), String(hex, radix: 16))
        }
    }

    /// White on #949494 is 3.03:1 and on #999999 is 2.85:1, so the cut-off falls between them.
    func testTheCutOffIsThreeToOne() {
        XCTAssertTrue(whiteReads(0x949494))
        XCTAssertFalse(whiteReads(0x999999))
    }
}
