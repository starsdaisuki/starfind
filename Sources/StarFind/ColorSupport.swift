import SwiftUI
import AppKit

/// 颜色存进 UserDefaults 用十六进制字符串，不用 NSKeyedArchiver ——
/// 前者 `defaults read` 能直接看懂、CLI 也能改，后者是一坨二进制。
enum HexColor {

    /// `#RRGGBB` / `RRGGBB` / `#RRGGBBAA` → NSColor。认不出返回 nil。
    static func nsColor(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }

        let hasAlpha = s.count == 8
        let r, g, b, a: CGFloat
        if hasAlpha {
            r = CGFloat((v >> 24) & 0xFF) / 255
            g = CGFloat((v >> 16) & 0xFF) / 255
            b = CGFloat((v >> 8) & 0xFF) / 255
            a = CGFloat(v & 0xFF) / 255
        } else {
            r = CGFloat((v >> 16) & 0xFF) / 255
            g = CGFloat((v >> 8) & 0xFF) / 255
            b = CGFloat(v & 0xFF) / 255
            a = 1
        }
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static func color(_ hex: String, fallback: Color) -> Color {
        guard let ns = nsColor(hex) else { return fallback }
        return Color(nsColor: ns)
    }

    /// NSColor → `#RRGGBB`（丢掉 alpha，透明度单独用 slider 存）
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded())
        let g = Int((c.greenComponent * 255).rounded())
        let b = Int((c.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    static func hex(_ color: Color) -> String {
        hex(NSColor(color))
    }
}

/// 面板毛玻璃材质。不同材质的暗度差别很明显 ——
/// 使用更深的材质比单纯调低透明度更自然。
enum PanelMaterial: String, CaseIterable, Identifiable {
    case sidebar          // 跟 Spotlight 最接近
    case hudWindow        // 明显更深
    case popover
    case underWindowBackground
    case fullScreenUI

    var id: String { rawValue }

    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .sidebar:               return .sidebar
        case .hudWindow:             return .hudWindow
        case .popover:               return .popover
        case .underWindowBackground: return .underWindowBackground
        case .fullScreenUI:          return .fullScreenUI
        }
    }

    var localizedLabel: String {
        switch self {
        case .sidebar:               return T("material.sidebar")
        case .hudWindow:             return T("material.hud")
        case .popover:               return T("material.popover")
        case .underWindowBackground: return T("material.underWindow")
        case .fullScreenUI:          return T("material.fullScreen")
        }
    }
}

/// 面板明暗。强制深色可以让面板在浅色系统主题下仍保持高对比度。
enum PanelAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .vibrantLight)
        case .dark:   return NSAppearance(named: .vibrantDark)
        }
    }

    var localizedLabel: String {
        switch self {
        case .system: return T("appearance.system")
        case .light:  return T("appearance.light")
        case .dark:   return T("appearance.dark")
        }
    }
}
