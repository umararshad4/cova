#!/usr/bin/env swift
import AppKit
import CoreGraphics

// Draws Resources/AppIcon.icns from the notch silhouette itself.
//
// ponytail: procedural, so there is no binary asset to hand-maintain and the mark can be retuned by
// editing numbers. This is a *functional* icon — it stops the blank-document icon appearing inside
// every TCC consent alert — not a brand identity. Replace it with real artwork before launch.

let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources")

/// Apple's rounded-rect ratio for macOS icons: corner radius is 22.37% of the icon square, and the
/// art sits inset inside the 1024 canvas rather than bleeding to the edge.
let cornerRatio: CGFloat = 0.2237
let insetRatio: CGFloat = 0.0938

func notchPath(in rect: CGRect) -> CGPath {
    // Same silhouette as NotchShape: flush with the top edge, concave fillets flaring outward,
    // rounded bottom corners.
    let path = CGMutablePath()
    let topRadius = rect.height * 0.42
    let bottomRadius = rect.height * 0.55

    path.move(to: CGPoint(x: rect.minX - topRadius, y: rect.maxY))
    path.addCurve(
        to: CGPoint(x: rect.minX, y: rect.maxY - topRadius),
        control1: CGPoint(x: rect.minX - topRadius * 0.45, y: rect.maxY),
        control2: CGPoint(x: rect.minX, y: rect.maxY - topRadius * 0.55)
    )
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + bottomRadius))
    path.addArc(
        tangent1End: CGPoint(x: rect.minX, y: rect.minY),
        tangent2End: CGPoint(x: rect.minX + bottomRadius, y: rect.minY),
        radius: bottomRadius
    )
    path.addLine(to: CGPoint(x: rect.maxX - bottomRadius, y: rect.minY))
    path.addArc(
        tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
        tangent2End: CGPoint(x: rect.maxX, y: rect.minY + bottomRadius),
        radius: bottomRadius
    )
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - topRadius))
    path.addCurve(
        to: CGPoint(x: rect.maxX + topRadius, y: rect.maxY),
        control1: CGPoint(x: rect.maxX, y: rect.maxY - topRadius * 0.55),
        control2: CGPoint(x: rect.maxX + topRadius * 0.45, y: rect.maxY)
    )
    path.closeSubpath()
    return path
}

func render(size: CGFloat) -> Data {
    let scale = size / 1024
    guard let context = CGContext(
        data: nil,
        width: Int(size), height: Int(size),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("no context at \(size)") }

    context.scaleBy(x: scale, y: scale)
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let plate = canvas.insetBy(dx: 1024 * insetRatio, dy: 1024 * insetRatio)

    // Rounded plate, lit from the top like the hardware it sits on.
    let plateePath = CGPath(
        roundedRect: plate,
        cornerWidth: 1024 * cornerRatio, cornerHeight: 1024 * cornerRatio,
        transform: nil
    )
    context.saveGState()
    context.addPath(plateePath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(srgbRed: 0.361, green: 0.400, blue: 0.451, alpha: 1),
            CGColor(srgbRed: 0.102, green: 0.118, blue: 0.141, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: plate.midX, y: plate.maxY),
        end: CGPoint(x: plate.midX, y: plate.minY),
        options: []
    )

    // The notch, hanging from the plate's top edge.
    // Narrow enough to read as a notch rather than a bezel, and clear of the plate's own corner
    // radius so both fillets stay visible.
    let notchWidth = plate.width * 0.34
    let notchHeight = plate.height * 0.125
    let notch = CGRect(
        x: plate.midX - notchWidth / 2,
        y: plate.maxY - notchHeight,
        width: notchWidth,
        height: notchHeight
    )
    context.addPath(notchPath(in: notch))
    context.setFillColor(CGColor(srgbRed: 0.02, green: 0.024, blue: 0.031, alpha: 1))
    context.fillPath()

    // Live-activity dot: the one warm note, and the thing the app is actually for.
    let dotDiameter = notchHeight * 0.34
    context.setFillColor(CGColor(srgbRed: 0.890, green: 0.675, blue: 0.275, alpha: 1))
    context.fillEllipse(in: CGRect(
        x: notch.midX - dotDiameter / 2,
        y: notch.midY - dotDiameter / 2,
        width: dotDiameter, height: dotDiameter
    ))

    // Hairline top highlight, so the plate reads as glass rather than a flat swatch.
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
    context.setLineWidth(3)
    context.addPath(plateePath)
    context.strokePath()
    context.restoreGState()

    guard let image = context.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    return png
}

let iconset = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// The exact set `iconutil` expects.
let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    try render(size: size).write(to: iconset.appendingPathComponent("\(name).png"))
}
print("wrote \(iconset.path)")
