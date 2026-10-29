import AppKit
import ImageIO
import SwiftUI

enum ArtworkColorSampler {
    static func sample(
        from data: Data?,
        brightness: ClosedRange<CGFloat>,
        minimumSaturation: CGFloat,
        fallback: Color
    ) -> Color {
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32
              ] as CFDictionary) else { return fallback }

        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        let stepX = max(1, bitmap.pixelsWide / 10)
        let stepY = max(1, bitmap.pixelsHigh / 10)
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                red += color.redComponent
                green += color.greenComponent
                blue += color.blueComponent
                count += 1
            }
        }
        guard count > 0 else { return fallback }

        let average = NSColor(calibratedRed: red / count, green: green / count, blue: blue / count, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, value: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &value, alpha: &alpha)
        return Color(
            hue: hue,
            saturation: max(minimumSaturation, saturation),
            brightness: min(brightness.upperBound, max(brightness.lowerBound, value))
        )
    }
}
