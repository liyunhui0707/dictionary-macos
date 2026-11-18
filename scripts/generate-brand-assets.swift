// Original vector artwork for Wordlit. Local rendering only; no fonts or network downloads.
// Run: xcrun swift scripts/generate-brand-assets.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let fm = FileManager.default
func directory(_ path: String) throws -> URL {
    let url = root.appendingPathComponent(path, isDirectory: true)
    try fm.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
let brand = try directory("branding")
let preview = try directory("build/branding.noindex")
let iconset = try directory("build/branding.noindex/Wordlit.iconset")
func color(_ hex: UInt32) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
func mark(_ c: CGContext, x: CGFloat, y: CGFloat, size: CGFloat) {
    c.saveGState(); defer { c.restoreGState() }
    c.translateBy(x: x, y: y); c.scaleBy(x: size / 100, y: size / 100)
    let tile = CGPath(roundedRect: CGRect(x: 6, y: 6, width: 88, height: 88), cornerWidth: 21, cornerHeight: 21, transform: nil)
    c.saveGState(); c.addPath(tile); c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x386751), color(0x254C3B)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 6, y: 6), end: CGPoint(x: 94, y: 94), options: [])
    c.restoreGState()
    let w = CGMutablePath(); w.move(to: CGPoint(x: 25, y: 33))
    for point in [CGPoint(x: 36, y: 69), CGPoint(x: 50, y: 45), CGPoint(x: 64, y: 69), CGPoint(x: 75, y: 33)] { w.addLine(to: point) }
    c.addPath(w); c.setStrokeColor(color(0xFCFCF4)); c.setLineWidth(7); c.setLineCap(.round); c.setLineJoin(.round); c.strokePath()
    let light = CGMutablePath(); light.move(to: CGPoint(x: 77, y: 15))
    for point in [CGPoint(x: 79, y: 21), CGPoint(x: 85, y: 23), CGPoint(x: 79, y: 25), CGPoint(x: 77, y: 31), CGPoint(x: 75, y: 25), CGPoint(x: 69, y: 23), CGPoint(x: 75, y: 21)] { light.addLine(to: point) }
    light.closeSubpath(); c.addPath(light); c.setFillColor(color(0xEBCB86)); c.fillPath()
}
func png(width: Int, height: Int, draw: (CGContext) -> Void) -> Data {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
    draw(c)
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, c.makeImage()!, nil)
    precondition(CGImageDestinationFinalize(destination)); return output as Data
}
func icon(_ size: Int) -> Data { png(width: size, height: size) { mark($0, x: 0, y: 0, size: CGFloat(size)) } }
for size in [16, 32, 128, 256, 512] {
    try icon(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
for size in [16, 48, 128] { try icon(size).write(to: root.appendingPathComponent("extensions/chromium/icons/\(size).png")) }
try icon(32).write(to: root.appendingPathComponent("website/dist/favicon-32.png"))
try icon(1024).write(to: brand.appendingPathComponent("wordlit-icon.png"))
// ICO embeds lossless PNG images, preserving the exact same small-size artwork.
var ico = Data()
func u16(_ n: Int) { ico.append(UInt8(n & 255)); ico.append(UInt8((n >> 8) & 255)) }
func u32(_ n: Int) { for shift in stride(from: 0, to: 32, by: 8) { ico.append(UInt8((n >> shift) & 255)) } }
let faviconImages = [16, 32, 64].map { ($0, icon($0)) }
u16(0); u16(1); u16(faviconImages.count)
var offset = 6 + 16 * faviconImages.count
for (size, data) in faviconImages {
    ico.append(contentsOf: [UInt8(size), UInt8(size), 0, 0]); u16(1); u16(32); u32(data.count); u32(offset); offset += data.count
}
for (_, data) in faviconImages { ico.append(data) }
try ico.write(to: root.appendingPathComponent("website/dist/favicon.ico"))
let markBody = """
<defs><linearGradient id="green" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#386751"/><stop offset="1" stop-color="#254C3B"/></linearGradient></defs>
<rect x="6" y="6" width="88" height="88" rx="21" fill="url(#green)"/>
<path d="M25 33 36 69 50 45 64 69 75 33" fill="none" stroke="#FCFCF4" stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>
<path d="m77 15 2 6 6 2-6 2-2 6-2-6-6-2 6-2z" fill="#EBCB86"/>
"""
let svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\" role=\"img\" aria-label=\"Wordlit\">\(markBody)</svg>\n"
try svg.write(to: brand.appendingPathComponent("wordlit-mark.svg"), atomically: true, encoding: .utf8)
try svg.write(to: root.appendingPathComponent("website/dist/wordlit-mark.svg"), atomically: true, encoding: .utf8)
let wordmark = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 440 100\" role=\"img\" aria-label=\"Wordlit\">\(markBody)<text x=\"120\" y=\"70\" fill=\"#252D2B\" font-family=\"Georgia,serif\" font-size=\"67\" letter-spacing=\"-2\">Wordlit</text></svg>\n"
try wordmark.write(to: brand.appendingPathComponent("wordlit-wordmark.svg"), atomically: true, encoding: .utf8)
func text(_ c: CGContext, _ value: String, x: CGFloat, y: CGFloat, size: CGFloat, ink: UInt32 = 0x252D2B, serif: Bool = false) {
    c.saveGState(); defer { c.restoreGState() }
    c.translateBy(x: x, y: y); c.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    let font = serif ? NSFont(name: "Georgia", size: size)! : NSFont.systemFont(ofSize: size)
    (value as NSString).draw(at: NSPoint(x: 0, y: -size), withAttributes: [.font: font, .foregroundColor: NSColor(cgColor: color(ink))!])
    NSGraphicsContext.restoreGraphicsState()
}
let board = png(width: 1440, height: 900) { c in
    c.setFillColor(color(0xF5F5EF)); c.fill(CGRect(x: 0, y: 0, width: 1440, height: 900))
    text(c, "WORDLIT  /  BRAND IDENTITY", x: 80, y: 64, size: 17, ink: 0x66716C)
    mark(c, x: 70, y: 160, size: 260)
    text(c, "Wordlit", x: 370, y: 195, size: 118, serif: true)
    text(c, "A little light on every word.", x: 378, y: 355, size: 28, ink: 0x66716C)
    c.setFillColor(color(0x242C28)); c.fill(CGRect(x: 80, y: 510, width: 1280, height: 310))
    mark(c, x: 120, y: 560, size: 180)
    text(c, "Wordlit", x: 330, y: 582, size: 76, ink: 0xEDF1E9, serif: true)
    text(c, "Understand in context. Keep reading.", x: 335, y: 690, size: 23, ink: 0xA9B6AB)
    for (index, size) in [64, 32, 16].enumerated() { mark(c, x: 1060 + CGFloat(index) * 90, y: 625, size: CGFloat(size)) }
}
try board.write(to: preview.appendingPathComponent("wordlit-brand-preview.png"))
let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Sources/DictionaryApp/Resources/AppIcon.icns").path]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else {
    throw NSError(domain: "WordlitBrandAssets", code: Int(task.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "iconutil failed; generated artwork is retained for inspection."])
}
print("Generated Wordlit vector marks, app/extension icons, favicons and local brand preview.")
