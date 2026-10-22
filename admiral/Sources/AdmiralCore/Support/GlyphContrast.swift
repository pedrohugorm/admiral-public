import Foundation

/// Whether a white glyph reads on a colored tile. A white glyph on a light tile (yellow, a pale
/// custom color) was barely visible, so white stays only where it reaches 3:1 contrast, WCAG's
/// minimum for icons; elsewhere the tile draws its glyph in a deep shade of its own color.
public enum GlyphContrast {
    /// The components are linear sRGB, the space relative luminance is defined in.
    public static func whiteReads(linearRed: Double, linearGreen: Double, linearBlue: Double) -> Bool {
        let luminance = 0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
        return (1 + 0.05) / (luminance + 0.05) >= 3
    }
}
