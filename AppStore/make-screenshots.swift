import AppKit

// App Store screenshots that tell DualShot's story: a headline with one highlighted word,
// a short supporting line, the app in a phone frame, and callout badges.
// Usage: swift story.swift <raw screens dir> <out dir> <width> <height>

let args = CommandLine.arguments
let rawDir = args[1], outDir = args[2]
let W = CGFloat(Double(args[3])!), H = CGFloat(Double(args[4])!)
let s = W / 1206   // everything is laid out for 1206 wide, then scaled

struct Badge { let symbol: String; let text: String; let tint: NSColor }
struct Slide {
    let screen: String
    let before: String, highlight: String, after: String   // headline: before + highlight + after
    let sub: String
    let top: [Badge]       // a row of badges above the phone
    let side: [Badge]      // badges floating over the phone
    /// Where the first side badge sits, as a fraction of the phone's height from its bottom;
    /// higher on slides whose screen has a sheet at the bottom.
    var sideAt: CGFloat = 0.42
}

let orange = NSColor(srgbRed: 1.0, green: 0.68, blue: 0.27, alpha: 1)
let blue = NSColor(srgbRed: 0.48, green: 0.58, blue: 1.0, alpha: 1)
let green = NSColor(srgbRed: 0.30, green: 0.85, blue: 0.50, alpha: 1)
let white = NSColor.white

let slides: [Slide] = [
    Slide(screen: "recording", before: "Film the moment\n", highlight: "and", after: " your reaction.",
          sub: "Front and back cameras record at the same time.",
          top: [Badge(symbol: "checkmark.seal.fill", text: "Works on iPhone XS and newer", tint: green)],
          side: [Badge(symbol: "camera.fill", text: "Back camera", tint: orange),
                 Badge(symbol: "person.crop.square.fill", text: "Front camera", tint: blue)]),
    Slide(screen: "pip", before: "No new iPhone\n", highlight: "needed.", after: "",
          sub: "Dual-camera video on the iPhone you already own.",
          top: [Badge(symbol: "iphone", text: "XS · XR · 11 · 12 · 13 · 14 · 15 · 16", tint: white)],
          side: [Badge(symbol: "dollarsign.circle.fill", text: "Skip the upgrade", tint: green)]),
    Slide(screen: "files", before: "Two cameras.\n", highlight: "Three", after: " files.",
          sub: "Back, front and combined, saved separately and ready to edit.",
          top: [],
          side: [Badge(symbol: "film.fill", text: "Back.mov", tint: orange),
                 Badge(symbol: "film.fill", text: "Front.mov", tint: blue),
                 Badge(symbol: "rectangle.on.rectangle", text: "Combined.mov", tint: white)], sideAt: 0.70),
    Slide(screen: "split", before: "Picture in picture\n", highlight: "or", after: " split screen.",
          sub: "Drag the window anywhere. Your video follows.",
          top: [], side: [Badge(symbol: "hand.draw.fill", text: "Drag to any corner", tint: white)]),
    Slide(screen: "photo", before: "Both cameras.\n", highlight: "One", after: " tap.",
          sub: "Photos of the view and you, taken at the same moment.",
          top: [], side: [Badge(symbol: "camera.aperture", text: "HEIF or JPEG", tint: white),
                          Badge(symbol: "timer", text: "Self-timer", tint: orange)]),
    Slide(screen: "heat", before: "Records longer.\n", highlight: "Stays cool.", after: "",
          sub: "Heat-Up Settings keep long takes going.",
          top: [], side: [Badge(symbol: "thermometer.medium", text: "Smart heat control", tint: orange)], sideAt: 0.62),
    Slide(screen: "format", before: "Up to ", highlight: "4K,", after: "\ntuned to your iPhone.",
          sub: "DualShot offers only what your iPhone can really record.",
          top: [], side: [Badge(symbol: "sparkles", text: "Measured on first launch", tint: white)], sideAt: 0.62),
]

func roundRect(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }

/// A frosted capsule with an SF Symbol and a label. Returns its size; draws when `at` is given.
@discardableResult
func badge(_ b: Badge, at origin: NSPoint?) -> NSSize {
    let font = NSFont.systemFont(ofSize: 40 * s, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let textSize = (b.text as NSString).size(withAttributes: attrs)
    let iconSize = 44 * s, padX = 30 * s, gap = 16 * s, h = 92 * s
    let size = NSSize(width: padX * 2 + iconSize + gap + textSize.width, height: h)
    guard let o = origin else { return size }
    let rect = NSRect(origin: o, size: size)
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 30 * s; sh.shadowOffset = NSSize(width: 0, height: -8 * s); sh.set()
    NSColor(srgbRed: 0.10, green: 0.11, blue: 0.20, alpha: 0.88).setFill(); roundRect(rect, h / 2).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.18).setStroke(); let border = roundRect(rect.insetBy(dx: 1.5 * s, dy: 1.5 * s), h / 2); border.lineWidth = 3 * s; border.stroke()
    // Symbols are drawn as a mask, then filled with the badge's colour.
    let config = NSImage.SymbolConfiguration(pointSize: iconSize * 0.85, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: b.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let isz = symbol.size
        let scale = min(iconSize / isz.width, iconSize / isz.height)
        let iw = isz.width * scale, ih = isz.height * scale
        let tinted = NSImage(size: NSSize(width: iw, height: ih), flipped: false) { r in
            symbol.draw(in: r)
            b.tint.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: o.x + padX + (iconSize - iw) / 2, y: o.y + (h - ih) / 2, width: iw, height: ih))
    }
    (b.text as NSString).draw(at: NSPoint(x: o.x + padX + iconSize + gap, y: o.y + (h - textSize.height) / 2), withAttributes: attrs)
    return size
}

