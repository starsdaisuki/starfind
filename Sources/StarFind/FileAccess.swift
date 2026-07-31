import Foundation
import AppKit

/// 受 TCC 保护的三个用户目录。
///
/// ⚠️⚠️ **Spotlight 的搜索结果是按客户端权限过滤的。**
/// 这跟「Spotlight 只回路径、不读内容，所以不需要授权」的直觉正好相反 ——
/// 同一个二进制、谓词和 scope 在不同授权下会返回不同结果。
/// 从终端直接运行时可能使用终端应用的权限上下文，而通过 `open`
/// 启动的 `.app` 使用 StarFind 自己的应用身份。
/// 如果可以搜到应用，却搜不到「桌面/文稿/下载」里的普通文件，
/// 首先检查 TCC 授权，不要把它误判成 Spotlight 索引损坏。
enum ProtectedFolder: String, CaseIterable, Identifiable {
    case desktop, documents, downloads

    var id: String { rawValue }

    var url: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .desktop:   return home.appendingPathComponent("Desktop")
        case .documents: return home.appendingPathComponent("Documents")
        case .downloads: return home.appendingPathComponent("Downloads")
        }
    }

    var localizedLabel: String {
        switch self {
        case .desktop:   return T("access.desktop")
        case .documents: return T("access.documents")
        case .downloads: return T("access.downloads")
        }
    }
}

enum FileAccess {

    /// 读一下目录列表。
    ///
    /// - 还没决定过 → **系统弹授权框**（这正是我们要的，用户点「允许」就好了）
    /// - 已允许 → 直接成功
    /// - 已拒绝 → 直接失败，不会再弹
    ///
    /// 用 `contentsOfDirectory` 而不是 `isReadableFile`：后者走 `access(2)`，
    /// 不触发 TCC，问不出真实状态。
    @discardableResult
    static func probe(_ folder: ProtectedFolder) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) != nil
    }

    /// 现在还缺哪几个目录的权限
    static func missing() -> [ProtectedFolder] {
        ProtectedFolder.allCases.filter { !probe($0) }
    }

    static var hasAllAccess: Bool { missing().isEmpty }

    /// 每次启动都探一遍。
    ///
    /// 不用「只问一次」的标志位，因为 TCC 自己就有正确的语义：
    /// **只有「还没决定过」才会弹框**，用户拒绝过的一声不吭地失败。
    /// 所以这样既不会骚扰拒绝过的人，又能在授权失效后自动补上 ——
    /// ad-hoc 签名的 app 每次 `make install` 二进制都变，TCC 授权会跟着失效，
    /// 只问一次的话重装之后就悄悄搜不到文稿了，而且完全看不出为什么。
    static func requestIfNeeded() {
        ProtectedFolder.allCases.forEach { probe($0) }
    }

    /// 设置里那个按钮：再请求一遍（已拒绝过的不会再弹，只能去系统设置改）
    static func requestAll() {
        ProtectedFolder.allCases.forEach { probe($0) }
    }

    /// 系统设置 → 隐私与安全性 → 文件与文件夹
    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
        NSWorkspace.shared.open(url)
    }
}
