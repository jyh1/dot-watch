import AppKit
import Foundation
// Original, reproducible artwork: a cyan dot containing an audio waveform.
let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Branding/Default", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (name, pixels, opaque) in [("AppIcon", 1024, true), ("Avatar", 512, false)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let size = CGFloat(pixels)
    let navy = NSColor(srgbRed: 0.035, green: 0.075, blue: 0.11, alpha: 1)
    (opaque ? navy : .clear).setFill()
    NSRect(x: 0,y: 0,width: size,height: size).fill()
    NSColor(srgbRed: 0.27,green: 0.84,blue: 0.91,alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: size*0.19,y: size*0.19,width: size*0.62,height: size*0.62)).fill()
    navy.setStroke()
    for (i,height) in [0.10,0.22,0.34,0.22,0.10].enumerated() {
        let line=NSBezierPath(); line.lineWidth=size*0.034; line.lineCapStyle = .round
        let x=size*(0.34+CGFloat(i)*0.08)
        line.move(to: NSPoint(x:x,y:size*(0.5-height/2)))
        line.line(to: NSPoint(x:x,y:size*(0.5+height/2)))
        line.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name+".png"))
}
