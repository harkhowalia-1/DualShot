import AppKit

// App Store screenshots in the style of Apple's own iPhone campaigns: white background,
// a short headline and supporting line, and the app running in a lavender iPhone.
// Usage: swift make-screenshots.swift <app screens dir> <out dir> <width> <height>
// App screens come from the Simulator in demo mode (see README "Screenshots").

let args = CommandLine.arguments
let screensDir = args[1], outDir = args[2]
let W = CGFloat(Double(args[3])!), H = CGFloat(Double(args[4])!)
let s = W / 1206   // laid out for 1206 × 2622, scaled for other sizes

struct Slide { let screen: String; let headline: String; let sub: String }

let slides: [Slide] = [
    Slide(screen: "1-mountain", headline: "Record yourself\nand the world around you.",
          sub: "Front and back video, captured at the same time."),
    Slide(screen: "2-concert", headline: "Works on the iPhone\nyou already have.",
          sub: "Dual-camera video on iPhone XS and later. No upgrade needed."),
    Slide(screen: "3-tokyo", headline: "Two cameras.\nTwo separate files.",
          sub: "The back and front save as their own videos, plus one combined, ready to edit."),
    Slide(screen: "4-beach", headline: "Picture in picture.\nOr split screen.",
          sub: "Move the window anywhere. Your video keeps the layout."),
    Slide(screen: "5-birthday", headline: "Both sides\nof every moment.",
          sub: "Take photos with the front and back cameras at once."),
    Slide(screen: "6-festival", headline: "Made for\nlong takes.",
          sub: "Heat-Up Settings lower the frame rate before your iPhone gets too warm."),
]

func rr(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }
func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// The iPhone mockup from AppStore/mockup.png, if present: its white screen area is cut out
/// (flood-filled from the centre), so the app shows through while the frame, corners and
/// Dynamic Island stay exactly as drawn.
struct Mockup { let frame: NSImage; let screen: NSRect; let size: NSSize }
let mockup: Mockup? = {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("mockup.png").path
    guard let data = FileManager.default.contents(atPath: path), let src = NSBitmapImageRep(data: data) else { return nil }
    let w = src.pixelsWide, h = src.pixelsHigh
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    src.draw(in: NSRect(x: 0, y: 0, width: w, height: h)); NSGraphicsContext.restoreGraphicsState()
    let px = rep.bitmapData!
    func white(_ i: Int) -> Bool { px[i] > 225 && px[i + 1] > 225 && px[i + 2] > 225 && px[i + 3] > 200 }
    var stack = [(w / 2, h / 2)], seen = [Bool](repeating: false, count: w * h)
    var minX = w, maxX = 0, minY = h, maxY = 0
    while let (x, y) = stack.popLast() {
        guard x >= 0, y >= 0, x < w, y < h, !seen[y * w + x] else { continue }
        seen[y * w + x] = true
        let i = (y * w + x) * 4
        guard white(i) else { continue }
        px[i + 3] = 0; px[i] = 0; px[i + 1] = 0; px[i + 2] = 0
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    }
    let image = NSImage(size: NSSize(width: w, height: h)); image.addRepresentation(rep)
    // Bitmap rows run top-down; drawing coordinates run bottom-up.
    return Mockup(frame: image, screen: NSRect(x: minX, y: h - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1),
                  size: NSSize(width: w, height: h))
}()

/// The mockup with `screen` showing through its cut-out, filling it like a photo (aspect fill).
func drawMockup(_ m: Mockup, _ screen: NSImage, width: CGFloat, top: CGFloat) {
    let k = width / m.size.width
    let frame = NSRect(x: (W - width) / 2, y: top - m.size.height * k, width: width, height: m.size.height * k)
    let hole = NSRect(x: frame.minX + m.screen.minX * k, y: frame.minY + m.screen.minY * k, width: m.screen.width * k, height: m.screen.height * k)
    let fill = max(hole.width / screen.size.width, hole.height / screen.size.height)
    let drawn = NSRect(x: hole.midX - screen.size.width * fill / 2, y: hole.midY - screen.size.height * fill / 2,
                       width: screen.size.width * fill, height: screen.size.height * fill)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.14); shadow.shadowBlurRadius = 70 * s; shadow.shadowOffset = NSSize(width: 0, height: -30 * s); shadow.set()
    m.frame.draw(in: frame)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: hole).addClip(); screen.draw(in: drawn); NSGraphicsContext.restoreGraphicsState()
    m.frame.draw(in: frame)
}

