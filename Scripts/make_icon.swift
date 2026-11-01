import AppKit
// Draws the icon: a yellow note with a folded corner and lines.
let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let r = NSRect(x: 120, y: 120, width: 784, height: 784)
    let fold: CGFloat = 190
    let shadow = NSShadow(); shadow.shadowBlurRadius = 40; shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.set()
    let p = NSBezierPath()
    p.move(to: NSPoint(x: r.minX + 40, y: r.minY)); p.line(to: NSPoint(x: r.maxX - fold, y: r.minY))
    p.line(to: NSPoint(x: r.maxX, y: r.minY + fold)); p.line(to: NSPoint(x: r.maxX, y: r.maxY - 40))
    p.appendArc(withCenter: NSPoint(x: r.maxX - 40, y: r.maxY - 40), radius: 40, startAngle: 0, endAngle: 90)
    p.line(to: NSPoint(x: r.minX + 40, y: r.maxY))
    p.appendArc(withCenter: NSPoint(x: r.minX + 40, y: r.maxY - 40), radius: 40, startAngle: 90, endAngle: 180)
    p.line(to: NSPoint(x: r.minX, y: r.minY + 40))
    p.appendArc(withCenter: NSPoint(x: r.minX + 40, y: r.minY + 40), radius: 40, startAngle: 180, endAngle: 270)
    p.close()
    NSGradient(starting: NSColor(srgbRed: 1, green: 0.93, blue: 0.55, alpha: 1), ending: NSColor(srgbRed: 1, green: 0.84, blue: 0.3, alpha: 1))!.draw(in: p, angle: -90)
    NSShadow().set()
    NSColor(srgbRed: 0.93, green: 0.74, blue: 0.2, alpha: 1).setFill()
    let f = NSBezierPath(); f.move(to: NSPoint(x: r.maxX - fold, y: r.minY)); f.line(to: NSPoint(x: r.maxX - fold, y: r.minY + fold)); f.line(to: NSPoint(x: r.maxX, y: r.minY + fold)); f.close(); f.fill()
    NSColor(srgbRed: 0.98, green: 0.82, blue: 0.3, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: r.minX, y: r.maxY - 110, width: r.width, height: 70)).fill()
    NSColor(srgbRed: 0.35, green: 0.28, blue: 0.1, alpha: 0.55).setFill()
    for (i, w) in [520.0, 440, 560, 300].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: r.minX + 90, y: r.maxY - 230 - CGFloat(i) * 120, width: CGFloat(w), height: 34), xRadius: 17, yRadius: 17).fill()
    }
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
