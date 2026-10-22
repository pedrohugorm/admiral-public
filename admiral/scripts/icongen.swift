// Renders a source app-icon image into a macOS-style master: inset to the standard
// ~10% grid on a 1024×1024 transparent canvas, with a soft drop shadow.
// Usage: swift icongen.swift <src.png> <out.png>
//
// The source is expected to already carry the icon's silhouette in its alpha — a
// finished squircle with transparent corners. The shadow is cast from that alpha,
// so the art keeps its own corner radius. Feeding an opaque square here yields a
// square icon with a square shadow; shape the art first.
import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else { FileHandle.standardError.write(Data("usage: icongen <src> <out>\n".utf8)); exit(2) }
let size = 1024

guard let srcImage = NSImage(contentsOfFile: args[1]),
      let src = srcImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot load source\n".utf8)); exit(1)
}

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.interpolationQuality = .high
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// Apple grid: 824 body on a 1024 canvas → 100 inset. Nudge up slightly for the shadow.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset + 8, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)

// Draw the source upright, casting a soft contact shadow from its own alpha.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 30, color: NSColor(white: 0, alpha: 0.30).cgColor)
ctx.draw(src, in: body)
ctx.restoreGState()

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
print("wrote \(args[2])")
