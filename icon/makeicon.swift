import AppKit

// Draws the app icon: a waveform whose frequency steps up partway across —
// the thing the app does, matching the rate to the source.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { image.unlockFocus(); return image }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = size * 0.2237   // macOS squircle-ish
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                      transform: nil)
    ctx.addPath(path)
    ctx.clip()

    // Background: deep indigo → violet
    let colors = [NSColor(srgbRed: 0.11, green: 0.13, blue: 0.28, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.29, green: 0.18, blue: 0.51, alpha: 1).cgColor]
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0), options: [])
    }

    // Level bars rising then falling. Bars stay legible at 16px where a drawn
    // waveform turns to mush, and the rounded caps read as audio rather than a
    // generic chart.
    let heights: [CGFloat] = [0.34, 0.60, 0.86, 1.0, 0.74, 0.48, 0.28]
    let barWidth = size * 0.077
    let gap = size * 0.038
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let startX = (size - totalWidth) / 2
    let maxHeight = size * 0.50
    let centerY = size * 0.5

    ctx.setFillColor(NSColor.white.cgColor)
    for (index, factor) in heights.enumerated() {
        let height = maxHeight * factor
        let x = startX + CGFloat(index) * (barWidth + gap)
        let bar = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
        ctx.addPath(CGPath(roundedRect: bar,
                           cornerWidth: barWidth / 2, cornerHeight: barWidth / 2,
                           transform: nil))
    }
    ctx.fillPath()

    image.unlockFocus()
    return image
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Ratebridge.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in specs {
    let image = drawIcon(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("iconset written to \(out)")
