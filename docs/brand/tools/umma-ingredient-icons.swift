#!/usr/bin/env swift
// Umma ingredient icons (brief 018, DECISIONS #30). Direction A, "Persimmon flat": icons drawn the
// way the persimmon mark is drawn (umma-brand.swift): flat fills in the brand palette, no outlines,
// details cut out of the fill as real gaps, and a gap wherever one shape sits on another.
//
// This file is the single source of truth for the icon geometry, the palette and which icon each
// dictionary ingredient uses. It writes:
//   - ios/Umma/Resources/Assets.xcassets/Ingredients/<icon>.imageset   (light + dark SVG)
//   - fixtures/ingredient_icons.json   (canonical name -> icon, plus the per-category fallback)
//   - docs/brand/ingredient-icons.html (the review gallery)
//
//   swift docs/brand/tools/umma-ingredient-icons.swift      # from the repo root
//
// Needs macOS 13+ (CGPath boolean operations). No third-party tools. Never hand-edit the outputs.
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assetDir = root.appendingPathComponent("ios/Umma/Resources/Assets.xcassets/Ingredients")
let mappingURL = root.appendingPathComponent("fixtures/ingredient_icons.json")
let galleryURL = root.appendingPathComponent("docs/brand/ingredient-icons.html")
let dictionaryURL = root.appendingPathComponent("fixtures/ingredients.json")

// MARK: - Palette (light, dark)

/// The brand palette (docs/brand/README.md) plus a few food tones kept analogous to it. Dark values
/// lift the deep tones so they still read on the dark surface; the cut-outs are real holes, so the
/// background shows through in both appearances.
enum Tone: String, CaseIterable {
    case persimmon, persimmonDeep, persimmonLight, leaf, leafLight, cream, pale, amber, gold, tan,
         brown, ink, chili, plum, nori, olive

    var light: UInt32 {
        switch self {
        case .persimmon: 0xF2782A
        case .persimmonDeep: 0xD85F17
        case .persimmonLight: 0xF7A06B
        case .leaf: 0x2F6B3A
        case .leafLight: 0x6FA35F
        case .cream: 0xE9B987
        case .pale: 0xD9C2A6
        case .amber: 0xE89A2E
        case .gold: 0xF0BE48
        case .tan: 0xB07A52
        case .brown: 0x7A4A2E
        case .ink: 0x3B2A20
        case .chili: 0xC8432B
        case .plum: 0x8E4A6B
        case .nori: 0x2E4A33
        case .olive: 0xA6A33A
        }
    }

    var dark: UInt32 {
        switch self {
        case .persimmon: 0xFF8A3D
        case .persimmonDeep: 0xFF9C57
        case .persimmonLight: 0xFFB27A
        case .leaf: 0x8ED39A
        case .leafLight: 0xA9DDA0
        case .cream: 0xFFDCC2
        case .pale: 0xF3E4D3
        case .amber: 0xF2AE4A
        case .gold: 0xF5CF6A
        case .tan: 0xD09A72
        case .brown: 0xB98262
        case .ink: 0xCDB8A6
        case .chili: 0xF0705A
        case .plum: 0xC27BA0
        case .nori: 0x7FA387
        case .olive: 0xC9C565
        }
    }
}

func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }

// MARK: - Geometry helpers (32 x 32 grid, y down, as in SVG)

/// Parses the absolute SVG subset the forms below are written in: M L H V C Q Z.
func P(_ d: String) -> CGPath {
    let path = CGMutablePath()
    var tokens: [String] = []
    var current = ""
    for ch in d {
        if ch.isLetter {
            if !current.isEmpty { tokens.append(current); current = "" }
            tokens.append(String(ch))
        } else if ch == " " || ch == "," {
            if !current.isEmpty { tokens.append(current); current = "" }
        } else if ch == "-" && !current.isEmpty && !current.hasSuffix("e") {
            tokens.append(current); current = "-"
        } else {
            current.append(ch)
        }
    }
    if !current.isEmpty { tokens.append(current) }
    var i = 0
    var cmd = "M"
    var pt = CGPoint.zero
    func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i])!) }
    while i < tokens.count {
        if let c = tokens[i].first, c.isLetter { cmd = tokens[i]; i += 1; if cmd == "Z" { path.closeSubpath(); continue } }
        switch cmd {
        case "M": pt = CGPoint(x: num(), y: num()); path.move(to: pt); cmd = "L"
        case "L": pt = CGPoint(x: num(), y: num()); path.addLine(to: pt)
        case "H": pt = CGPoint(x: num(), y: pt.y); path.addLine(to: pt)
        case "V": pt = CGPoint(x: pt.x, y: num()); path.addLine(to: pt)
        case "C":
            let c1 = CGPoint(x: num(), y: num()), c2 = CGPoint(x: num(), y: num())
            pt = CGPoint(x: num(), y: num()); path.addCurve(to: pt, control1: c1, control2: c2)
        case "Q":
            let c1 = CGPoint(x: num(), y: num())
            pt = CGPoint(x: num(), y: num()); path.addQuadCurve(to: pt, control: c1)
        default: fatalError("unsupported path command \(cmd) in \(d)")
        }
    }
    return path
}

func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r), transform: nil)
}

func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}

/// A rotated ellipse: seeds, beans, leaves.
func oval(_ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat, deg: CGFloat) -> CGPath {
    var t = CGAffineTransform(translationX: x, y: y).rotated(by: deg * .pi / 180)
    return CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t)
}

/// A pointed leaf from `base` to `tip`, `width` across at its widest (the brand mark's sepal idea).
func leafShape(_ base: CGPoint, _ tip: CGPoint, _ width: CGFloat) -> CGPath {
    let dx = tip.x - base.x, dy = tip.y - base.y
    let len = max(hypot(dx, dy), 0.001)
    let nx = -dy / len * width, ny = dx / len * width
    let mid = CGPoint(x: base.x + dx * 0.45, y: base.y + dy * 0.45)
    let p = CGMutablePath()
    p.move(to: base)
    p.addQuadCurve(to: tip, control: CGPoint(x: mid.x + nx, y: mid.y + ny))
    p.addQuadCurve(to: base, control: CGPoint(x: mid.x - nx, y: mid.y - ny))
    p.closeSubpath()
    return p
}

// MARK: - Parts and rendering

enum Part {
    /// A filled shape. Unless `gap` is false, it knocks a gap out of every shape drawn before it.
    case fill(CGPath, Tone, gap: Bool = true)
    /// A stroked line drawn as a filled shape (stems, strings).
    case line(CGPath, Tone, width: CGFloat = 1.8)
    /// A detail cut out of everything drawn before it (a real hole).
    case cut(CGPath, width: CGFloat = 1.5)
    /// A round hole: cheese holes, eyes, salt-shaker holes.
    case hole(CGFloat, CGFloat, CGFloat)
}

let gapWidth: CGFloat = 1.1

struct Layer { var path: CGPath; let tone: Tone }

