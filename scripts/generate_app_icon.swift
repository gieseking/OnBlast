#!/usr/bin/env swift

import AppKit
import Foundation

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let rootDirectory = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let appDirectory = rootDirectory.appendingPathComponent("App", isDirectory: true)
let iconsetURL = appDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let icnsURL = appDirectory.appendingPathComponent("AppIcon.icns")

let iconSizes: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

for iconSize in iconSizes {
    let pixels = iconSize.points * iconSize.scale
    let image = drawIcon(size: pixels)
    let imageRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    imageRep.size = NSSize(width: iconSize.points, height: iconSize.points)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: imageRep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = imageRep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateAppIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG for \(pixels)x\(pixels)"])
    }

    let filename = "icon_\(iconSize.points)x\(iconSize.points)\(iconSize.scale == 2 ? "@2x" : "").png"
    try pngData.write(to: iconsetURL.appendingPathComponent(filename))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "GenerateAppIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}

func drawIcon(size pixels: Int) -> NSImage {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let canvas = NSRect(origin: .zero, size: size)
    let inset = CGFloat(pixels) * 0.06
    let iconRect = canvas.insetBy(dx: inset, dy: inset)
    let cornerRadius = CGFloat(pixels) * 0.23

    let shadow = NSShadow()
    shadow.shadowBlurRadius = CGFloat(pixels) * 0.04
    shadow.shadowOffset = NSSize(width: 0, height: -CGFloat(pixels) * 0.015)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.set()

    let backgroundPath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.17, green: 0.19, blue: 0.24, alpha: 1.0),
        NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1.0)
    ])!
    gradient.draw(in: backgroundPath, angle: -90)

    NSGraphicsContext.saveGraphicsState()
    backgroundPath.addClip()

    let highlightRect = NSRect(
        x: iconRect.minX,
        y: iconRect.midY,
        width: iconRect.width,
        height: iconRect.height * 0.6
    )
    let highlight = NSGradient(colors: [
        NSColor.white.withAlphaComponent(0.16),
        NSColor.white.withAlphaComponent(0.0)
    ])!
    highlight.draw(in: highlightRect, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    let micRect = NSRect(
        x: iconRect.minX + iconRect.width * 0.19,
        y: iconRect.minY + iconRect.height * 0.12,
        width: iconRect.width * 0.62,
        height: iconRect.height * 0.71
    )
    drawMicGlyph(in: micRect, pixelSize: CGFloat(pixels))

    let overlayRect = NSRect(
        x: iconRect.minX + iconRect.width * 0.16,
        y: iconRect.minY + iconRect.height * 0.16,
        width: iconRect.width * 0.68,
        height: iconRect.height * 0.68
    )
    drawMuteOverlay(in: overlayRect, pixelSize: CGFloat(pixels))

    let borderPath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
    borderPath.lineWidth = max(1, CGFloat(pixels) * 0.01)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    borderPath.stroke()

    return image
}

func drawMicGlyph(in rect: NSRect, pixelSize: CGFloat) {
    let bodyRect = NSRect(
        x: rect.minX + rect.width * 0.29,
        y: rect.minY + rect.height * 0.26,
        width: rect.width * 0.42,
        height: rect.height * 0.58
    )
    let bodyRadius = bodyRect.width * 0.5

    let stemPath = NSBezierPath()
    stemPath.lineWidth = max(2.0, pixelSize * 0.028)
    stemPath.lineCapStyle = .round
    stemPath.move(to: NSPoint(x: rect.midX, y: bodyRect.minY - rect.height * 0.04))
    stemPath.line(to: NSPoint(x: rect.midX, y: rect.minY + rect.height * 0.11))

    let basePath = NSBezierPath()
    basePath.lineWidth = max(2.0, pixelSize * 0.028)
    basePath.lineCapStyle = .round
    basePath.move(to: NSPoint(x: rect.midX - rect.width * 0.20, y: rect.minY + rect.height * 0.08))
    basePath.line(to: NSPoint(x: rect.midX + rect.width * 0.20, y: rect.minY + rect.height * 0.08))

    let yokePath = NSBezierPath()
    yokePath.lineWidth = max(2.0, pixelSize * 0.028)
    yokePath.lineCapStyle = .round
    yokePath.move(to: NSPoint(x: rect.minX + rect.width * 0.21, y: bodyRect.minY + rect.height * 0.085))
    yokePath.curve(
        to: NSPoint(x: rect.maxX - rect.width * 0.21, y: bodyRect.minY + rect.height * 0.085),
        controlPoint1: NSPoint(x: rect.minX + rect.width * 0.21, y: rect.minY + rect.height * 0.025),
        controlPoint2: NSPoint(x: rect.maxX - rect.width * 0.21, y: rect.minY + rect.height * 0.025)
    )

    if let shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor.copy(alpha: 0.22) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = pixelSize * 0.014
        shadow.shadowOffset = NSSize(width: 0, height: -pixelSize * 0.008)
        shadow.shadowColor = NSColor(cgColor: shadowColor)
        shadow.set()
    }

    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: bodyRadius, yRadius: bodyRadius)
    let bodyGradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.98, alpha: 1.0),
        NSColor(calibratedWhite: 0.90, alpha: 1.0)
    ])!
    bodyGradient.draw(in: bodyPath, angle: -90)

    NSColor(calibratedWhite: 0.95, alpha: 1.0).setStroke()
    stemPath.stroke()
    basePath.stroke()
    yokePath.stroke()
}

func drawMuteOverlay(in rect: NSRect, pixelSize: CGFloat) {
    let ringPath = NSBezierPath(ovalIn: rect)
    ringPath.lineWidth = max(4.0, pixelSize * 0.042)
    NSColor.systemRed.setStroke()
    ringPath.stroke()

    let slashPath = NSBezierPath()
    slashPath.lineWidth = max(4.0, pixelSize * 0.045)
    slashPath.lineCapStyle = .round
    slashPath.move(to: NSPoint(x: rect.minX + rect.width * 0.16, y: rect.minY + rect.height * 0.18))
    slashPath.line(to: NSPoint(x: rect.maxX - rect.width * 0.16, y: rect.maxY - rect.height * 0.18))
    NSColor.systemRed.setStroke()
    slashPath.stroke()
}
