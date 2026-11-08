import AppKit

// Draws the app icon at 1024×1024: two sticky notes on a blue rounded square,
// the front one with a folded corner and a small checklist.
// Usage: swift Scripts/make_icon.swift out.png [full|back|front]
//   full  = complete icon (for .icns on older macOS)
//   back / front = a single note on a transparent canvas, as a layer for the macOS 26 .icon
let out = CommandLine.arguments[1]
let mode = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "full"
let S: CGFloat = 1024

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// A note shape with rounded corners and a folded bottom-right corner, centered on the origin.
func notePath(width w: CGFloat, height h: CGFloat, radius r: CGFloat, fold: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let x0 = -w / 2, y0 = -h / 2, x1 = w / 2, y1 = h / 2
    p.move(to: NSPoint(x: x0 + r, y: y0))
    p.line(to: NSPoint(x: x1 - fold, y: y0))
    p.line(to: NSPoint(x: x1, y: y0 + fold))
    p.line(to: NSPoint(x: x1, y: y1 - r))
    p.appendArc(withCenter: NSPoint(x: x1 - r, y: y1 - r), radius: r, startAngle: 0, endAngle: 90)
    p.line(to: NSPoint(x: x0 + r, y: y1))
    p.appendArc(withCenter: NSPoint(x: x0 + r, y: y1 - r), radius: r, startAngle: 90, endAngle: 180)
    p.line(to: NSPoint(x: x0, y: y0 + r))
    p.appendArc(withCenter: NSPoint(x: x0 + r, y: y0 + r), radius: r, startAngle: 180, endAngle: 270)
    p.close()
    return p
}

func withTransform(dx: CGFloat, dy: CGFloat, degrees: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: dx, yBy: dy)
    t.rotate(byDegrees: degrees)
    t.concat()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func shadow(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat) {
    guard mode == "full" else { return }   // in .icon layers the system draws the shadows
    let s = NSShadow()
    s.shadowBlurRadius = blur
    s.shadowOffset = NSSize(width: 0, height: dy)
    s.shadowColor = NSColor.black.withAlphaComponent(alpha)
    s.set()
}

let img = NSImage(size: NSSize(width: S, height: S), flipped: false) { _ in
    if mode != "full" {
        // .icon layers use the whole canvas as the rounded square: map the 824 px square onto 1024
        let t = NSAffineTransform()
        t.scale(by: S / 824)
        t.translateX(by: -100, yBy: -100)
        t.concat()
    }
    if mode == "full" {
    // Background: macOS icon grid (824 px rounded square, 100 px margin)
    let bgRect = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSGraphicsContext.saveGraphicsState()
    shadow(28, -12, 0.30)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
    rgb(0x3A7BD5).setFill()
    bg.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [rgb(0x6FD3FF), rgb(0x3F8CE8), rgb(0x3557C9)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: bg, angle: -90)
    // soft highlight in the top half
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    }

    // Back note: mint, tilted left
    if mode == "full" || mode == "back" {
    withTransform(dx: 470, dy: 540, degrees: 9) {
        let p = notePath(width: 470, height: 470, radius: 34, fold: 0)
        NSGraphicsContext.saveGraphicsState()
        shadow(30, -14, 0.28)
        rgb(0x9FE6C3).setFill(); p.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: rgb(0xB9F0D4), ending: rgb(0x86D9B0))!.draw(in: p, angle: -90)
    }

    }

    // Front note: yellow, tilted right, folded corner
    if mode == "full" || mode == "front" {
    withTransform(dx: 548, dy: 470, degrees: -5) {
        let w: CGFloat = 500, h: CGFloat = 500, fold: CGFloat = 112
        let p = notePath(width: w, height: h, radius: 36, fold: fold)
        NSGraphicsContext.saveGraphicsState()
        shadow(36, -18, 0.32)
        rgb(0xFFE16B).setFill(); p.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: rgb(0xFFEC8F), ending: rgb(0xFFD445))!.draw(in: p, angle: -90)

        // top strip
        NSGraphicsContext.saveGraphicsState()
        p.addClip()
        rgb(0xF5C431, 0.55).setFill()
        NSBezierPath(rect: NSRect(x: -w / 2, y: h / 2 - 70, width: w, height: 70)).fill()
        NSGraphicsContext.restoreGraphicsState()

        // folded corner
        let f = NSBezierPath()
        f.move(to: NSPoint(x: w / 2 - fold, y: -h / 2))
        f.line(to: NSPoint(x: w / 2 - fold + 10, y: -h / 2 + fold - 10))
        f.line(to: NSPoint(x: w / 2, y: -h / 2 + fold))
        f.close()
        NSGraphicsContext.saveGraphicsState()
        shadow(10, -4, 0.25)
        rgb(0xE9B520).setFill(); f.fill()
        NSGraphicsContext.restoreGraphicsState()

        // checklist: ticked item, empty item, text line
        let ink = rgb(0x5A4710, 0.75)
        let rows: [(CGFloat, Bool, CGFloat)] = [(95, true, 230), (-5, false, 260), (-105, false, 190)]
        for (i, row) in rows.enumerated() {
            let (y, checked, len) = row
            let x0: CGFloat = -w / 2 + 70
            if i < 2 {
                let box = NSBezierPath(roundedRect: NSRect(x: x0, y: y - 26, width: 52, height: 52), xRadius: 12, yRadius: 12)
                box.lineWidth = 9
                if checked { rgb(0x34C759).setFill(); box.fill() } else { ink.setStroke(); box.stroke() }
                if checked {
                    let tick = NSBezierPath()
                    tick.move(to: NSPoint(x: x0 + 12, y: y))
                    tick.line(to: NSPoint(x: x0 + 23, y: y - 12))
                    tick.line(to: NSPoint(x: x0 + 41, y: y + 13))
                    tick.lineWidth = 9; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
                    NSColor.white.setStroke(); tick.stroke()
                }
                ink.withAlphaComponent(checked ? 0.4 : 0.75).setFill()
                NSBezierPath(roundedRect: NSRect(x: x0 + 82, y: y - 13, width: len, height: 26), xRadius: 13, yRadius: 13).fill()
            } else {
                ink.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: NSRect(x: x0, y: y - 13, width: len + 82, height: 26), xRadius: 13, yRadius: 13).fill()
            }
        }
    }
    }
    return true
}

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
