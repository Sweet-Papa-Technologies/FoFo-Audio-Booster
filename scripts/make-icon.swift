import AppKit
import Foundation
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let p = CGFloat(pixels)
        let rect = NSRect(x: p*0.06, y: p*0.06, width: p*0.88, height: p*0.88)
        let path = NSBezierPath(roundedRect: rect, xRadius: p*0.2, yRadius: p*0.2)
        NSColor(calibratedRed: 0.09, green: 0.105, blue: 0.125, alpha: 1).setFill(); path.fill()
        let lengths: [CGFloat] = [0.16,0.34,0.57,0.39,0.2]
        for (i, length) in lengths.enumerated() {
            let x = p*(0.27+CGFloat(i)*0.115), h=p*length
            let bar=NSBezierPath(roundedRect: NSRect(x: x-p*0.028,y: (p-h)*0.5,width: p*0.056,height: h),xRadius: p*0.028,yRadius: p*0.028)
            NSColor(calibratedRed: 1, green: 0.48+Double(i)*0.04, blue: 0.25, alpha: 1).setFill();bar.fill()
        }
        image.unlockFocus()
        guard let tiff=image.tiffRepresentation, let bitmap=NSBitmapImageRep(data:tiff), let png=bitmap.representation(using:.png,properties:[:]) else { fatalError("Icon rendering failed") }
        try png.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
