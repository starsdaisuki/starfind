import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = AppSettings.shared
    private let panelController = PanelController()
    private let hotkeys = HotkeyManager()

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ note: Notification) {
        // 自检模式：不起界面，跑完就退。`make test`
        if ProcessInfo.processInfo.environment["STARFIND_SELFTEST"] == "1" {
            SelfTest.run()
            return
        }
        // 打字模拟：`make type Q=关键词`，复现「引擎正常但界面 0 结果」
        if let q = ProcessInfo.processInfo.environment["STARFIND_TYPE"], !q.isEmpty {
            QueryDump.simulateTyping(q)
            return
        }
        // 查询诊断模式：`make query Q=关键词`，「搜不出来」时用
        if let q = ProcessInfo.processInfo.environment["STARFIND_QUERY"], !q.isEmpty {
            QueryDump.run(q)
            return
        }

        installMainMenu()
        setupStatusItem()

        // 真面板模拟：`make panel Q=关键词`，复现只在面板层出现的问题
        if let q = ProcessInfo.processInfo.environment["STARFIND_PANEL"], !q.isEmpty {
            QueryDump.simulatePanel(q, controller: panelController)
            return
        }

        // ⚠️ 没有这三个目录的权限，Spotlight **不会把那里的文件回给我们**
        // （只有 .app 例外）。搜不到自己文稿里的东西就是这么来的，见 FileAccess.swift。
        FileAccess.requestIfNeeded()

        hotkeys.onAction = { [weak self] action in
            switch action {
            case .toggleSearch: self?.panelController.toggle()
            }
        }
        hotkeys.reload(from: settings)

        NotificationCenter.default.addObserver(
            forName: .starFindHotkeysChanged, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.hotkeys.reload(from: self.settings)
        }

        NotificationCenter.default.addObserver(
            forName: .starFindOpenSettings, object: nil, queue: .main
        ) { [weak self] _ in self?.openSettings() }

        // 语言一变，菜单栏那几项也要跟着换
        settings.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.rebuildMenu() }
            .store(in: &bag)

        // 没设快捷键的话（用户自己清掉了）第一次启动直接把面板弹出来，
        // 否则这个 app 看起来像没反应
        if settings.hotkeys[HotkeyAction.toggleSearch.rawValue] == nil {
            panelController.show()
        }
    }

    // MARK: 主菜单（⌘A / ⌘V / ⌘X / ⌘Z 全靠它）

    /// ⚠️ **文本编辑快捷键不是 NSTextView 自带的**，是主菜单里「编辑」那几项的
    /// key equivalent —— `NSApplication.sendEvent` 拿到带 ⌘ 的 keyDown 时，
    /// 先问 `NSApp.mainMenu.performKeyEquivalent(_:)`，才轮到窗口和响应链。
    ///
    /// 这个 app 一直没建过 `NSApp.mainMenu`（只有状态栏那个 `statusItem.menu`，
    /// 那个不参与 key equivalent 派发），所以搜索框里 ⌘A 全选、⌘V 粘贴、⌘X 剪切、
    /// ⌘Z 撤销**一个都不灵**。不是被面板的 local monitor 截掉的 —— monitor 对这几个键
    /// 一律 `return false` 放行，只是放行之后根本没人接。
    ///
    /// LSUIElement（accessory）app 永远不显示菜单栏，但 key equivalent 照样派发，
    /// 所以补一个「看不见的主菜单」就够了，界面上不会多出任何东西。
    ///
    /// **故意不放 Quit ⌘Q**：面板弹出时 StarFind 是激活状态，放了的话在别的 app 上
    /// 按 ⌘Q 会把 StarFind 自己关掉。退出走菜单栏图标那一项。
    private func installMainMenu() {
        NSApp.mainMenu = AppDelegate.makeMainMenu(settingsTarget: self,
                                                  settingsAction: #selector(openSettings))
    }

    /// 抽成静态方法是为了能在 `make test` 里直接量 —— 「菜单里有没有那几项、
    /// 键位对不对」不需要起界面就能验。
    static func makeMainMenu(settingsTarget: AnyObject?, settingsAction: Selector?) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let prefs = NSMenuItem(title: T("menu.settings"), action: settingsAction, keyEquivalent: ",")
        prefs.target = settingsTarget
        appMenu.addItem(prefs)
        appItem.submenu = appMenu
        main.addItem(appItem)

        // ⌘W 关窗口。跟 ⌘A 一样，它也是主菜单的 key equivalent ——
        // 没有主菜单的时候设置窗口只能用鼠标点左上角红点关，键盘关不掉。
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: T("menu.file"))
        let close = NSMenuItem(title: T("menu.close"),
                               action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        close.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(close)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: T("menu.edit"))
        // target 全部留 nil = 走响应链，谁是 firstResponder 谁接（搜索框 / 设置窗口都行）
        for (title, action, key, mods) in editEntries {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = mods
            editMenu.addItem(item)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        return main
    }

    static var editEntries: [(String, Selector, String, NSEvent.ModifierFlags)] {
        [
            // undo: / redo: 在 AppKit 里没有公开的 Swift 符号（UndoManager.undo() 不带冒号，
            // 不是菜单要的那个 action），只能按名字取
            (T("menu.undo"),      NSSelectorFromString("undo:"),   "z", [.command]),
            (T("menu.redo"),      NSSelectorFromString("redo:"),   "z", [.command, .shift]),
            (T("menu.cut"),       #selector(NSText.cut(_:)),       "x", [.command]),
            (T("menu.copy"),      #selector(NSText.copy(_:)),      "c", [.command]),
            (T("menu.paste"),     #selector(NSText.paste(_:)),     "v", [.command]),
            (T("menu.selectAll"), #selector(NSText.selectAll(_:)), "a", [.command]),
        ]
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "sparkle.magnifyingglass",
            accessibilityDescription: "StarFind"
        ) ?? NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "StarFind")
        item.button?.image?.isTemplate = true
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let search = NSMenuItem(title: T("menu.search"), action: #selector(showPanel), keyEquivalent: "")
        search.target = self
        menu.addItem(search)

        menu.addItem(.separator())

        let prefs = NSMenuItem(title: T("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: T("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    @objc private func showPanel() { panelController.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: 设置窗口

    @objc func openSettings() {
        if let w = settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }

        // ⚠️ 先建窗口再塞 NSHostingView，尺寸写死。
        // 早先用 NSWindow(contentViewController:) 再改 styleMask，内容会被重置成 0 高
        // —— 现象是「设置窗口打开是空的」。SelfTest 里量 fittingSize 那三项就是防这个。
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsView.contentSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: SettingsView())
        host.frame = NSRect(origin: .zero, size: SettingsView.contentSize)
        host.autoresizingMask = [.width, .height]
        w.contentView = host
        w.title = T("settings.title")
        w.isReleasedWhenClosed = false
        w.setContentSize(SettingsView.contentSize)
        w.center()
        settingsWindow = w

        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}