/// A lavender iPhone with a black bezel and Dynamic Island, with `screen` inside.
func drawPhone(_ screen: NSImage, screenWidth: CGFloat, top: CGFloat) {
    let sw = screenWidth, sh = sw * 2622 / 1206
    let bezel = sw * 0.032, rim = sw * 0.016
    let outer = NSRect(x: (W - sw) / 2 - bezel - rim, y: top - sh - 2 * (bezel + rim),
                       width: sw + 2 * (bezel + rim), height: sh + 2 * (bezel + rim))
    let outerR = outer.width * 0.165

    // Side buttons, behind the frame.
    let lavender = NSGradient(colors: [color(0xE6DFF2), color(0xCBC0E0), color(0xE9E4F4)])!
    let bw = rim * 1.4
    for (y, h) in [(0.80, 0.045), (0.71, 0.075), (0.62, 0.075)] {
        let r = NSRect(x: outer.minX - bw * 0.6, y: outer.minY + outer.height * CGFloat(y) - outer.height * CGFloat(h), width: bw * 2, height: outer.height * CGFloat(h))
        lavender.draw(in: rr(r, bw), angle: 0)
    }
    let power = NSRect(x: outer.maxX - bw * 1.4, y: outer.minY + outer.height * 0.60, width: bw * 2, height: outer.height * 0.11)
    lavender.draw(in: rr(power, bw), angle: 180)

    // Soft shadow, then the lavender aluminium rim.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.16); shadow.shadowBlurRadius = 70 * s; shadow.shadowOffset = NSSize(width: 0, height: -30 * s); shadow.set()
    color(0xD6CEE8).setFill(); rr(outer, outerR).fill()
    NSGraphicsContext.restoreGraphicsState()
    lavender.draw(in: rr(outer, outerR), angle: -35)
    color(0xB4A8CC).setStroke(); let edge = rr(outer.insetBy(dx: 1 * s, dy: 1 * s), outerR); edge.lineWidth = 2 * s; edge.stroke()

    // Black bezel and the screen.
    let bezelRect = outer.insetBy(dx: rim, dy: rim)
    NSColor.black.setFill(); rr(bezelRect, outerR - rim).fill()
    let screenRect = bezelRect.insetBy(dx: bezel, dy: bezel)
    NSGraphicsContext.saveGraphicsState(); rr(screenRect, outerR - rim - bezel).addClip(); screen.draw(in: screenRect); NSGraphicsContext.restoreGraphicsState()

    // Dynamic Island, with the green camera-in-use dot and the front lens.
    let iw = sw * 0.30, ih = sw * 0.088
    let island = NSRect(x: W / 2 - iw / 2, y: screenRect.maxY - sw * 0.035 - ih, width: iw, height: ih)
    NSColor.black.setFill(); rr(island, ih / 2).fill()
    let dot = ih * 0.20
    color(0x34C759).setFill(); NSBezierPath(ovalIn: NSRect(x: island.maxX - ih * 1.45, y: island.midY - dot / 2, width: dot, height: dot)).fill()
    let lens = ih * 0.34
    color(0x1B1E3A).setFill(); NSBezierPath(ovalIn: NSRect(x: island.maxX - ih * 0.78, y: island.midY - lens / 2, width: lens, height: lens)).fill()
    color(0x3A4380).setFill(); NSBezierPath(ovalIn: NSRect(x: island.maxX - ih * 0.78 + lens * 0.3, y: island.midY - lens * 0.2, width: lens * 0.4, height: lens * 0.4)).fill()
}

for (i, slide) in slides.enumerated() {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()

    let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineHeightMultiple = 0.95
    let headAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 92 * s, weight: .bold),
                                                    .foregroundColor: color(0x1D1D1F), .paragraphStyle: p, .kern: -1.6 * s]
    let top = H - 150 * s * (H / W) / (2622.0 / 1206.0)
    let headRect = NSRect(x: 40 * s, y: top - 240 * s, width: W - 80 * s, height: 240 * s)
    (slide.headline as NSString).draw(with: headRect, options: [.usesLineFragmentOrigin], attributes: headAttrs)
    let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44 * s, weight: .regular),
                                                   .foregroundColor: color(0x6E6E73), .paragraphStyle: p]
    let subRect = NSRect(x: 110 * s, y: headRect.minY - 140 * s, width: W - 220 * s, height: 130 * s)
    (slide.sub as NSString).draw(with: subRect, options: [.usesLineFragmentOrigin], attributes: subAttrs)

    let screen = NSImage(contentsOfFile: "\(screensDir)/\(slide.screen).png")!
    let available = subRect.minY - 70 * s - 110 * s
    let screenWidth = min(860 * s, available / (2622.0 / 1206.0 + 0.1))
    if let m = mockup {
        let height = subRect.minY - 60 * s - 90 * s
        drawMockup(m, screen, width: min(1000 * s, height * m.size.width / m.size.height), top: subRect.minY - 60 * s)
    } else {
        drawPhone(screen, screenWidth: screenWidth, top: subRect.minY - 60 * s)
    }

    NSGraphicsContext.restoreGraphicsState()
    // JPEG has no alpha channel, so the opaque canvas is saved flat, as App Store Connect requires.
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.94])!
        .write(to: URL(fileURLWithPath: "\(outDir)/\(slide.screen).jpg"))
}
print("done")
