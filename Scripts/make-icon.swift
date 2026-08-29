// Generates Resources/AppIcon.icns: dark squircle with the neon waterfall motif.
// Run via Scripts/package.sh (or: swift Scripts/make-icon.swift <output-dir>).
import AppKit

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size,
                    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func neon(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

let cyan = neon(0.0, 0.92, 1.0)
let magenta = neon(1.0, 0.2, 0.85)

// macOS icon grid: ~824pt squircle centered in the 1024 canvas.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.addPath(squircle)
ctx.clip()
ctx.setFillColor(neon(0.035, 0.03, 0.07))
ctx.fill(plate)

// Subtle vertical glow gradient at the bottom (synthwave horizon).
let gradient = CGGradient(colorsSpace: colorSpace,
                          colors: [neon(0.35, 0.05, 0.35, 0.55), neon(0.035, 0.03, 0.07, 0)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: 512, y: 100),
                       end: CGPoint(x: 512, y: 560),
                       options: [])

// Ridgeline waves, back (cyan, faint) to front (magenta, hot).
srand48(7)
let rows = 7
for i in 0..<rows {
    let t = CGFloat(i) / CGFloat(rows - 1)          // 0 = back
    let inset: CGFloat = 170 + (1 - t) * 60
    let yBase: CGFloat = 660 - t * 330
    let amp: CGFloat = 60 + t * 130

    let path = CGMutablePath()
    let n = 48
    for j in 0...n {
        let x = inset + (1024 - 2 * inset) * CGFloat(j) / CGFloat(n)
        let u = CGFloat(j) / CGFloat(n)
        // A few summed sines make a plausible "spectrum" ridge.
        let ridge = pow(sin(u * .pi), 0.8) *
            (0.55 + 0.30 * sin(u * 21 + t * 5) + 0.15 * sin(u * 47 + t * 11))
        let y = yBase + max(0, ridge) * amp
        if j == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }

    // Occlude what's behind, then stroke with glow.
    let silhouette = path.mutableCopy()!
    silhouette.addLine(to: CGPoint(x: 1024 - inset, y: yBase - 20))
    silhouette.addLine(to: CGPoint(x: inset, y: yBase - 20))
    silhouette.closeSubpath()
    ctx.setFillColor(neon(0.035, 0.03, 0.07, 0.94))
    ctx.addPath(silhouette)
    ctx.fillPath()

    let color = neon(0.1 + 0.9 * t, 0.85 - 0.62 * t, 1.0 - 0.15 * t, 0.35 + 0.65 * t)
    ctx.setShadow(offset: .zero, blur: 14 + t * 10, color: color)
    ctx.setStrokeColor(color)
    ctx.setLineWidth(4 + t * 6)
    ctx.setLineJoin(.round)
    ctx.addPath(path)
    ctx.strokePath()
}

ctx.setShadow(offset: .zero, blur: 0, color: nil)

let image = ctx.makeImage()!

// Write the iconset and compile to .icns.
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconset = "\(outDir)/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for pts in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = pts * scale
        let scaled = CGContext(data: nil, width: px, height: px,
                               bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        scaled.interpolationQuality = .high
        scaled.draw(image, in: CGRect(x: 0, y: 0, width: px, height: px))
        let out = scaled.makeImage()!
        let name = scale == 1 ? "icon_\(pts)x\(pts).png" : "icon_\(pts)x\(pts)@2x.png"
        let url = URL(fileURLWithPath: "\(iconset)/\(name)")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, out, nil)
        CGImageDestinationFinalize(dest)
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset, "-o", "\(outDir)/AppIcon.icns"]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(atPath: iconset)
print("wrote \(outDir)/AppIcon.icns")