for (i, slide) in slides.enumerated() {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let canvas = NSRect(x: 0, y: 0, width: W, height: H)

    // Night-sky background in the icon's colours, with warm and cool glows.
    NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.18, blue: 0.40, alpha: 1),
                        NSColor(srgbRed: 0.06, green: 0.07, blue: 0.16, alpha: 1)])!.draw(in: canvas, angle: -90)
    let warm = NSGradient(colors: [orange.withAlphaComponent(0.45), orange.withAlphaComponent(0)])!
    warm.draw(fromCenter: NSPoint(x: W * 0.92, y: H * 0.80), radius: 0, toCenter: NSPoint(x: W * 0.92, y: H * 0.80), radius: 700 * s, options: [])
    let cool = NSGradient(colors: [blue.withAlphaComponent(0.40), blue.withAlphaComponent(0)])!
    cool.draw(fromCenter: NSPoint(x: W * 0.05, y: H * 0.25), radius: 0, toCenter: NSPoint(x: W * 0.05, y: H * 0.25), radius: 760 * s, options: [])

    // Headline with one highlighted word.
    let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineSpacing = -6 * s
    let hFont = NSFont.systemFont(ofSize: 108 * s, weight: .heavy)
    let headline = NSMutableAttributedString(string: slide.before, attributes: [.font: hFont, .foregroundColor: NSColor.white, .paragraphStyle: p, .kern: -2.5 * s])
    headline.append(NSAttributedString(string: slide.highlight, attributes: [.font: hFont, .foregroundColor: orange, .paragraphStyle: p, .kern: -2.5 * s]))
    headline.append(NSAttributedString(string: slide.after, attributes: [.font: hFont, .foregroundColor: NSColor.white, .paragraphStyle: p, .kern: -2.5 * s]))
    let topMargin = 150 * s * (H / W) / (2622.0 / 1206.0)
    let hRect = NSRect(x: 50 * s, y: H - topMargin - 270 * s, width: W - 100 * s, height: 270 * s)
    headline.draw(with: hRect, options: [.usesLineFragmentOrigin])
    let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 46 * s, weight: .medium),
                                                   .foregroundColor: NSColor.white.withAlphaComponent(0.75), .paragraphStyle: p]
    let subRect = NSRect(x: 90 * s, y: hRect.minY - 140 * s, width: W - 180 * s, height: 130 * s)
    (slide.sub as NSString).draw(with: subRect, options: [.usesLineFragmentOrigin], attributes: subAttrs)

    // Badges above the phone.
    var phoneTop = subRect.minY - 40 * s
    if !slide.top.isEmpty {
        let sizes = slide.top.map { badge($0, at: nil) }
        let total = sizes.reduce(0) { $0 + $1.width } + CGFloat(sizes.count - 1) * 20 * s
        var x = (W - total) / 2
        let y = phoneTop - sizes[0].height
        for (b, sz) in zip(slide.top, sizes) { badge(b, at: NSPoint(x: x, y: y)); x += sz.width + 20 * s }
        phoneTop = y - 40 * s
    }

    // The phone: a dark bezel around the app screen, running off the bottom edge.
    let screen = NSImage(contentsOfFile: "\(rawDir)/\(slide.screen).png")!
    let bezel = 26 * s
    let screenW = 900 * s, screenH = screenW * 2622 / 1206
    let phone = NSRect(x: (W - screenW) / 2 - bezel, y: phoneTop - screenH - bezel * 2, width: screenW + bezel * 2, height: screenH + bezel * 2)
    let corner = 150 * s
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.55); shadow.shadowBlurRadius = 90 * s; shadow.shadowOffset = NSSize(width: 0, height: -30 * s); shadow.set()
    NSColor(srgbRed: 0.07, green: 0.07, blue: 0.09, alpha: 1).setFill(); roundRect(phone, corner).fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0.45, alpha: 1).setStroke(); let rim = roundRect(phone.insetBy(dx: 3 * s, dy: 3 * s), corner - 3 * s); rim.lineWidth = 5 * s; rim.stroke()
    let screenRect = phone.insetBy(dx: bezel, dy: bezel)
    NSGraphicsContext.saveGraphicsState(); roundRect(screenRect, corner - bezel).addClip(); screen.draw(in: screenRect); NSGraphicsContext.restoreGraphicsState()
    // Dynamic Island.
    let island = NSRect(x: W / 2 - 110 * s, y: screenRect.maxY - 30 * s - 64 * s, width: 220 * s, height: 64 * s)
    NSColor.black.setFill(); roundRect(island, 32 * s).fill()

    // Badges over the lower half of the phone, alternating sides like annotations.
    let sizes = slide.side.map { badge($0, at: nil) }
    var y = phone.minY + phone.height * slide.sideAt
    for (j, (b, sz)) in zip(slide.side, sizes).enumerated() {
        let x = j % 2 == 0 ? max(40 * s, phone.minX - 60 * s) : min(W - sz.width - 40 * s, phone.maxX - sz.width + 60 * s)
        badge(b, at: NSPoint(x: x, y: y))
        y -= sz.height + 34 * s
    }

    NSGraphicsContext.restoreGraphicsState()
    // JPEG has no alpha channel, so the (fully opaque) canvas is saved flat, as App Store Connect requires.
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95])!
        .write(to: URL(fileURLWithPath: "\(outDir)/\(i + 1)-\(slide.screen).jpg"))
}
print("done")
