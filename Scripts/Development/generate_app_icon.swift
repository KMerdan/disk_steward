import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources/App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: red, green: green, blue: blue, alpha: alpha)
}

func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func render(size: Int) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CocoaError(.fileWriteUnknown) }

    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let tile = rounded(CGRect(x: 62, y: 62, width: 900, height: 900), radius: 218)
    context.saveGState()
    context.addPath(tile)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [color(1.00, 0.68, 0.18), color(0.96, 0.39, 0.07)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 962), end: CGPoint(x: 512, y: 62), options: [])
    context.restoreGState()

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: color(0, 0, 0, 0.24))
    context.addPath(rounded(CGRect(x: 226, y: 300, width: 572, height: 424), radius: 92))
    context.setFillColor(color(0.12, 0.12, 0.12, 0.94))
    context.fillPath()
    context.restoreGState()

    context.addPath(rounded(CGRect(x: 268, y: 342, width: 488, height: 174), radius: 48))
    context.setFillColor(color(0.20, 0.20, 0.20))
    context.fillPath()

    context.addPath(rounded(CGRect(x: 326, y: 575, width: 372, height: 30), radius: 15))
    context.setFillColor(color(1, 1, 1, 0.70))
    context.fillPath()

    context.addEllipse(in: CGRect(x: 638, y: 394, width: 48, height: 48))
    context.setFillColor(color(0.36, 0.90, 0.55))
    context.fillPath()

    context.beginPath()
    context.move(to: CGPoint(x: 354, y: 414))
    context.addLine(to: CGPoint(x: 438, y: 382))
    context.addLine(to: CGPoint(x: 522, y: 414))
    context.addLine(to: CGPoint(x: 438, y: 470))
    context.closePath()
    context.setFillColor(color(1, 1, 1, 0.92))
    context.fillPath()

    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let destinationURL = output.appending(path: "app-icon-\(size).png") as CFURL
    guard let destination = CGImageDestinationCreateWithURL(destinationURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

for size in [16, 32, 64, 128, 256, 512, 1024] {
    try render(size: size)
}
