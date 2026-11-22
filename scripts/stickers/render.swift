// Renders placeholder quest stickers (one per category) for the demo account seed.
//   swift scripts/stickers/render.swift supabase/seed/stickers
// Transparent 512x512 PNG: the category emoji with a soft white "die-cut" halo.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let stickers = ["bench": "🪑", "lamppost": "🏮", "tree": "🌳", "fire_hydrant": "🚒",
                "mural": "🎨", "statue": "🗽", "mailbox": "📮"]
let size = 512

for (name, emoji) in stickers {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let font = NSFont.systemFont(ofSize: 330)
    let text = NSAttributedString(string: emoji, attributes: [.font: font])
    let bounds = text.size()
    let origin = NSPoint(x: (CGFloat(size) - bounds.width) / 2, y: (CGFloat(size) - bounds.height) / 2)
    // White halo: the glyph drawn several times with a white shadow, then once on top.
    let halo = NSShadow()
    halo.shadowColor = .white
    halo.shadowBlurRadius = 14
    halo.shadowOffset = .zero
    halo.set()
    for _ in 0..<6 { text.draw(at: origin) }
    NSShadow().set()
    text.draw(at: origin)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(name).png"))
    print("wrote \(name).png")
}
