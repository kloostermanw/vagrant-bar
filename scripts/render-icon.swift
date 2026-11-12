// Render an SVG logo into a macOS .iconset (logo centred on a white rounded square,
// following the macOS icon grid). Turn it into .icns with `iconutil -c icns`.
// Usage: swift scripts/render-icon.swift <logo.svg> <out.iconset>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: render-icon.swift <logo.svg> <out.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(pixels: Int) throws -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS grid on a 1024 canvas: 824pt tile with ~185pt corner radius.
    let s = CGFloat(pixels) / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s).fill()

    let inset = tile.insetBy(dx: 150 * s, dy: 150 * s)
    logo.draw(in: inset, from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: outDir.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: outDir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
