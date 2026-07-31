#!/usr/bin/env swift
//
// StarFind 应用图标生成器。
//
//   swift tools/make-icon.swift
//
// 每个尺寸单独按矢量渲染（不是渲染 1024 再缩），这样 16px 那档也不会糊成一团。
// 生成 Resources/AppIcon.iconset/ 然后交给 iconutil 打包成 .icns。
//
// 设计：方胜形 + 对角渐变 + 四角星，配色为青蓝，
// 主体图形是放大镜，镜片里嵌一颗星。
// 放大镜的环和柄都画得很粗，缩到 16px 仍然认得出是「搜索」。

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 形状

/// 方胜形（超椭圆）。Apple 的圆角是连续曲率，n≈5 的超椭圆比 roundedRect 像得多。
func squirclePath(in rect: CGRect, n: Double = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = Double(rect.width / 2), b = Double(rect.height / 2)
    let cx = Double(rect.midX), cy = Double(rect.midY)
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2.0 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2.0 / n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// 四角星。waist 越小尖角越锐利。
func sparklePath(center c: CGPoint, radius r: CGFloat, waist: CGFloat = 0.165) -> CGPath {
    let w = r * waist
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y - r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + w, y: c.y - w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - w, y: c.y + w))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - w, y: c.y - w))
    p.closeSubpath()
    return p
}

// MARK: - 绘制

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func drawIcon(size S: CGFloat, into ctx: CGContext) {
    let space = CGColorSpaceCreateDeviceRGB()
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let inset = S * 0.098
    let body = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let shape = squirclePath(in: body)

    // 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.010),
                  blur: S * 0.022, color: rgb(0x000000, 0.28))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0x0B2333))
    ctx.fillPath()
    ctx.restoreGState()

    // 主体渐变（左上深墨蓝 → 右下青绿）
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    let grad = CGGradient(colorsSpace: space, colors: [
        rgb(0x08182B), rgb(0x14496E), rgb(0x1B87A6), rgb(0x3FD0C9),
    ] as CFArray, locations: [0.0, 0.40, 0.72, 1.0])!
    ctx.drawLinearGradient(grad,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: [])

    // 右上角辉光
    let glowCenter = CGPoint(x: body.maxX - body.width * 0.18, y: body.maxY - body.height * 0.16)
    let glow = CGGradient(colorsSpace: space, colors: [
        rgb(0x9CFFF0, 0.34), rgb(0x9CFFF0, 0.0),
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                           endCenter: glowCenter, endRadius: body.width * 0.62, options: [])

    // 一道斜向光带
    let bw = body.width * 0.16
    let ox = -body.width * 0.30
    let band = CGMutablePath()
    band.move(to: CGPoint(x: body.minX + ox, y: body.minY))
    band.addLine(to: CGPoint(x: body.minX + ox + bw, y: body.minY))
    band.addLine(to: CGPoint(x: body.maxX + ox + bw, y: body.maxY))
    band.addLine(to: CGPoint(x: body.maxX + ox, y: body.maxY))
    band.closeSubpath()
    ctx.addPath(band)
    ctx.setFillColor(rgb(0xFFFFFF, 0.11))
    ctx.fillPath()

    // 玻璃边
    ctx.addPath(shape)
    ctx.setLineWidth(S * 0.008)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.22))
    ctx.strokePath()

    ctx.restoreGState()

    // MARK: 放大镜
    // 镜片略偏左上，柄伸向右下，整体在方胜形里居中
    let lensR = body.width * 0.235
    let lensC = CGPoint(x: body.midX - body.width * 0.055, y: body.midY + body.height * 0.062)
    let ringW = body.width * 0.086

    // 镜片里的浅色玻璃
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: lensC.x - lensR, y: lensC.y - lensR, width: lensR * 2, height: lensR * 2))
    ctx.clip()
    let lensGrad = CGGradient(colorsSpace: space, colors: [
        rgb(0xFFFFFF, 0.30), rgb(0xFFFFFF, 0.08),
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(lensGrad,
        start: CGPoint(x: lensC.x - lensR, y: lensC.y + lensR),
        end: CGPoint(x: lensC.x + lensR, y: lensC.y - lensR), options: [])
    ctx.restoreGState()

    // 柄。先画柄再画环，环会盖住接缝。
    let dir = CGPoint(x: 0.7071, y: -0.7071)
    let handleStart = CGPoint(x: lensC.x + dir.x * (lensR - ringW * 0.1),
                              y: lensC.y + dir.y * (lensR - ringW * 0.1))
    let handleLen = body.width * 0.30
    let handleEnd = CGPoint(x: handleStart.x + dir.x * handleLen,
                            y: handleStart.y + dir.y * handleLen)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.006), blur: S * 0.018, color: rgb(0x00131F, 0.45))
    ctx.setLineCap(.round)
    ctx.setLineWidth(ringW * 0.92)
    ctx.setStrokeColor(rgb(0xFFFFFF))
    ctx.move(to: handleStart)
    ctx.addLine(to: handleEnd)
    ctx.strokePath()

    // 镜框
    ctx.setLineWidth(ringW)
    ctx.strokeEllipse(in: CGRect(x: lensC.x - lensR, y: lensC.y - lensR,
                                 width: lensR * 2, height: lensR * 2))
    ctx.restoreGState()

    // MARK: 镜片里的星
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.022, color: rgb(0xBFFFF6, 0.95))
    ctx.addPath(sparklePath(center: lensC, radius: lensR * 0.62))
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // 一颗小星做配重，16px 那档会糊所以不画
    if S >= 64 {
        ctx.addPath(sparklePath(center: CGPoint(x: body.minX + body.width * 0.235,
                                                y: body.minY + body.height * 0.225),
                                radius: lensR * 0.30))
        ctx.setFillColor(rgb(0xFFFFFF, 0.85))
        ctx.fillPath()
    }
}

// MARK: - 输出

func render(size: Int, to url: URL) {
    let S = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("建不了 CGContext") }

    drawIcon(size: S, into: ctx)

    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("写不出 PNG") }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for v in variants {
    render(size: v.px, to: iconset.appendingPathComponent("\(v.name).png"))
    print("  \(v.name).png  (\(v.px)px)")
}
print("→ \(iconset.path)")
