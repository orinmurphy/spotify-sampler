// Renders the app icon: a dark squircle with a waveform, an amber "sliced" region and trim handles.
// Usage: swift Scripts/make_icon.swift <output.png>
import AppKit
import CoreGraphics

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [r, g, b, a])!
}

let amber = rgb(1.0, 0.66, 0.18)
let amberHot = rgb(1.0, 0.82, 0.38)

// Body: macOS icon grid (824pt squircle centred on 1024 canvas).
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.45))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0.08, 0.08, 0.09))
ctx.fillPath()
ctx.restoreGState()

// Background gradient
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [rgb(0.20, 0.19, 0.22), rgb(0.06, 0.06, 0.07)] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Warm glow behind the sliced region
let glow = CGGradient(colorsSpace: cs, colors: [rgb(1, 0.6, 0.15, 0.38), rgb(1, 0.6, 0.15, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 380, options: [])

// Waveform bars
let barCount = 23
let left: CGFloat = 178, right: CGFloat = 846
let pitch = (right - left) / CGFloat(barCount)
let barW = pitch * 0.58
let mid: CGFloat = 512
let sliceA = 7, sliceB = 15 // bars inside the selected region (inclusive)
let heights: [CGFloat] = [0.16, 0.26, 0.20, 0.38, 0.30, 0.48, 0.36, 0.62, 0.84, 0.70, 1.0, 0.78,
                          0.92, 0.66, 0.80, 0.56, 0.40, 0.50, 0.30, 0.36, 0.22, 0.26, 0.14]
let maxH: CGFloat = 520

for i in 0..<barCount {
    let h = max(maxH * heights[i], barW)
    let x = left + CGFloat(i) * pitch + (pitch - barW) / 2
    let r = CGRect(x: x, y: mid - h / 2, width: barW, height: h)
    let path = CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
    let inSlice = (sliceA...sliceB).contains(i)
    ctx.saveGState()
    if inSlice {
        ctx.setShadow(offset: .zero, blur: 22, color: rgb(1, 0.62, 0.15, 0.7))
        ctx.addPath(path)
        ctx.clip()
        let barGrad = CGGradient(colorsSpace: cs, colors: [amberHot, amber, rgb(0.95, 0.42, 0.10)] as CFArray,
                                 locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(barGrad, start: CGPoint(x: x, y: r.maxY), end: CGPoint(x: x, y: r.minY), options: [])
    } else {
        ctx.addPath(path)
        ctx.setFillColor(rgb(1, 1, 1, 0.22))
        ctx.fillPath()
    }
    ctx.restoreGState()
}

// Trim handles framing the slice
let hx0 = left + CGFloat(sliceA) * pitch - 4
let hx1 = left + CGFloat(sliceB + 1) * pitch + 4
let top: CGFloat = 512 + 300, bottom: CGFloat = 512 - 300
ctx.setFillColor(amber)
for (hx, dir) in [(hx0, CGFloat(1)), (hx1, CGFloat(-1))] {
    // vertical line
    ctx.fill(CGRect(x: hx - 5, y: bottom, width: 10, height: top - bottom))
    // flag tabs at top and bottom
    for y in [top - 34, bottom] {
        let tab = CGRect(x: dir > 0 ? hx - 5 : hx - 39, y: y, width: 44, height: 34)
        ctx.addPath(CGPath(roundedRect: tab, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
    }
}

// Subtle top sheen
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(1, 1, 1, 0.10), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
ctx.restoreGState()

// Hairline border
ctx.addPath(bodyPath)
ctx.setStrokeColor(rgb(1, 1, 1, 0.12))
ctx.setLineWidth(3)
ctx.strokePath()

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
