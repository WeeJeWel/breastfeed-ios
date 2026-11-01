import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let size = 1024
let readme = CommandLine.arguments.contains("--readme")
let alphaInfo: CGImageAlphaInfo = readme ? .premultipliedLast : .noneSkipLast
let bitmap = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: alphaInfo.rawValue)!
let context = NSGraphicsContext(cgContext: bitmap, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(calibratedRed: 0.075, green: 0.059, blue: 0.064, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
             xRadius: readme ? 224 : 0, yRadius: readme ? 224 : 0).fill()
bitmap.translateBy(x: 176, y: 792)
bitmap.scaleBy(x: 24, y: -24)
let breast = NSBezierPath()
breast.move(to: NSPoint(x: 4, y: 3))
breast.line(to: NSPoint(x: 4, y: 7))
breast.curve(to: NSPoint(x: 2, y: 14), controlPoint1: NSPoint(x: 4, y: 10), controlPoint2: NSPoint(x: 2, y: 10))
breast.curve(to: NSPoint(x: 14, y: 14), controlPoint1: NSPoint(x: 2, y: 22), controlPoint2: NSPoint(x: 14, y: 22))
breast.curve(to: NSPoint(x: 26, y: 14), controlPoint1: NSPoint(x: 14, y: 22), controlPoint2: NSPoint(x: 26, y: 22))
breast.curve(to: NSPoint(x: 24, y: 7), controlPoint1: NSPoint(x: 26, y: 10), controlPoint2: NSPoint(x: 24, y: 10))
breast.line(to: NSPoint(x: 24, y: 3))
breast.lineWidth = 2
breast.lineCapStyle = .round
breast.lineJoinStyle = .round
NSColor(srgbRed: 240.0 / 255, green: 105.0 / 255, blue: 146.0 / 255, alpha: 1).setStroke()
breast.stroke()
NSColor(srgbRed: 240.0 / 255, green: 105.0 / 255, blue: 146.0 / 255, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 6.7, y: 12.7, width: 2.6, height: 2.6)).fill()
NSBezierPath(ovalIn: NSRect(x: 18.7, y: 12.7, width: 2.6, height: 2.6)).fill()
NSGraphicsContext.restoreGraphicsState()
let data = NSMutableData()
let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, bitmap.makeImage()!, nil)
CGImageDestinationFinalize(destination)
if readme {
    try (data as Data).write(to: root.appendingPathComponent("AppStore/Icon.png"))
} else {
    for platform in ["iPhone", "Watch"] {
        let directory = root.appendingPathComponent("\(platform)/Assets.xcassets/AppIcon.appiconset")
        try (data as Data).write(to: directory.appendingPathComponent("AppIcon.png"))
        let contents = """
        {"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"\(platform == "iPhone" ? "ios" : "watchos")","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
        """
        try contents.write(to: directory.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    }
}
