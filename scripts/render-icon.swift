import AppKit

let source = CommandLine.arguments[1]
let output = CommandLine.arguments[2]
guard let logo = NSImage(contentsOfFile: source) else {
    fatalError("Could not load i2pd vector logo")
}
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Could not create icon bitmap")
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(srgbRed: 0.18, green: 0.12, blue: 0.32, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
logo.draw(
    in: NSRect(x: 80, y: 80, width: 864, height: 864),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon PNG")
}
try data.write(to: URL(fileURLWithPath: output))
