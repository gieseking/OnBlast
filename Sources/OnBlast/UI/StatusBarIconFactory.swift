import AppKit
import Foundation

enum StatusBarIconFactory {
    private static let basePointSize: CGFloat = 14

    static func image(for micState: MicState) -> NSImage {
        switch micState {
        case .muted:
            return mutedImage()
        case .live:
            return liveImage()
        case .disconnected:
            return disconnectedImage()
        case .unavailable:
            return symbolImage(systemName: "mic.badge.xmark")
        case .unknown:
            return symbolImage(systemName: "mic")
        }
    }

    private static func liveImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.isTemplate = false

        image.lockFocus()
        defer { image.unlockFocus() }

        drawBaseMic(
            in: NSRect(x: 1.6, y: 1.3, width: 14.8, height: 14.8),
            micColor: NSColor.systemGreen,
            shadowColor: NSColor.black.withAlphaComponent(0.22)
        )
        return image
    }

    private static func mutedImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.isTemplate = false

        image.lockFocus()
        defer { image.unlockFocus() }

        drawBaseMic(
            in: NSRect(x: 1.6, y: 1.3, width: 14.8, height: 14.8),
            micColor: NSColor(calibratedWhite: 0.98, alpha: 1.0),
            shadowColor: NSColor.black.withAlphaComponent(0.28)
        )

        let overlayRect = NSRect(x: 1.25, y: 1.25, width: 15.5, height: 15.5)
        let circlePath = NSBezierPath(ovalIn: overlayRect)
        circlePath.lineWidth = 1.8
        NSColor.systemRed.setStroke()
        circlePath.stroke()

        let slashPath = NSBezierPath()
        slashPath.lineWidth = 1.9
        slashPath.lineCapStyle = .round
        NSColor.systemRed.setStroke()
        slashPath.move(to: NSPoint(x: overlayRect.minX + 2.1, y: overlayRect.minY + 2.3))
        slashPath.line(to: NSPoint(x: overlayRect.maxX - 2.1, y: overlayRect.maxY - 2.3))
        slashPath.stroke()

        return image
    }

    private static func disconnectedImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.isTemplate = false

        image.lockFocus()
        defer { image.unlockFocus() }

        if let disconnectedMic = tintedSymbol(
            systemName: "mic.slash.fill",
            pointSize: 14.2,
            weight: .bold,
            color: NSColor.systemOrange
        ) {
            disconnectedMic.draw(
                in: NSRect(x: 1.6, y: 1.3, width: 14.8, height: 14.8),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }

        return image
    }

    private static func drawBaseMic(
        in micBounds: NSRect,
        micColor: NSColor,
        shadowColor: NSColor
    ) {
        if let shadowMic = tintedSymbol(
            systemName: "mic.fill",
            pointSize: 14.2,
            weight: .bold,
            color: shadowColor
        ) {
            shadowMic.draw(
                in: micBounds.offsetBy(dx: 0, dy: -0.15),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }

        if let mic = tintedSymbol(
            systemName: "mic.fill",
            pointSize: 14.2,
            weight: .bold,
            color: micColor
        ) {
            mic.draw(
                in: micBounds,
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
        }
    }

    private static func tintedSymbol(
        systemName: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            return nil
        }

        let tinted = NSImage(size: symbol.size)
        tinted.isTemplate = false
        tinted.lockFocus()
        defer { tinted.unlockFocus() }

        color.setFill()
        NSRect(origin: .zero, size: symbol.size).fill()
        symbol.draw(
            at: .zero,
            from: NSRect(origin: .zero, size: symbol.size),
            operation: .destinationIn,
            fraction: 1
        )

        return tinted
    }

    private static func symbolImage(systemName: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: basePointSize, weight: .semibold)
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage(size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }
}