func render(_ parts: [Part]) -> [Layer] {
    var layers: [Layer] = []
    func knock(_ shape: CGPath) {
        for i in layers.indices { layers[i].path = layers[i].path.subtracting(shape) }
    }
    for part in parts {
        switch part {
        case let .fill(path, tone, gap):
            if gap {
                let halo = path.union(path.copy(strokingWithWidth: gapWidth * 2, lineCap: .round, lineJoin: .round, miterLimit: 4))
                knock(halo)
            }
            layers.append(Layer(path: path, tone: tone))
        case let .line(path, tone, width):
            let shape = path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4)
            knock(shape.copy(strokingWithWidth: gapWidth * 2, lineCap: .round, lineJoin: .round, miterLimit: 4).union(shape))
            layers.append(Layer(path: shape, tone: tone))
        case let .cut(path, width):
            knock(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 4))
        case let .hole(x, y, r):
            knock(circle(x, y, r))
        }
    }
    return layers.filter { !$0.path.isEmpty }
}

func svgData(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String {
        var s = String(format: "%.2f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s == "-0" ? "0" : s
    }
    path.applyWithBlock { element in
        let e = element.pointee
        let p = e.points
        switch e.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint:
            d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func svg(_ layers: [Layer], dark: Bool, title: String, size: Int = 32) -> String {
    var body = ""
    for l in layers {
        body += "<path fill=\"\(hex(dark ? l.tone.dark : l.tone.light))\" fill-rule=\"evenodd\" d=\"\(svgData(l.path))\"/>"
    }
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 32 32\" width=\"\(size)\" height=\"\(size)\" role=\"img\" aria-label=\"\(title)\"><title>\(title)</title>\(body)</svg>\n"
}

// MARK: - Forms
// Each form is a function of its tones, so ingredients that share a shape (bottled sauces, spice
// jars, cans) share one drawing in their own colours.

enum Form {
    static func garlic(_ skin: Tone = .cream) -> [Part] { [
        .fill(P("M16 6C16 6 14 9 12 10C8 12 6 15 6 19C6 24 10 27 16 27C22 27 26 24 26 19C26 15 24 12 20 10C18 9 16 6 16 6Z"), skin),
        .cut(P("M16 12C14 15 13.5 21 14.5 26.5")), .cut(P("M16 12C18 15 18.5 21 17.5 26.5")),
        .line(P("M16 5.5L16 2.8"), .tan, width: 2),
    ] }

    static func onion(_ skin: Tone) -> [Part] { [
        .fill(P("M16 7C10 10 6 14 6 19C6 24 10.5 27 16 27C21.5 27 26 24 26 19C26 14 22 10 16 7Z"), skin),
        .cut(P("M16 10C12.5 13 11.8 21 13 26.5")), .cut(P("M16 10C19.5 13 20.2 21 19 26.5")),
        .line(P("M16 6.5C15.2 4.6 15.8 3.2 17.6 2.6"), .leaf, width: 1.9),
    ] }

    static func scallion(_ root: Tone = .pale, _ top: Tone = .leafLight) -> [Part] { [
        .fill(P("M12.6 20C11 14.6 8.6 9.4 5.4 4C10 7.4 14 12.6 16 20Z"), top),
        .fill(P("M14.2 20C14 13.6 14.6 8.2 16 2.6C17.6 8.2 18.2 13.6 17.8 20Z"), top),
        .fill(P("M16.2 20C18.2 12.6 21.6 7.6 26.6 4C24 9 21.8 14.6 19.6 20Z"), top),
        .fill(rrect(10, 18.6, 12, 9.6, 4.8), root),
        .cut(P("M13 23.4L19 23.4"), width: 1.3),
    ] }

    static func ginger() -> [Part] { [
        .fill(P("M6 18C6 15 8.5 13.5 11 14.5C11.5 11 14 9.5 16.5 11C18 8.5 21.5 8.5 22.5 11.5C25.5 11.5 27 14 26 16.5C25 19.5 21.5 20 19.5 19C18 21.5 14.5 22.5 12.5 21C10 23.5 6 22 6 18Z"), .gold),
        .cut(P("M10 18L12.4 17.4")), .cut(P("M16 14.6L17.6 13.2")), .cut(P("M21 14.8L23 14.2")), .cut(P("M15.6 18.6L17.2 17.6")),
    ] }

    static func tomato(_ body: Tone = .chili) -> [Part] { [
        .fill(circle(16, 18, 10), body),
        .fill(P("M16 7.5L17.6 10.4L21 9.6L19 12.3L21.6 14.2L18 14L16 16.3L14 14L10.4 14.2L13 12.3L11 9.6L14.4 10.4Z"), .leaf),
        .line(P("M16 8.5L16.6 4.6"), .leaf, width: 1.8),
        .cut(P("M9.4 20C9.2 18.2 9.7 16.6 10.7 15.4"), width: 1.4),
    ] }

    static func cucumber(_ skin: Tone = .leaf) -> [Part] { [
        .fill(P("M6.5 23.5C4.5 21.5 5.5 18 9 14.5L17 6.5C20 3.5 24 3 26 5C28 7 27.5 11 24.5 14L16.5 22C13 25.5 8.5 25.5 6.5 23.5Z"), skin),
        .cut(P("M11 17.6L12 16.6")), .cut(P("M15 13.6L16 12.6")), .cut(P("M19.4 9.4L20.4 8.4")),
        .cut(P("M13.8 20L14.8 19")), .cut(P("M18 15.8L19 14.8")), .cut(P("M22 11.6L23 10.6")),
    ] }

    static func citrus(_ peel: Tone) -> [Part] { [
        .fill(P("M3 17C5 14 7 10 12 8.6C14.5 8 17.5 8 20 8.6C25 10 27 14 29 17C27 20 25 24 20 25.4C17.5 26 14.5 26 12 25.4C7 24 5 20 3 17Z"), peel),
        .fill(P("M16 8.3C16.8 5.4 19.6 3.6 23.2 3.8C22.4 6.6 19.6 8.4 16 8.3Z"), .leaf),
        .cut(P("M8.6 15.4C9.4 13.4 10.8 12 12.8 11.4"), width: 1.4),
    ] }

    static func potato() -> [Part] { [
        .fill(P("M5 17C5 11.5 9.5 8 15.5 8C22 8 27 11 27 16C27 21.5 22.5 25 16 25C9.5 25 5 22 5 17Z"), .tan),
        .hole(11, 14, 0.9), .hole(19.5, 12.5, 0.9), .hole(15.5, 20.2, 0.9), .hole(22, 19, 0.9),
    ] }

    static func carrot() -> [Part] { [
        .fill(P("M16 9.5C19 8 23 11.5 22 14.5C21.6 15.6 20.8 16.4 19.8 17.2L8.6 26.4C7.4 27.3 6 25.9 6.9 24.7L14.2 12.2C14.7 11 15.2 10 16 9.5Z"), .persimmon),
        .fill(P("M19.4 10.4C19.4 7 20.9 4.6 22.9 3.6C23.5 6.6 22.5 8.9 21 10.6Z"), .leaf),
        .fill(P("M21.2 11.9C23.6 9.6 26.6 9 28.6 9.8C27.6 12 25 13 22 12.7Z"), .leaf),
        .cut(P("M13.2 16.6L15 18")), .cut(P("M10.6 21L12.3 22.4")),
    ] }

    static func bellPepper(_ body: Tone) -> [Part] { [
        .fill(P("M7 14C6 10 9.5 8.5 12 9.5C13.5 8.5 18.5 8.5 20 9.5C22.5 8.5 26 10 25 14C24.5 18 26 21.5 23.5 25C21.5 27.5 18.5 27 16 26C13.5 27 10.5 27.5 8.5 25C6 21.5 7.5 18 7 14Z"), body),
        .fill(P("M14.8 10C14.8 7 15.4 5 18 3.4L19.2 4.8C17.3 6 17.1 7.8 17.1 10Z"), .leaf),
        .cut(P("M12 13C11 17 11 21 12.5 25.2")), .cut(P("M20 13C21 17 21 21 19.5 25.2")),
    ] }

    static func chili(_ body: Tone) -> [Part] { [
        .fill(P("M8 10C10 9 12.5 10.5 14 13C16.5 17.5 20 22 26 24.5C27.5 25.2 27 27 25.4 26.9C17.5 26.4 10.5 21 7.4 14.5C6.6 12.6 6.8 10.6 8 10Z"), body),
        .fill(P("M8.6 10.6C8 8 8.6 5.8 10.6 4.4L11.8 5.6C10.4 6.8 10.2 8.6 10.8 10.4Z"), .leaf),
        .cut(P("M11 14.6C13 18.4 16 21.4 19.6 23.4"), width: 1.4),
    ] }

    static func leafy(_ body: Tone = .leaf) -> [Part] { [
        .fill(P("M7 25C5 17 9 8 20 5C25 4 27.5 5 27.5 7C27 16 22 25 12 26.5C10 26.8 8 26.2 7 25Z"), body),
        .cut(P("M8.6 24.4C13 18 18 12 24.6 7.4")),
        .cut(P("M13 18.4L11.6 13.6"), width: 1.2), .cut(P("M16.6 14.6L15.9 10.6"), width: 1.2),
        .cut(P("M15.4 19.6L20.4 19"), width: 1.2), .cut(P("M19.4 15.6L23.4 14.9"), width: 1.2),
    ] }

    static func cabbage(_ outer: Tone = .leafLight, _ inner: Tone = .leaf) -> [Part] { [
        .fill(circle(16, 17, 11), outer),
        .fill(P("M16 9C20.5 9 23.5 12.5 23.5 17C23.5 21.5 20.5 25 16 25C11.5 25 8.5 21.5 8.5 17C8.5 12.5 11.5 9 16 9Z"), inner),
        .cut(P("M16 10.5C13.5 13.5 13.2 19.5 15 24")), .cut(P("M16.4 13C18.8 15 19.4 19 18.4 22.6"), width: 1.3),
    ] }

    static func mushroom(_ cap: Tone = .tan) -> [Part] { [
        .fill(P("M12 17L20 17L21 25C21.1 26.2 20.2 27 19 27L13 27C11.8 27 10.9 26.2 11 25Z"), .pale),
        .fill(P("M4 16C4 9.5 9.5 5 16 5C22.5 5 28 9.5 28 16C28 17.2 27.2 18 26 18L6 18C4.8 18 4 17.2 4 16Z"), cap),
        .hole(10.5, 11.5, 1.1), .hole(16, 9, 1.2), .hole(21.5, 11.8, 1),
    ] }

    static func broccoli() -> [Part] { [
        .fill(P("M13.4 18.5L18.6 18.5L18.2 27C18.2 27.6 17.7 28 17.1 28L14.9 28C14.3 28 13.8 27.6 13.8 27Z"), .leafLight),
        .fill(circle(11, 13.5, 5.8).union(circle(17, 10, 6.4)).union(circle(22, 14.5, 5.4)).union(circle(16, 16.5, 5.6)), .leaf),
        .cut(P("M13 12.6C14 11.4 15.4 10.8 17 11"), width: 1.3), .cut(P("M18.6 15.4C19.8 14.6 21 14.4 22.2 14.8"), width: 1.3),
    ] }

    static func avocado() -> [Part] { [
        .fill(P("M16 4C19.5 4 21 7.5 22 11C23.5 15.5 26 17.5 26 21C26 25.5 21.5 28.5 16 28.5C10.5 28.5 6 25.5 6 21C6 17.5 8.5 15.5 10 11C11 7.5 12.5 4 16 4Z"), .leaf),
        .fill(P("M16 7.6C18.3 7.6 19.4 10.2 20.2 12.8C21.4 16.4 23.4 18 23.4 21C23.4 24.4 20 26.4 16 26.4C12 26.4 8.6 24.4 8.6 21C8.6 18 10.6 16.4 11.8 12.8C12.6 10.2 13.7 7.6 16 7.6Z"), .olive),
        .fill(circle(16, 20.6, 4), .tan),
    ] }

    static func apple() -> [Part] { [
        .fill(P("M16 9.5C19 7.5 25 8 26.5 13C28 18 25 25.5 20.5 26.5C18.8 26.9 17.3 26 16 26C14.7 26 13.2 26.9 11.5 26.5C7 25.5 4 18 5.5 13C7 8 13 7.5 16 9.5Z"), .chili),
        .line(P("M16 9.4L16.8 4.8"), .brown, width: 1.8),
        .fill(P("M17.6 7.2C19 4.6 21.8 3.5 24.4 4C23.4 6.6 20.6 7.9 17.6 7.2Z"), .leaf),
        .cut(P("M9 15.2C9.3 13.3 10.3 11.9 11.8 11.3"), width: 1.4),
    ] }

    static func banana() -> [Part] { [
        .fill(P("M5 9C6.5 8 7.5 9 8 10.5C10 17.5 15.5 22 23.5 21.5C25.5 21.4 27 21.8 27 23C27 24.5 24 26.5 19.5 26.5C11 26.5 5.5 19.5 4.5 13C4.2 11.3 4.2 9.6 5 9Z"), .gold),
        .fill(P("M4.4 9.8L5.2 6.8L7 7.2L6.6 10Z"), .brown),
        .cut(P("M8 13.4C10 19 15 23 22 23.6"), width: 1.3),
    ] }

    static func sprig(_ leaves: Tone, narrow: Bool = false) -> [Part] {
        let w: CGFloat = narrow ? 1.3 : 2.6
        var parts: [Part] = [.line(P("M16 28C16 21 16 12 16 4.5"), .leaf, width: 1.7)]
        let pairs: [(CGFloat, CGFloat)] = [(23, 6.5), (17.5, 6.8), (12, 6.2)]
        for (y, len) in pairs {
            parts.append(.fill(leafShape(CGPoint(x: 16, y: y), CGPoint(x: 16 - len, y: y - len * 0.75), w), leaves))
            parts.append(.fill(leafShape(CGPoint(x: 16, y: y), CGPoint(x: 16 + len, y: y - len * 0.75), w), leaves))
        }
        parts.append(.fill(leafShape(CGPoint(x: 16, y: 7), CGPoint(x: 16, y: 1.6), narrow ? 1.2 : 2.2), leaves))
        return parts
    }

    static func drumstick(_ meat: Tone = .persimmon) -> [Part] { [
        .fill(P("M15.6 16.2L17.6 18.2L10.6 25.2L8.6 23.2Z").union(circle(7, 22.6, 2.4)).union(circle(10.6, 26.2, 2.4)), .pale),
        .fill(P("M20 4.5C25 4.5 28 8.5 27.5 13C27 17.5 22.5 20 18.5 19C16 18.5 13.5 16 13 13.5C12.5 8.5 15.5 4.5 20 4.5Z"), meat),
        .cut(P("M18 8.6C20 7.6 22.4 7.8 24 9.2"), width: 1.4),
    ] }

    static func egg() -> [Part] { [
        .fill(P("M16 4.5C21 4.5 25 12 25 18.5C25 23.5 21 27 16 27C11 27 7 23.5 7 18.5C7 12 11 4.5 16 4.5Z"), .cream),
        .cut(P("M11.4 16C11.8 13.2 12.8 11 14 9.8"), width: 1.4),
    ] }

    static func mince(_ meat: Tone) -> [Part] { [
        .fill(P("M3 23.5L29 23.5L27.4 27.4C27.2 27.8 26.8 28 26.4 28L5.6 28C5.2 28 4.8 27.8 4.6 27.4Z"), .pale),
        .fill(P("M5 21.5C5 16 9 12 13 12.5C14.5 9.5 19 9 21 11.5C24.5 11 27.5 14.5 27 18.5C27 20.5 26.6 21.5 25.5 22L6.5 22C5.6 22 5 21.8 5 21.5Z"), meat),
        .cut(P("M10 17C11 16 12 16 13 17"), width: 1.3), .cut(P("M16 14.5C17 13.5 18 13.5 19 14.5"), width: 1.3),
        .cut(P("M18.4 19C19.4 18 20.4 18 21.4 19"), width: 1.3), .cut(P("M12 20.4C13 19.4 14 19.4 15 20.4"), width: 1.3),
    ] }

    static func bacon(_ meat: Tone = .persimmonLight) -> [Part] { [
        .fill(P("M4 12C8 9 11 15 15 12C19 9 22 15 28 11L28 19C22 23 19 17 15 20C11 23 8 17 4 20Z"), meat),
        .cut(P("M5 16C8.5 13.5 11.5 18.5 15 16C18.5 13.5 22 18.5 27 15"), width: 2),
    ] }

    static func fish(_ body: Tone = .persimmonLight) -> [Part] { [
        .fill(P("M4 16C7 10 13 8 18 9.5C21 10.3 23 12 24 13.5L28.5 9.5C29 9.1 29.6 9.5 29.5 10.2L28.5 16L29.5 21.8C29.6 22.5 29 22.9 28.5 22.5L24 18.5C23 20 21 21.7 18 22.5C13 24 7 22 4 16Z"), body),
        .hole(9.4, 14.8, 1.1),
        .cut(P("M13.4 11.6C14.8 14 14.8 18 13.4 20.4"), width: 1.4),
    ] }

    static func shrimp() -> [Part] { [
        .fill(P("M8 20L3.5 17L4.5 22L3.5 26.5L8.5 23.5Z"), .persimmonDeep),
        .fill(P("M22 6C27 8 28.5 14 26 19C23.5 24 17 27 11 25.5C8 24.8 6.5 22.5 7.5 20.5C8.5 18.5 11 18.6 13 19.5C16.5 21 20 19.5 21.5 16.5C23 13.5 21.5 10.5 19 9.5C17.5 8.9 17.6 6.5 19.2 6C20.1 5.7 21.1 5.7 22 6Z"), .persimmon),
        .cut(P("M24.6 11.4L21.4 13")), .cut(P("M25.2 16.6L21.8 16.2")), .cut(P("M23 21.2L20.6 18.8")),
        .cut(P("M18.4 24.6L17.6 21.4")), .cut(P("M13.6 25.6L14 22.2")),
    ] }

    /// An isometric block: tofu, butter.
    static func block(_ top: Tone, _ left: Tone, _ right: Tone) -> [Part] { [
        .fill(P("M5 12L16 6.5L27 12L16 17.5Z"), top),
        .fill(P("M5 12L16 17.5L16 28L5 22.5Z"), left),
        .fill(P("M27 12L16 17.5L16 28L27 22.5Z"), right),
    ] }

    static func bottle(_ liquid: Tone, cap: Tone = .chili) -> [Part] { [
        .fill(P("M9.5 13.5C9.5 11.6 12.4 10.6 12.4 8.8L12.4 6L19.6 6L19.6 8.8C19.6 10.6 22.5 11.6 22.5 13.5L23 25.4C23 26.3 22.3 27.2 21.4 27.2L10.6 27.2C9.7 27.2 9 26.3 9 25.4Z"), liquid),
        .fill(rrect(11.6, 2.2, 8.8, 3.8, 1.2), cap),
        .fill(rrect(10, 15.8, 12, 6.4, 1.2), .pale),
    ] }

    static func tub(_ paste: Tone, lid: Tone = .leaf) -> [Part] { [
        .fill(P("M7 12.5L25 12.5L23.4 25.6C23.3 26.5 22.6 27 21.8 27L10.2 27C9.4 27 8.7 26.5 8.6 25.6Z"), paste),
        .fill(P("M6 10C6 8.9 6.9 8 8 8L24 8C25.1 8 26 8.9 26 10L26 12.5L6 12.5Z"), lid),
        .cut(P("M11.5 18.5L20.5 18.5")), .cut(P("M12.5 22L19.5 22")),
    ] }

    static func squeeze(_ body: Tone, cap: Tone) -> [Part] { [
        .fill(P("M8.5 12C8.5 10.5 10 9.5 11.5 9.5L20.5 9.5C22 9.5 23.5 10.5 23.5 12L23.5 25C23.5 26.1 22.6 27 21.5 27L10.5 27C9.4 27 8.5 26.1 8.5 25Z"), body),
        .fill(P("M13 9.5L14 5.6L18 5.6L19 9.5Z"), cap),
        .fill(P("M15.1 5.6L15.6 2.4L16.4 2.4L16.9 5.6Z"), cap, gap: false),
        .cut(P("M12 17L20 17")), .cut(P("M12 20.5L17.5 20.5")),
    ] }

    static func honeyJar(_ honey: Tone) -> [Part] { [
        .fill(P("M9.5 11C8.1 11 7 12.1 7 13.5L7 24C7 25.7 8.3 27 10 27L22 27C23.7 27 25 25.7 25 24L25 13.5C25 12.1 23.9 11 22.5 11Z"), honey),
        .fill(P("M9 5.6L23 5.6C23.6 5.6 24 6 24 6.6L24 11L8 11L8 6.6C8 6 8.4 5.6 9 5.6Z"), .leaf),
        .cut(P("M12 11L12 15.2C12 16.6 14.4 16.6 14.4 15.2L14.4 11"), width: 1.6),
    ] }

    static func can(_ label: Tone) -> [Part] { [
        .fill(P("M8 9L24 9L24 25C24 26.7 20.4 28 16 28C11.6 28 8 26.7 8 25Z"), label),
        .fill(CGPath(ellipseIn: CGRect(x: 8, y: 6, width: 16, height: 5.6), transform: nil), .pale),
        .cut(P("M8.4 13.4C11 14.6 21 14.6 23.6 13.4"), width: 1.3), .cut(P("M8.4 22.6C11 23.8 21 23.8 23.6 22.6"), width: 1.3),
    ] }

    static func sack(_ sack: Tone, badge: Tone) -> [Part] { [
        .fill(P("M9 11L23 11C25 15 26 20 25.5 24.5C25.3 26.2 24 27.5 22.3 27.5L9.7 27.5C8 27.5 6.7 26.2 6.5 24.5C6 20 7 15 9 11Z"), sack),
        .fill(P("M10.2 10.6L12 5.6C12.2 5 12.7 4.6 13.3 4.6L18.7 4.6C19.3 4.6 19.8 5 20 5.6L21.8 10.6Z"), sack),
        .fill(circle(16, 19.5, 4.4), badge),
    ] }

    static func carton(_ body: Tone, gable: Tone) -> [Part] { [
        .fill(P("M9 13L23 13L23 26C23 26.8 22.3 27.5 21.5 27.5L10.5 27.5C9.7 27.5 9 26.8 9 26Z"), body),
        .fill(P("M9 12.6L12 7L20 7L23 12.6Z"), gable),
        .fill(rrect(12, 3.4, 8, 2.8, 0.8), gable),
        .fill(circle(16, 20.4, 3.4), gable),
    ] }

    static func spiceJar(_ spice: Tone, lid: Tone = .leaf) -> [Part] { [
        .fill(P("M10 12L22 12L22 25.5C22 26.3 21.3 27 20.5 27L11.5 27C10.7 27 10 26.3 10 25.5Z"), spice),
        .fill(rrect(9.5, 6.2, 13, 5.2, 1.6), lid),
        .fill(rrect(10, 16.4, 12, 5.2, 0), .pale),
    ] }

    static func saltShaker() -> [Part] { [
        .fill(P("M10 13C10 11 11.5 10 13 10L19 10C20.5 10 22 11 22 13L22.5 26C22.5 26.8 21.8 27.5 21 27.5L11 27.5C10.2 27.5 9.5 26.8 9.5 26Z"), .pale),
        .fill(P("M10 9.6C10 6.5 12.7 4.5 16 4.5C19.3 4.5 22 6.5 22 9.6Z"), .leaf),
        .hole(13.6, 7.6, 0.7), .hole(16, 6.6, 0.7), .hole(18.4, 7.6, 0.7),
        .cut(P("M12.6 16.6L19.4 16.6"), width: 1.3),
    ] }

    static func grinder() -> [Part] { [
        .fill(P("M11 11L21 11L22 26C22 26.8 21.3 27.5 20.5 27.5L11.5 27.5C10.7 27.5 10 26.8 10 26Z"), .brown),
        .fill(P("M12 10.6C12 7.8 13.8 6.4 16 6.4C18.2 6.4 20 7.8 20 10.6Z"), .tan),
        .fill(circle(16, 4, 1.7), .tan),
        .cut(P("M10.6 15.6L21.4 15.6"), width: 1.3),
    ] }

    static func riceBowl() -> [Part] { [
        .fill(P("M7 15.5C7 11 11 8 16 8C21 8 25 11 25 15.5Z"), .pale),
        .fill(P("M5 15.5L27 15.5C27 21.8 22 26 16 26C10 26 5 21.8 5 15.5Z"), .leaf),
        .fill(P("M12.5 26L19.5 26L18.8 28.5L13.2 28.5Z"), .leaf, gap: false),
        .hole(13.2, 11.8, 0.7), .hole(18, 11.2, 0.7), .hole(16, 13.6, 0.7),
    ] }

    static func noodles(_ noodle: Tone = .gold) -> [Part] { [
        .fill(circle(16, 16, 11.5), noodle),
        .cut(P("M6.6 12C9.6 10 12 14 15 12C18 10 20.4 14 25.4 12")),
        .cut(P("M5.4 16.6C8.9 14.6 11.4 18.6 14.9 16.6C18.4 14.6 20.9 18.6 26.6 16.6")),
        .cut(P("M7.2 21.2C10.2 19.2 12.7 23.2 15.7 21.2C18.7 19.2 21.2 23.2 24.8 21.2")),
    ] }

    static func bread() -> [Part] { [
        .fill(P("M5 14C5 10 8.5 7.5 12 8C13.5 6.5 18.5 6.5 20 8C23.5 7.5 27 10 27 14C27 15.6 26 16.6 25 17L25 25.5C25 26.3 24.3 27 23.5 27L8.5 27C7.7 27 7 26.3 7 25.5L7 17C6 16.6 5 15.6 5 14Z"), .tan),
        .fill(P("M8.8 14.5C8.8 12.2 10.7 10.8 12.7 11.1C14 9.9 18 9.9 19.3 11.1C21.3 10.8 23.2 12.2 23.2 14.5C23.2 15.5 22.6 16.2 21.8 16.5L21.8 24.4L10.2 24.4L10.2 16.5C9.4 16.2 8.8 15.5 8.8 14.5Z"), .cream),
    ] }

    static func tortilla() -> [Part] { [
        .fill(circle(16, 16, 11.5), .gold),
        .hole(11.5, 12, 1.1), .hole(19.5, 10.6, 0.9), .hole(21.4, 18.6, 1.2), .hole(13.6, 20.4, 0.9), .hole(16.4, 15.4, 0.7),
    ] }

    static func nori() -> [Part] { [
        .fill(rrect(6, 7, 20, 18, 2.2), .nori),
        .cut(P("M6 13L26 13"), width: 1.2), .cut(P("M6 19L26 19"), width: 1.2),
    ] }

    static func cheese(_ body: Tone) -> [Part] { [
        .fill(P("M4 17L28 10L28 25C28 26.1 27.1 27 26 27L6 27C4.9 27 4 26.1 4 25Z"), body),
        .hole(11.5, 21.5, 1.9), .hole(20, 18.6, 1.4), .hole(23.4, 23.6, 1.2), .hole(15.6, 25.2, 0.9),
    ] }

    static func yogurt() -> [Part] { [
        .fill(P("M8 11L24 11L22 26C21.9 26.9 21.1 27.5 20.2 27.5L11.8 27.5C10.9 27.5 10.1 26.9 10 26Z"), .pale),
        .fill(P("M7 7.6L25 7.6C25.6 7.6 26 8 26 8.6L26 11L6 11L6 8.6C6 8 6.4 7.6 7 7.6Z"), .leaf),
        .fill(circle(16, 19, 3.6), .persimmonLight),
    ] }

    static func oilBottle(_ oil: Tone, cap: Tone = .leaf) -> [Part] { [
        .fill(P("M5.8 12.8C5.8 11.2 8 10.4 8 8.8L8 6L13 6L13 8.8C13 10.4 15.2 11.2 15.2 12.8L16.2 25.4C16.2 26.3 15.5 27.2 14.6 27.2L6.4 27.2C5.5 27.2 4.8 26.3 4.8 25.4Z"), oil),
        .fill(rrect(7.4, 2.4, 6.2, 3.6, 1), cap),
        .fill(P("M23.4 11.6C23.4 11.6 28.6 17.6 28.6 21.2C28.6 24.1 26.3 26.4 23.4 26.4C20.5 26.4 18.2 24.1 18.2 21.2C18.2 17.6 23.4 11.6 23.4 11.6Z"), oil),
    ] }

    static func preserveJar(_ contents: Tone) -> [Part] { [
        .fill(P("M9 9.4L23 9.4L24 12.4L24 25C24 26.4 22.9 27.5 21.5 27.5L10.5 27.5C9.1 27.5 8 26.4 8 25L8 12.4Z"), .pale),
        .fill(P("M8 15L24 15L24 25C24 26.4 22.9 27.5 21.5 27.5L10.5 27.5C9.1 27.5 8 26.4 8 25Z"), contents),
        .fill(rrect(9, 4.8, 14, 4, 1.2), .leaf),
    ] }

    static func nut() -> [Part] { [
        .fill(P("M10 6C14 4.5 18 7 18.5 11C19 14.5 21.5 17 25 17.5C27 17.8 28 19.5 27 21.5C24.5 26 17 27.5 11.5 24.5C6.5 21.8 4.5 15.5 5.5 11C6 8.6 7.8 6.8 10 6Z"), .tan),
        .cut(P("M9 10.4C8.4 14.6 10 19 14 21.6"), width: 1.4),
    ] }

    static func coconut() -> [Part] { [
        .fill(circle(16, 16.5, 11.5), .brown),
        .fill(circle(16, 16.5, 8.2), .pale),
    ] }

    static func box(_ body: Tone, badge: Tone = .pale) -> [Part] { [
        .fill(P("M8 10L24 10L24 26C24 26.8 23.3 27.5 22.5 27.5L9.5 27.5C8.7 27.5 8 26.8 8 26Z"), body),
        .fill(P("M8 9.6L10 5L22 5L24 9.6Z"), body),
        .fill(circle(16, 18.6, 4.2), badge),
    ] }

    static func seeds(_ seed: Tone = .cream) -> [Part] {
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(10, 10, 30), (17, 8, -20), (23.5, 11, 50), (8.5, 18.5, -40),
                                                     (15.5, 15.5, 15), (22.5, 18.5, -10), (11.5, 24.5, 60), (19, 23.5, -55)]
        return spots.map { .fill(oval($0.0, $0.1, 1.9, 3.1, deg: $0.2), seed) }
    }

    static func beans(_ bean: Tone) -> [Part] {
        let spots: [(CGFloat, CGFloat, CGFloat)] = [(11, 12, -25), (21, 12.5, 30), (16, 21, 5), (8.5, 22, 70), (23.5, 22.5, -60)]
        return spots.map { .fill(oval($0.0, $0.1, 4.1, 2.9, deg: $0.2), bean) }
            + spots.map { .cut(P("M\($0.0 - 1.2) \($0.1)L\($0.0 + 1.2) \($0.1)"), width: 1.1) }
    }

    static func cinnamon() -> [Part] { [
        .fill(P("M6 22L20 6.5C21 5.4 22.8 5.4 23.8 6.4L25.6 8.2C26.6 9.2 26.6 11 25.5 12L10 26C9 26.9 7.4 26.9 6.4 25.9L6.1 25.6C5.1 24.6 5.1 23 6 22Z"), .brown),
        .cut(P("M20.4 7.6C21.8 8 23.6 9.8 24 11.4"), width: 1.3),
    ] }

    static func basket() -> [Part] { [
        .line(P("M10.5 13L14 6.5"), .tan, width: 1.9), .line(P("M21.5 13L18 6.5"), .tan, width: 1.9),
        .fill(P("M5 13L27 13L24.6 25.4C24.4 26.3 23.7 27 22.7 27L9.3 27C8.3 27 7.6 26.3 7.4 25.4Z"), .tan),
        .cut(P("M12 17L12.6 23")), .cut(P("M16 17L16 23")), .cut(P("M20 17L19.4 23")),
    ] }
}

// MARK: - The icon set: name -> drawing

let icons: [(String, [Part])] = [
    // produce
    ("garlic", Form.garlic()), ("onion", Form.onion(.amber)), ("red-onion", Form.onion(.plum)), ("shallot", Form.onion(.persimmonLight)),
    ("scallion", Form.scallion()), ("celery", Form.scallion(.leafLight, .leaf)), ("ginger", Form.ginger()),
    ("tomato", Form.tomato()), ("cucumber", Form.cucumber()), ("zucchini", Form.cucumber(.leafLight)),
    ("lemon", Form.citrus(.gold)), ("lime", Form.citrus(.leafLight)), ("potato", Form.potato()), ("carrot", Form.carrot()),
    ("bell-pepper", Form.bellPepper(.chili)), ("chili", Form.chili(.chili)), ("jalapeno", Form.chili(.leafLight)),
    ("spinach", Form.leafy()), ("cabbage", Form.cabbage()), ("napa-cabbage", Form.cabbage(.pale, .leafLight)),
    ("mushroom", Form.mushroom()), ("shiitake", Form.mushroom(.brown)), ("broccoli", Form.broccoli()),
    ("avocado", Form.avocado()), ("apple", Form.apple()), ("banana", Form.banana()),
    // herbs
    ("herb", Form.sprig(.leafLight)), ("basil", Form.sprig(.leaf)), ("rosemary", Form.sprig(.leaf, narrow: true)),
    // protein
    ("chicken", Form.drumstick()), ("egg", Form.egg()), ("ground-beef", Form.mince(.chili)), ("ground-pork", Form.mince(.persimmonLight)),
    ("bacon", Form.bacon()), ("fish", Form.fish()), ("shrimp", Form.shrimp()), ("tofu", Form.block(.pale, .cream, .tan)),
    // condiments
    ("soy-sauce", Form.bottle(.ink)), ("fish-sauce", Form.bottle(.amber, cap: .leaf)), ("oyster-sauce", Form.bottle(.brown, cap: .leaf)),
    ("vinegar", Form.bottle(.pale, cap: .leaf)), ("cider-vinegar", Form.bottle(.amber, cap: .chili)), ("mirin", Form.bottle(.gold, cap: .leaf)),
    ("rice-wine", Form.bottle(.persimmonDeep, cap: .leaf)), ("sauce", Form.bottle(.tan, cap: .leaf)),
    ("gochujang", Form.tub(.chili)), ("chili-paste", Form.tub(.persimmonDeep, lid: .chili)), ("doenjang", Form.tub(.brown)),
    ("miso", Form.tub(.gold)), ("peanut-butter", Form.tub(.tan, lid: .chili)), ("mustard", Form.tub(.gold, lid: .chili)),
    ("ketchup", Form.squeeze(.chili, cap: .leaf)), ("mayonnaise", Form.squeeze(.pale, cap: .chili)),
    ("honey", Form.honeyJar(.amber)), ("maple-syrup", Form.honeyJar(.tan)), ("molasses", Form.honeyJar(.brown)),
    ("canned-tomatoes", Form.can(.chili)), ("coconut-milk", Form.can(.cream)), ("canned-fish", Form.can(.amber)),
    ("canned-meat", Form.can(.persimmonLight)), ("chipotle", Form.can(.persimmonDeep)), ("canned-beans", Form.can(.gold)),
    ("sugar", Form.sack(.tan, badge: .pale)), ("brown-sugar", Form.sack(.tan, badge: .brown)), ("flour", Form.sack(.cream, badge: .pale)),
    ("oats", Form.sack(.tan, badge: .cream)), ("rice", Form.sack(.leaf, badge: .pale)),
    ("stock", Form.carton(.gold, gable: .persimmon)), ("milk", Form.carton(.pale, gable: .leaf)), ("cream", Form.carton(.pale, gable: .persimmon)),
    ("plant-milk", Form.carton(.cream, gable: .tan)),
    // spices
    ("salt", Form.saltShaker()), ("black-pepper", Form.grinder()), ("spice", Form.spiceJar(.tan)),
    ("red-spice", Form.spiceJar(.chili)), ("brown-spice", Form.spiceJar(.brown)), ("pale-spice", Form.spiceJar(.cream)),
    ("gold-spice", Form.spiceJar(.gold)), ("dried-herb", Form.spiceJar(.leafLight)), ("chili-flakes", Form.spiceJar(.chili, lid: .chili)),
    ("cinnamon", Form.cinnamon()), ("vanilla", Form.bottle(.brown, cap: .tan)),
    // grains
    ("cooked-rice", Form.riceBowl()), ("noodles", Form.noodles()), ("pasta", Form.noodles(.amber)), ("bread", Form.bread()),
    ("tortilla", Form.tortilla()), ("seaweed", Form.nori()),
    // dairy
    ("butter", Form.block(.gold, .amber, .gold)), ("cheese", Form.cheese(.gold)), ("fresh-cheese", Form.cheese(.pale)),
    ("cheddar", Form.cheese(.persimmonLight)), ("yogurt", Form.yogurt()),
    // oils
    ("oil", Form.oilBottle(.gold)), ("olive-oil", Form.oilBottle(.olive)), ("sesame-oil", Form.oilBottle(.amber, cap: .chili)),
    // preserved, nuts, seeds, legumes, baking
    ("kimchi", Form.preserveJar(.chili)), ("pickle", Form.preserveJar(.leafLight)), ("nut", Form.nut()), ("coconut", Form.coconut()),
    ("seeds", Form.seeds()), ("beans", Form.beans(.ink)), ("chickpeas", Form.beans(.gold)),
    ("baking", Form.box(.persimmon)), ("cornstarch", Form.box(.gold)),
    // fallback
    ("basket", Form.basket()),
]

/// Category fallbacks, used when an ingredient has no icon of its own.
let categoryIcons: [String: String] = [
    "produce": "spinach", "herb": "herb", "protein": "chicken", "condiment": "sauce", "spice": "spice",
    "grain": "rice", "dairy": "milk", "preserved": "pickle", "oil": "oil", "nut": "nut", "baking": "baking",
    "legume": "beans", "seed": "seeds", "additive": "basket",
]

/// Dictionary canonical names -> icon. Anything missing falls back to its category.
let ingredientIcons: [String: String] = [
    "garlic": "garlic", "onion": "onion", "red onion": "red-onion", "shallot": "shallot", "scallion": "scallion",
    "chives": "scallion", "celery": "celery", "ginger": "ginger", "tomato": "tomato", "cherry tomato": "tomato",
    "cucumber": "cucumber", "zucchini": "zucchini", "lemon": "lemon", "lime": "lime", "potato": "potato",
    "carrot": "carrot", "bell pepper": "bell-pepper", "jalapeño": "jalapeno", "spinach": "spinach", "cabbage": "cabbage",
    "napa cabbage": "napa-cabbage", "mushroom": "mushroom", "shiitake mushroom": "shiitake", "broccoli": "broccoli",
    "avocado": "avocado", "apple": "apple", "banana": "banana",
    "cilantro": "herb", "parsley": "herb", "mint": "herb", "thyme": "rosemary", "oregano": "herb", "basil": "basil",
    "rosemary": "rosemary",
    "chicken": "chicken", "chicken thigh": "chicken", "chicken breast": "chicken", "chicken drumstick": "chicken",
    "whole chicken": "chicken", "egg": "egg", "egg white": "egg", "egg yolk": "egg", "ground beef": "ground-beef",
    "ground pork": "ground-pork", "pork belly": "bacon", "bacon": "bacon", "salmon": "fish", "shrimp": "shrimp",
    "tofu": "tofu", "spam": "canned-meat", "canned tuna": "canned-fish",
    "soy sauce": "soy-sauce", "tamari": "soy-sauce", "fish sauce": "fish-sauce", "oyster sauce": "oyster-sauce",
    "rice vinegar": "vinegar", "white vinegar": "vinegar", "apple cider vinegar": "cider-vinegar", "mirin": "mirin",
    "shaoxing wine": "rice-wine", "gochujang": "gochujang", "chili paste": "chili-paste", "sambal oelek": "chili-paste",
    "doubanjiang": "chili-paste", "chili crisp": "chili-paste", "doenjang": "doenjang", "miso": "miso",
    "peanut butter": "peanut-butter", "dijon mustard": "mustard", "ketchup": "ketchup", "mayonnaise": "mayonnaise",
    "honey": "honey", "maple syrup": "maple-syrup", "molasses": "molasses", "canned tomatoes": "canned-tomatoes",
    "tomato paste": "canned-tomatoes", "coconut milk": "coconut-milk", "chipotle pepper in adobo": "chipotle",
    "sugar": "sugar", "brown sugar": "brown-sugar", "chicken stock": "stock",
    "salt": "salt", "black pepper": "black-pepper", "black peppercorn": "black-pepper", "pepper": "black-pepper",
    "ground cumin": "spice", "cumin seed": "spice", "ground coriander": "spice", "coriander seed": "spice",
    "paprika": "red-spice", "smoked paprika": "red-spice", "chili powder": "red-spice", "gochugaru": "chili-flakes",
    "red pepper flakes": "chili-flakes", "garam masala": "brown-spice", "ground cinnamon": "brown-spice",
    "cinnamon stick": "cinnamon", "garlic powder": "pale-spice", "onion powder": "pale-spice", "ground ginger": "gold-spice",
    "dried basil": "dried-herb", "dried cilantro": "dried-herb", "dried oregano": "dried-herb", "dried parsley": "dried-herb",
    "dried thyme": "dried-herb", "vanilla extract": "vanilla",
    "cooked rice": "cooked-rice", "rice": "rice", "oats": "oats", "all-purpose flour": "flour", "panko": "flour",
    "spaghetti": "pasta", "linguine": "pasta", "penne": "pasta", "ditalini": "pasta", "udon": "noodles", "somen": "noodles",
    "ramen noodles": "noodles", "bread": "bread", "corn tortilla": "tortilla", "nori": "seaweed", "roasted seaweed": "seaweed",
    "butter": "butter", "parmesan": "cheese", "cheddar": "cheddar", "mozzarella": "fresh-cheese", "queso fresco": "fresh-cheese",
    "plain yogurt": "yogurt", "milk": "milk", "heavy cream": "cream", "oat milk": "plant-milk", "almond milk": "plant-milk",
    "neutral oil": "oil", "peanut oil": "oil", "olive oil": "olive-oil", "sesame oil": "sesame-oil",
    "kimchi": "kimchi", "kimchi juice": "kimchi", "cashew": "nut", "pistachio": "nut", "coconut": "coconut",
    "sesame seeds": "seeds", "black beans": "beans", "chickpeas": "chickpeas",
    "baking powder": "baking", "baking soda": "baking", "cornstarch": "cornstarch",
]

// MARK: - Checks against the dictionary

struct Entry: Decodable { let canonical_name: String; let category: String }
struct Dictionary: Decodable { let ingredients: [Entry] }

let dictionary = try JSONDecoder().decode(Dictionary.self, from: Data(contentsOf: dictionaryURL)).ingredients
let iconNames = Set(icons.map(\.0))
precondition(iconNames.count == icons.count, "duplicate icon names")
for (name, icon) in ingredientIcons {
    precondition(dictionary.contains { $0.canonical_name == name }, "\(name) is not in fixtures/ingredients.json")
    precondition(iconNames.contains(icon), "\(name) -> \(icon) has no drawing")
}
for (cat, icon) in categoryIcons { precondition(iconNames.contains(icon), "category \(cat) -> \(icon) has no drawing") }
for e in dictionary { precondition(categoryIcons[e.category] != nil, "category \(e.category) has no fallback icon") }

// MARK: - Write the asset catalog

let fm = FileManager.default
if fm.fileExists(atPath: assetDir.path) { try fm.removeItem(at: assetDir) }
try fm.createDirectory(at: assetDir, withIntermediateDirectories: true)
try """
{
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "provides-namespace" : true }
}

""".write(to: assetDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

var rendered: [(String, [Layer])] = []
for (name, parts) in icons {
    let layers = render(parts)
    rendered.append((name, layers))
    let set = assetDir.appendingPathComponent("\(name).imageset")
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    try svg(layers, dark: false, title: name).write(to: set.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
    try svg(layers, dark: true, title: name).write(to: set.appendingPathComponent("\(name)-dark.svg"), atomically: true, encoding: .utf8)
    try """
    {
      "images" : [
        { "filename" : "\(name).svg", "idiom" : "universal" },
        {
          "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
          "filename" : "\(name)-dark.svg",
          "idiom" : "universal"
        }
      ],
      "info" : { "author" : "xcode", "version" : 1 },
      "properties" : { "preserves-vector-representation" : true }
    }

    """.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

// MARK: - Write the mapping fixture

var mapping = "{\n  \"version\": 1,\n  \"note\": \"Generated by docs/brand/tools/umma-ingredient-icons.swift (brief 018). Do not edit by hand. icon: canonical_name -> asset name in Assets.xcassets/Ingredients; category: fallback per dictionary category; default: anything unmatched.\",\n  \"default\": \"basket\",\n  \"category\": {\n"
mapping += categoryIcons.keys.sorted().map { "    \"\($0)\": \"\(categoryIcons[$0]!)\"" }.joined(separator: ",\n")
mapping += "\n  },\n  \"icon\": {\n"
mapping += ingredientIcons.keys.sorted().map { "    \"\($0)\": \"\(ingredientIcons[$0]!)\"" }.joined(separator: ",\n")
mapping += "\n  }\n}\n"
try mapping.write(to: mappingURL, atomically: true, encoding: .utf8)

// MARK: - Write the review gallery

func usedBy(_ icon: String) -> [String] {
    var names = ingredientIcons.filter { $0.value == icon }.map(\.key)
    for e in dictionary where ingredientIcons[e.canonical_name] == nil && categoryIcons[e.category] == icon {
        names.append(e.canonical_name + " *")
    }
    return names.sorted()
}

var tiles = ""
for (name, layers) in rendered {
    let users = usedBy(name)
    let fallbackOf = categoryIcons.filter { $0.value == name }.map(\.key).sorted()
    tiles += """
    <figure class="tile"><div class="pair"><span class="light">\(svg(layers, dark: false, title: name, size: 56))</span><span class="dark">\(svg(layers, dark: true, title: name, size: 56))</span></div>
    <figcaption><b>\(name)</b>\(fallbackOf.isEmpty ? "" : "<i>fallback: \(fallbackOf.joined(separator: ", "))</i>")<span>\(users.isEmpty ? "—" : users.joined(separator: ", "))</span></figcaption></figure>

    """
}
var rows = ""
for item in ["chicken thigh", "garlic", "gochujang", "honey", "onion", "sesame oil", "egg", "cooked rice", "soy sauce", "scallion", "kimchi", "black pepper"] {
    let entry = dictionary.first { $0.canonical_name == item }!
    let icon = ingredientIcons[item] ?? categoryIcons[entry.category]!
    let layers = rendered.first { $0.0 == icon }!.1
    rows += "<div class=\"row\"><span class=\"light\">\(svg(layers, dark: false, title: icon, size: 28))</span><span class=\"dark\">\(svg(layers, dark: true, title: icon, size: 28))</span><div><div class=\"name\">\(item)</div><div class=\"sub\">Confirmed today</div></div></div>\n"
}

let gallery = """
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Umma Ingredient Icons</title>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bagel+Fat+One&family=Inter:wght@400;600&display=swap">
<style>
:root { --flesh:#FFF1E6; --surface:#FFFAF5; --seed:#2A1C14; --muted:#6E5A4E; --line:#EBD9CB; --leaf:#2F6B3A;
  --display:"Bagel Fat One", ui-rounded, system-ui, sans-serif; --text:"Inter", -apple-system, system-ui, sans-serif; color-scheme: light; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) { --flesh:#1B130E; --surface:#271C16; --seed:#F6E9DE; --muted:#C2AE9F; --line:#3C2E26; --leaf:#8ED39A; color-scheme: dark; } }
:root[data-theme="dark"] { --flesh:#1B130E; --surface:#271C16; --seed:#F6E9DE; --muted:#C2AE9F; --line:#3C2E26; --leaf:#8ED39A; color-scheme: dark; }
* { box-sizing:border-box } body { margin:0; background:var(--flesh); color:var(--seed); font:15px/1.5 var(--text) }
main { max-width:1200px; margin:0 auto; padding:40px max(20px, env(safe-area-inset-right,0px)) 64px max(20px, env(safe-area-inset-left,0px)) }
h1 { font:400 clamp(36px,6vw,60px)/1.05 var(--display); margin:0 } h2 { font:400 26px var(--display); margin:40px 0 12px }
p { max-width:66ch; color:var(--muted) }
.dark { display:none } :root[data-theme="dark"] .dark { display:inline-flex } :root[data-theme="dark"] .light { display:none }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) .dark { display:inline-flex } :root:not([data-theme="light"]) .light { display:none } }
.grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(150px, 1fr)); gap:12px }
.tile { margin:0; background:var(--surface); border:1px solid var(--line); border-radius:16px; padding:14px; display:flex; flex-direction:column; gap:8px }
.pair { display:flex; justify-content:center; padding-block:6px } .pair svg { width:56px; height:56px }
figcaption { font-size:12.5px; display:flex; flex-direction:column; gap:2px; min-width:0 } figcaption b { font-size:13.5px }
figcaption i { color:var(--leaf); font-style:normal; font-weight:600 } figcaption span { color:var(--muted); overflow-wrap:anywhere }
.list { max-width:420px; background:var(--surface); border:1px solid var(--line); border-radius:22px; padding:4px 16px }
.row { display:grid; grid-template-columns:36px 1fr; align-items:center; gap:12px; padding-block:10px; border-bottom:1px solid var(--line) } .row:last-child { border:0 }
.row svg { width:28px; height:28px } .name { font-weight:600 } .sub { font-size:12.5px; color:var(--muted) }
.bar button { font:600 13px var(--text); padding:7px 14px; border-radius:999px; border:1px solid var(--line); background:var(--surface); color:var(--seed); cursor:pointer }
.sizes { display:flex; gap:18px; align-items:end; flex-wrap:wrap } .sizes svg { display:block }
</style></head><body><main>
<h1>Ingredient icons</h1>
<p>Generated by <code>docs/brand/tools/umma-ingredient-icons.swift</code> (brief 018). \(rendered.count) icons, each with a light and a dark version, covering all \(dictionary.count) dictionary ingredients. Names marked * use their category's fallback icon. Detail lines are real holes, so the background shows through.</p>
<div class="bar"><button type="button" onclick="document.documentElement.setAttribute('data-theme','light')">Light</button> <button type="button" onclick="document.documentElement.setAttribute('data-theme','dark')">Dark</button> <button type="button" onclick="document.documentElement.removeAttribute('data-theme')">Match my system</button></div>
<h2>In a pantry list, at 28 pt</h2>
<div class="list">\(rows)</div>
<h2>Every icon</h2>
<div class="grid">\(tiles)</div>
</main></body></html>

"""
try gallery.write(to: galleryURL, atomically: true, encoding: .utf8)
print("\(rendered.count) icons, \(ingredientIcons.count) mapped ingredients, \(dictionary.count) in the dictionary")
