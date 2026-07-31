import Foundation

enum Lang: String, CaseIterable, Identifiable {
    case zh, en
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

/// 极简本地化：一张表，两列。
/// 切语言要即时生效，所以 T() 直接读 AppSettings.shared.language。
func T(_ key: String) -> String {
    let lang = AppSettings.shared.language
    guard let pair = strings[key] else {
        assertionFailure("缺翻译: \(key)")
        return key
    }
    return lang == .zh ? pair.0 : pair.1
}

private let strings: [String: (String, String)] = [
    "app.name":              ("StarFind", "StarFind"),
    "settings.title":        ("StarFind 设置", "StarFind Settings"),

    // 菜单栏
    "menu.search":           ("搜索…", "Search…"),
    "menu.settings":         ("设置…", "Settings…"),
    "menu.quit":             ("退出 StarFind", "Quit StarFind"),

    // 主菜单里的「编辑」。菜单栏上看不见（accessory app 不显示菜单栏），
    // 但 ⌘A / ⌘V / ⌘X / ⌘Z 全靠它派发。
    "menu.file":             ("文件", "File"),
    "menu.close":            ("关闭窗口", "Close Window"),
    "menu.edit":             ("编辑", "Edit"),
    "menu.undo":             ("撤销", "Undo"),
    "menu.redo":             ("重做", "Redo"),
    "menu.cut":              ("剪切", "Cut"),
    "menu.copy":             ("拷贝", "Copy"),
    "menu.paste":            ("粘贴", "Paste"),
    "menu.selectAll":        ("全选", "Select All"),

    // 面板
    "panel.placeholder":     ("搜索文件…", "Search files…"),
    "panel.hintTokens":      ("空格=都要含 · a|b=或 · !排除 · \"字面\" · *.mp3 · ext:jpg;png · image: · size:>10mb · dm:today · dir:~/x · content:全文",
                              "space=AND · a|b=OR · !exclude · \"literal\" · *.mp3 · ext:jpg;png · image: · size:>10mb · dm:today · dir:~/x · content:fulltext"),
    "panel.searching":       ("搜索中…", "Searching…"),
    "panel.noResults":       ("没有结果", "No results"),
    "panel.typeMore":        ("再多打几个字", "Type a bit more"),
    "panel.resultsCount":    ("个结果", "results"),
    "panel.needAccess":      ("⚠️ 还没有「%@」的访问权限 —— 那些位置的文件 Spotlight 不会回给 StarFind。⌘, 去设置里授权",
                              "⚠️ No access to %@ — Spotlight won't return files there to StarFind. Press ⌘, to grant it"),
    "panel.truncated":       ("（已截断）", "(truncated)"),

    // 底部动作条
    "key.open":              ("打开", "Open"),
    "key.reveal":            ("访达中显示", "Reveal in Finder"),
    "key.copyPath":          ("拷贝路径", "Copy Path"),
    "key.quickLook":         ("快速查看", "Quick Look"),
    "key.close":             ("关闭", "Close"),

    // 标签页
    "tab.search":            ("搜索", "Search"),
    "tab.appearance":        ("外观", "Appearance"),
    "tab.general":           ("通用", "General"),

    // 搜索页
    "scope.label":           ("搜索范围", "Search Scope"),
    "scope.home":            ("个人目录", "Home Folder"),
    "scope.computer":        ("整台电脑", "This Mac"),
    "scope.note":            ("整机会把系统文件也翻出来，一般用不上。",
                              "Searching the whole Mac surfaces system files you rarely want."),
    "search.filterNoise":    ("过滤噪音目录", "Filter Noisy Folders"),
    "search.filterNoiseNote": ("滤掉 Library / node_modules / 缓存 / 废纸篓这些。你要找的几乎总是自己的文件。",
                               "Hides Library, node_modules, caches and Trash. You're almost always looking for your own files."),
    "search.includeApps":    ("结果里包含应用程序", "Include Applications"),
    "search.maxResults":     ("最多显示", "Max Results"),
    "search.minQueryLength": ("最少输入字符", "Minimum Query Length"),
    "search.minQueryNote":   ("太短的关键词会匹配到几十万个文件，没有意义。",
                              "Very short queries match hundreds of thousands of files."),

    // 外观页
    "appearance.language":   ("界面语言", "Language"),
    "appearance.colorSection": ("配色", "Colors"),
    "preset.system":         ("跟随系统", "System"),
    "preset.dark":           ("深色", "Dark"),
    "preset.darker":         ("更深", "Darker"),
    "preset.black":          ("接近纯黑", "Near Black"),
    "appearance.mode":       ("明暗", "Light / Dark"),
    "appearance.system":     ("跟随系统", "System"),
    "appearance.light":      ("浅色", "Light"),
    "appearance.dark":       ("深色", "Dark"),
    "appearance.material":   ("毛玻璃材质", "Blur Material"),
    "appearance.materialNote": ("不同材质暗度差别很明显。「HUD」比 Spotlight 用的「侧边栏」深一档。",
                               "Materials differ a lot in darkness. HUD is a notch darker than the Sidebar material Spotlight uses."),
    "material.sidebar":      ("侧边栏（跟 Spotlight 一样）", "Sidebar (same as Spotlight)"),
    "material.hud":          ("HUD（更深）", "HUD (darker)"),
    "material.popover":      ("浮层", "Popover"),
    "material.underWindow":  ("窗口背景", "Under Window"),
    "material.fullScreen":   ("全屏 UI", "Full Screen UI"),
    "appearance.tintColor":  ("叠加颜色", "Tint Color"),
    "appearance.tintOpacity": ("叠加浓度", "Tint Strength"),
    "appearance.tintNote":   ("在毛玻璃上再盖一层色。浓度 0 就是纯系统外观；想更黑就把黑色的浓度拉高。",
                             "Paints a color over the blur. 0% is the plain system look — raise black to go darker."),
    "appearance.highlightColor": ("选中行颜色", "Selection Color"),
    "appearance.highlightOpacity": ("选中行浓度", "Selection Opacity"),
    "appearance.previewSelected": ("选中的这一行", "Selected row"),
    "appearance.previewNormal": ("普通的一行", "Normal row"),
    "appearance.showPreview": ("显示预览窗格", "Show Preview Pane"),
    "appearance.previewNote": ("右侧用系统「快速查看」渲染选中的文件。",
                               "Renders the selected file with the system Quick Look engine."),
    "appearance.panelWidth": ("面板宽度", "Panel Width"),
    "appearance.rowCount":   ("显示行数", "Visible Rows"),
    "appearance.defaultAction": ("回车时", "On Return"),
    "action.open":           ("打开文件", "Open File"),
    "action.reveal":         ("在访达中显示", "Reveal in Finder"),

    // 通用页 —— 文件访问权限
    "access.section":        ("文件访问权限", "File Access"),
    "access.desktop":        ("桌面", "Desktop"),
    "access.documents":      ("文稿", "Documents"),
    "access.downloads":      ("下载", "Downloads"),
    "access.granted":        ("已允许", "Granted"),
    "access.denied":         ("未授权", "Not granted"),
    "access.note":           ("⚠️ Spotlight 的结果是**按客户端权限过滤**的：没授权的目录，里面的普通文件不会回给 StarFind。",
                              "⚠️ Spotlight filters results by the requesting app's permissions: files in folders you haven't granted are never returned to StarFind at all (apps are the one exception). Without access, searching Documents only ever finds .app bundles."),
    "access.request":        ("请求访问", "Request Access"),
    "access.openSettings":   ("打开系统设置", "Open System Settings"),
    "access.deniedNote":     ("已经拒绝过的目录不会再弹框，要去「系统设置 → 隐私与安全性 → 文件与文件夹」里手动打开；想一次给全（含其它受保护位置）就给「完全磁盘访问权限」。",
                              "Folders you already denied won't prompt again — turn them on in System Settings → Privacy & Security → Files and Folders. Full Disk Access covers everything at once."),

    // 通用页
    "general.hotkey":        ("全局快捷键", "Global Hotkey"),
    "hotkey.toggleSearch":   ("唤起搜索面板", "Show Search Panel"),
    "hotkey.record":         ("点这里录制", "Click to record"),
    "hotkey.recording":      ("按下组合键…", "Press keys…"),
    "hotkey.clear":          ("清除", "Clear"),
    "hotkey.note":           ("必须带 ⌘ / ⌥ / ⌃ 之一，否则会把普通打字吃掉。默认是 ⌥Space。",
                              "Must include ⌘/⌥/⌃, otherwise it would swallow normal typing. Default is ⌥Space."),
    "general.spaceBehavior": ("切换桌面时", "When Switching Spaces"),
    "spaceBehavior.spotlight": ("Spotlight 式", "Spotlight Style"),
    "spaceBehavior.followAllSpaces": ("跟随所有桌面", "Follow Across Spaces"),
    "spaceBehavior.note":    ("Spotlight 式会在切换桌面时关闭面板；到了任何新桌面，按快捷键都会重新召唤。跟随模式会让已打开的面板一路留在最上层。",
                              "Spotlight Style closes the panel when you switch Spaces; invoke it again anywhere with the hotkey. Follow mode keeps an open panel with you across Spaces."),
    "general.launchAtLogin": ("开机自动启动", "Launch at Login"),
    "general.loginNote":     ("在「系统设置 → 通用 → 登录项」里也能关。",
                              "Can also be turned off in System Settings → General → Login Items."),
    "general.loginNeedsApproval": ("被系统拦下了，去登录项里批准一下。",
                                   "Blocked by macOS — approve it in Login Items."),
    "general.loginUnstable": ("⚠️ 当前是从 build 目录运行的。先 `make install` 装到 ~/Applications 再开自启，否则路径会失效。",
                              "⚠️ Running from the build folder. Run `make install` first, or the login item will point at a path that disappears."),
    "general.openLoginItems": ("打开登录项设置", "Open Login Items"),
    "general.rebuildIndex":  ("Spotlight 索引", "Spotlight Index"),
    "general.rebuildNote":   ("搜不到本该有的文件时，多半是 Spotlight 没索引到那个位置，去「系统设置 → Spotlight → 搜索隐私」看看。",
                              "If a file that should exist isn't found, Spotlight probably isn't indexing that location — check System Settings → Spotlight → Search Privacy."),
    "general.about":         ("StarFind 用的是系统 Spotlight 索引（跟 Raycast / Alfred 同一套），不自己建索引、不联网、无遥测。",
                              "StarFind queries the system Spotlight index (the same one Raycast and Alfred use). No index of its own, no network, no telemetry."),
]
