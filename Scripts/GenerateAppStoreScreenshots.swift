import AppKit
import ImageIO
import UniformTypeIdentifiers

let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("AppStore/Screenshots")
let titles = ["Track every\nbreastfeed.", "Left. Right.\nPump. Bottle.", "Share the\nnight shift.", "Apple Watch.\nLive Activities."]
let subtitles = ["Every feed in one simple timeline.", "A few taps. Everything recorded.", "One journal, together with iCloud.", "On your wrist. On your Lock Screen."]
let sources = ["timeline", "feeding", "sharing", "activity"]
let pink = NSColor(srgbRed: 240/255, green: 105/255, blue: 146/255, alpha: 1)
let colorSpace = CGColorSpaceCreateDeviceRGB()
let centered = NSMutableParagraphStyle()
centered.alignment = .center
centered.lineSpacing = -8
var results: [CGImage] = []

for index in 0..<4 {
    let cg = CGContext(data: nil, width: 1320, height: 2868, bitsPerComponent: 8, bytesPerRow: 5280, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    NSColor(srgbRed: 0.065, green: 0.047, blue: 0.06, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1320, height: 2868)).fill()
    let glow = CGGradient(colorsSpace: colorSpace, colors: [NSColor(srgbRed: 0.27, green: 0.10, blue: 0.17, alpha: 1).cgColor, NSColor(srgbRed: 0.065, green: 0.047, blue: 0.06, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(glow, startCenter: CGPoint(x: 660, y: 900), startRadius: 0, endCenter: CGPoint(x: 660, y: 900), endRadius: 1700, options: [])
    let brandFont = NSFont.systemFont(ofSize: 34, weight: .semibold)
    ("BreastFeed" as NSString).draw(in: NSRect(x: 80, y: 2700, width: 1160, height: 58), withAttributes: [.font: brandFont, .foregroundColor: NSColor(calibratedWhite: 0.86, alpha: 1), .paragraphStyle: centered, .kern: 1.2])

    let mask = CGContext(data: nil, width: 1320, height: 2868, bitsPerComponent: 8, bytesPerRow: 5280, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: mask, flipped: false)
    let baseFont = NSFont.systemFont(ofSize: index == 3 ? 118 : 130, weight: .bold)
    let roundedFont = NSFont(descriptor: baseFont.fontDescriptor.withDesign(.rounded)!, size: baseFont.pointSize)!
    (titles[index] as NSString).draw(in: NSRect(x: 50, y: 2325, width: 1220, height: 330), withAttributes: [.font: roundedFont, .foregroundColor: NSColor.white, .paragraphStyle: centered, .kern: -4])
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    cg.saveGState()
    cg.clip(to: CGRect(x: 0, y: 0, width: 1320, height: 2868), mask: mask.makeImage()!)
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [NSColor(srgbRed: 1, green: 0.77, blue: 0.83, alpha: 1).cgColor, pink.cgColor, NSColor(srgbRed: 0.91, green: 0.29, blue: 0.50, alpha: 1).cgColor] as CFArray, locations: [0, 0.55, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 2660), end: CGPoint(x: 1170, y: 2330), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
    (subtitles[index] as NSString).draw(in: NSRect(x: 40, y: 2250, width: 1240, height: 65), withAttributes: [.font: NSFont.systemFont(ofSize: 40, weight: .medium), .foregroundColor: NSColor(srgbRed: 0.80, green: 0.73, blue: 0.77, alpha: 1), .paragraphStyle: centered])

    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(directory.appendingPathComponent("Raw/\(sources[index]).png") as CFURL, nil)!, 0, nil)!
    let width: CGFloat = index == 3 ? 920 : 954
    let height = width * CGFloat(image.height) / CGFloat(image.width)
    let frame = CGRect(x: index == 3 ? 80 : (1320-width)/2, y: index == 3 ? 172 : 93, width: width, height: height)
    let outer = NSBezierPath(roundedRect: frame.insetBy(dx: -17, dy: -17), xRadius: 122, yRadius: 122)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
    shadow.shadowBlurRadius = 65
    shadow.shadowOffset = NSSize(width: 0, height: -25)
    shadow.set()
    NSColor.black.setFill()
    outer.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(srgbRed: 0.34, green: 0.29, blue: 0.32, alpha: 1).setStroke()
    outer.lineWidth = 3
    outer.stroke()
    cg.saveGState()
    NSBezierPath(roundedRect: frame, xRadius: 109, yRadius: 109).addClip()
    cg.draw(image, in: frame)
    cg.restoreGState()

    if index == 3 {
        let watch = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(directory.appendingPathComponent("Raw/watch.png") as CFURL, nil)!, 0, nil)!
        let rect = CGRect(x: 730, y: 1000, width: 480, height: 572)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(srgbRed: 0.12, green: 0.10, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 820, y: 805, width: 295, height: 960), xRadius: 70, yRadius: 70).fill()
        NSColor(srgbRed: 0.20, green: 0.18, blue: 0.20, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 1230, y: 1390, width: 26, height: 90), xRadius: 13, yRadius: 13).fill()
        let bezel = NSBezierPath(roundedRect: rect.insetBy(dx: -29, dy: -29), xRadius: 135, yRadius: 135)
        bezel.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 0.42, alpha: 1).setStroke()
        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: -26, dy: -26), xRadius: 133, yRadius: 133)
        edge.lineWidth = 3
        edge.stroke()
        cg.saveGState()
        NSBezierPath(roundedRect: rect, xRadius: 112, yRadius: 112).addClip()
        cg.draw(watch, in: rect)
        cg.restoreGState()
    }
    NSGraphicsContext.restoreGraphicsState()
    let result = cg.makeImage()!
    results.append(result)
    let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("0\(index+1)-\(sources[index]).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, result, nil)
    CGImageDestinationFinalize(destination)
}
let preview = CGContext(data: nil, width: 1320, height: 717, bitsPerComponent: 8, bytesPerRow: 5280, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
for (i, result) in results.enumerated() { preview.draw(result, in: CGRect(x: i*330, y: 0, width: 330, height: 717)) }
let destination = CGImageDestinationCreateWithURL(directory.appendingPathComponent("preview.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, preview.makeImage()!, nil)
CGImageDestinationFinalize(destination)
print("Rendered four 1320 × 2868 App Store screenshots and preview.png")
