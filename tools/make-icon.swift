// Erzeugt das App-Symbol (Haus mit Sendewellen) für iOS als 1024er-PNG:
//   swift tools/make-icon.swift Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)
    func rgb(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat(h >> 16 & 255) / 255, green: CGFloat(h >> 8 & 255) / 255, blue: CGFloat(h & 255) / 255, alpha: a)
    }
    // iOS-Symbol: volle Fläche (iOS rundet selbst ab), Verlauf Koralle → Violett
    let bg = CGGradient(colorsSpace: nil, colors: [rgb(0xFF7A59), rgb(0xD9469C), rgb(0x6B2FD6)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])
    // Haus
    let house = CGMutablePath()
    house.move(to: CGPoint(x: 512, y: 830))
    house.addLine(to: CGPoint(x: 845, y: 545))
    house.addLine(to: CGPoint(x: 770, y: 545))
    house.addLine(to: CGPoint(x: 770, y: 200))
    house.addLine(to: CGPoint(x: 254, y: 200))
    house.addLine(to: CGPoint(x: 254, y: 545))
    house.addLine(to: CGPoint(x: 179, y: 545))
    house.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0x2A0B4F, 0.35))
    ctx.addPath(house); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()
    // Sendewellen im Haus
    let c = CGPoint(x: 512, y: 410)
    ctx.setStrokeColor(rgb(0x8A35C9)); ctx.setLineCap(.round)
    for (r, w) in [(150.0, 34.0), (95.0, 34.0)] {
        ctx.setLineWidth(w)
        ctx.addArc(center: c, radius: r, startAngle: -.pi * 0.25, endAngle: .pi * 0.25, clockwise: false); ctx.strokePath()
        ctx.addArc(center: c, radius: r, startAngle: .pi * 0.75, endAngle: .pi * 1.25, clockwise: false); ctx.strokePath()
    }
    ctx.setFillColor(rgb(0x8A35C9))
    ctx.fillEllipse(in: CGRect(x: c.x - 44, y: c.y - 44, width: 88, height: 88))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try! render(1024).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon-1024.png"))
let json = """
{
  "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! json.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Symbol geschrieben nach \(out.path)")
