import AppKit
import SwiftUI
import Carbon.HIToolbox

/// 无边框面板。NSPanel 默认不肯当 key window，必须覆写这两个属性，
/// 否则输入框拿不到键盘。
final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 用户对面板的显示意图。不能拿 `NSWindow.isVisible` 充当这个状态：
/// Space 动画期间窗口的 visible / key / activeSpace 都会短暂抖动，但每次热键必须
/// 稳定地翻转一次意图，不能让迟到的 AppKit 通知吞掉较新的按键。
struct PanelVisibilityIntent {
    private(set) var wantsVisible = false

    mutating func toggle() -> Bool {
        wantsVisible.toggle()
        return wantsVisible
    }

    mutating func show() { wantsVisible = true }
    mutating func hide() { wantsVisible = false }
}

/// 面板的显示 / 隐藏 / 定位 / 按键。
final class PanelController: NSObject {

    let vm = SearchViewModel()

    private var panel: SearchPanel?
    private var hosting: NSHostingView<SearchView>?
    private var focusToken = 0
    private var previousApp: NSRunningApplication?
    private var localMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var visibilityIntent = PanelVisibilityIntent()
    private var presentationRevision = 0
    private var activeSpaceRevision = 0
    private var lastActiveSpaceChange = Date.distantPast
    private var pendingPresentation: DispatchWorkItem?
    private var pendingResign: DispatchWorkItem?
    /// 面板顶边的固定位置。结果变多变少时向下长，搜索框不能跟着跳。
    private var anchorTopY: CGFloat = 0

    private var settings: AppSettings { .shared }

    var isVisible: Bool { panel?.isVisible ?? false }

    override init() {
        super.init()
        vm.onRequestClose = { [weak self] restoreFocus in self?.hide(restoreFocus: restoreFocus) }
        vm.onResultsChanged = { [weak self] in self?.applyHeight() }

        // 跟随模式里，Space 切换只改变窗口落在哪个桌面，不能改变最后一次热键意图。
        // Spotlight 模式则结束旧 Space 的会话，但不能误关切换途中已在新 Space 的召唤。
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.activeSpaceRevision += 1
            self.lastActiveSpaceChange = Date()
            self.pendingResign?.cancel()
            self.pendingResign = nil

            if self.settings.panelSpaceBehavior == .spotlight {
                // 如果热键恰好在 Space 动画末尾触发，窗口已经属于新的活动 Space；
                // 这是一场更新的召唤，不能被迟到的 activeSpaceDidChange 关掉。
                let isNewPresentationOnActiveSpace = self.visibilityIntent.wantsVisible
                    && self.panel?.isVisible == true
                    && self.panel?.isOnActiveSpace == true
                    && self.panel?.isKeyWindow == true
                if !isNewPresentationOnActiveSpace {
                    self.visibilityIntent.hide()
                    self.conceal(restoreFocus: false)
                }
            } else if self.visibilityIntent.wantsVisible {
                self.schedulePresentation(after: .milliseconds(80), force: true)
            } else if self.panel?.isVisible == true {
                self.dismiss(restoreFocus: false)
            }
        }
    }

    deinit {
        pendingPresentation?.cancel()
        pendingResign?.cancel()
        removeMonitors()
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
        }
    }

    // MARK: 显示 / 隐藏

    func toggle() {
        visibilityIntent.toggle() ? presentFromUserIntent() : conceal(restoreFocus: true)
    }

    func show() {
        visibilityIntent.show()
        presentFromUserIntent()
    }

    /// `restoreFocus: false` = 别把焦点还给原来那个 app。
    /// 打开 / 在访达中显示之后必须这样，否则刚跳过去的 Finder 又被抢回来 ——
    /// 表现为「Finder 开了，但你还停在原来那个全屏桌面上」。
    func hide(restoreFocus: Bool = true) {
        visibilityIntent.hide()
        conceal(restoreFocus: restoreFocus)
    }

    private func presentFromUserIntent() {
        presentationRevision += 1
        pendingPresentation?.cancel()
        pendingResign?.cancel()
        pendingResign = nil
        previousApp = nil
        presentOnActiveSpace()
        // 热键可能正好落在 Space 动画中间。下一小拍再核对一次，若 WindowServer
        // 随后把窗口甩回旧 Space / 撤掉 key，就重挂；新的热键会通过 revision 取消它。
        schedulePresentation(after: .milliseconds(180), force: false)
    }

    private func presentOnActiveSpace() {
        guard visibilityIntent.wantsVisible else { return }
        pendingResign?.cancel()
        pendingResign = nil
        let panel = ensurePanel()
        applySpaceBehavior(to: panel)

        // 即使 WindowServer 仍说 visible，也先 order out，确保这次 order in 归属当前 Space。
        if panel.isVisible {
            removeMonitors()
            panel.orderOut(nil)
        }

        // 记住当前桌面的前台 app，关掉面板时还回去。
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }

        focusToken += 1
        rebuildRootView()
        // 明暗每次显示都重新套一遍，设置里改完不用重启
        panel.appearance = settings.panelAppearance.nsAppearance
        position(panel)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // 对 accessory app 的 nonactivatingPanel，Space 切换后的普通 orderFront 偶尔会
        // 被当前前台 app 压住。这个 API 专门保证窗口无视 app 激活顺序来到最前。
        panel.orderFrontRegardless()
        installMonitors(panel)
    }

    private func applySpaceBehavior(to panel: SearchPanel) {
        let common: NSWindow.CollectionBehavior = [
            .fullScreenAuxiliary, .transient, .ignoresCycle
        ]
        switch settings.panelSpaceBehavior {
        case .spotlight:
            panel.collectionBehavior = common.union(.moveToActiveSpace)
        case .followAllSpaces:
            panel.collectionBehavior = common.union(.canJoinAllSpaces)
        }
    }

    private func schedulePresentation(after delay: DispatchTimeInterval, force: Bool) {
        pendingPresentation?.cancel()
        let revision = presentationRevision
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.visibilityIntent.wantsVisible,
                  self.presentationRevision == revision else { return }

            let isStable = self.panel.map {
                $0.isVisible && $0.isOnActiveSpace && $0.isKeyWindow
            } ?? false
            if force || !isStable {
                self.presentOnActiveSpace()
            }
        }
        pendingPresentation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func conceal(restoreFocus: Bool) {
        presentationRevision += 1
        pendingPresentation?.cancel()
        pendingPresentation = nil
        pendingResign?.cancel()
        pendingResign = nil
        dismiss(restoreFocus: restoreFocus)
    }

    private func dismiss(restoreFocus: Bool) {
        removeMonitors()
        panel?.orderOut(nil)
        vm.reset()
        // 还回焦点。不还的话按 Esc 之后键盘会飘在一个没有窗口的 app 上。
        if restoreFocus,
           let prev = previousApp,
           prev.bundleIdentifier != Bundle.main.bundleIdentifier {
            prev.activate()
        }
        previousApp = nil
    }

    // MARK: 构建

    private func ensurePanel() -> SearchPanel {
        if let panel { return panel }

        let p = SearchPanel(
            contentRect: NSRect(x: 0, y: 0, width: settings.panelWidth, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.animationBehavior = .utilityWindow
        applySpaceBehavior(to: p)

        let host = NSHostingView(rootView: makeRootView())
        host.autoresizingMask = [.width, .height]
        p.contentView = host

        hosting = host
        panel = p
        return p
    }

    private func makeRootView() -> SearchView {
        SearchView(vm: vm, focusToken: focusToken)
    }

    private func rebuildRootView() {
        hosting?.rootView = makeRootView()
    }

    // MARK: 定位与尺寸

    private func position(_ panel: SearchPanel) {
        let screen = screenUnderMouse()
        let vf = screen.visibleFrame
        let width = CGFloat(settings.panelWidth)
        let height = SearchView.contentHeight(vm: vm, settings: settings)

        // 顶边落在可视区往下 16% 处 —— 跟 Spotlight 的位置感接近
        anchorTopY = vf.maxY - vf.height * 0.16
        let origin = NSPoint(x: (vf.midX - width / 2).rounded(), y: (anchorTopY - height).rounded())
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)),
                       display: true, animate: false)
        panel.invalidateShadow()
    }

    /// 结果数变了就改高度。**不做动画** —— 每敲一个字都动一次会晕。
    private func applyHeight() {
        guard let panel, panel.isVisible else { return }
        let width = CGFloat(settings.panelWidth)
        let height = SearchView.contentHeight(vm: vm, settings: settings)
        let frame = panel.frame
        guard abs(frame.height - height) > 0.5 || abs(frame.width - width) > 0.5 else { return }
        panel.setFrame(NSRect(x: frame.origin.x, y: anchorTopY - height, width: width, height: height),
                       display: true, animate: false)
        panel.invalidateShadow()
    }

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    // MARK: 按键

    /// 用 local event monitor 而不是 NSTextField 的 doCommandBy ——
    /// 后者只能拿到编辑相关的 selector，拿不到 ⌘↩ / ⌘C 这种带修饰键的组合。
    private func installMonitors(_ panel: SearchPanel) {
        removeMonitors()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            return self.handle(event) ? nil : event
        }

        // 真正点到别处 / 切走 app 要收起来，但 Space 动画也会发 didResignKey。
        // 延迟判别：期间若收到 activeSpaceDidChange，就保留用户显示意图并在新 Space 重挂。
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, self.isVisible, self.visibilityIntent.wantsVisible else { return }

            self.pendingResign?.cancel()
            let presentationRevision = self.presentationRevision
            let spaceRevision = self.activeSpaceRevision
            let resignedNearSpaceChange =
                Date().timeIntervalSince(self.lastActiveSpaceChange) < 0.75
            let work = DispatchWorkItem { [weak self] in
                guard let self,
                      self.visibilityIntent.wantsVisible,
                      self.presentationRevision == presentationRevision,
                      self.panel?.isVisible == true,
                      self.panel?.isKeyWindow == false else { return }

                let spaceChangedAfterResign = self.activeSpaceRevision != spaceRevision
                if spaceChangedAfterResign || resignedNearSpaceChange {
                    self.schedulePresentation(after: .milliseconds(40), force: true)
                } else {
                    self.visibilityIntent.hide()
                    self.conceal(restoreFocus: false)
                }
            }
            self.pendingResign = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(550), execute: work)
        }
    }

    // MARK: 诊断（`make panel`）

    /// 面板里那个正在编辑的 NSTextView。诊断模式往它 `insertText` 就等于真的敲键盘 ——
    /// 走的是 NSTextField delegate → SwiftUI binding → ViewModel 整条真实链路。
    var diagnosticFieldEditor: NSTextView? { panel?.firstResponder as? NSTextView }
    var diagnosticPanel: NSPanel? { panel }

    /// 诊断模式模拟一次按键（走 local monitor，跟真按键同一条路）
    func diagnosticSend(_ event: NSEvent) -> Bool { handle(event) }

    private func removeMonitors() {
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o); resignObserver = nil }
    }

    /// 输入法正在组字（有 marked text / 候选框开着）。
    ///
    /// ⚠️ 组字期间 ↑↓ 是翻候选、↩ 是上屏、⎋ 是取消组字、数字键是选候选 ——
    /// 这些**必须让给输入法**。local monitor 拿到 keyDown 比输入法更早，
    /// 不判断就会把「按回车上屏」整个吃掉：中文输入法组字时按回车会没反应。
    private var isComposing: Bool {
        guard let editor = panel?.firstResponder as? NSTextView else { return false }
        return editor.hasMarkedText()
    }

    /// 搜索框里当前选中了文字（多半是刚按了 ⌘A）
    private var hasSelectedText: Bool {
        guard let editor = panel?.firstResponder as? NSTextView else { return false }
        return editor.selectedRange().length > 0
    }

    private func handle(_ event: NSEvent) -> Bool {
        if isComposing { return false }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let cmd = flags.contains(.command)

        switch Int(event.keyCode) {
        case kVK_Escape:
            hide(); return true

        case kVK_DownArrow:
            cmd ? vm.moveToEdge(true) : vm.move(1); return true

        case kVK_UpArrow:
            cmd ? vm.moveToEdge(false) : vm.move(-1); return true

        case kVK_PageDown:
            vm.move(settings.rowCount); return true

        case kVK_PageUp:
            vm.move(-settings.rowCount); return true

        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard vm.selectedHit != nil else { return true }
            vm.activate(alternate: cmd)
            return true

        case kVK_ANSI_C where cmd:
            // ⌘C 拷路径，⌘⇧C 拷文件本身（能直接粘到访达里）。
            // 但如果用户刚 ⌘A 全选了搜索词，那这一下 ⌘C 显然是想拷那段文字 ——
            // 放行给主菜单的「拷贝」，别把它变成拷路径。
            if !flags.contains(.shift), hasSelectedText { return false }
            flags.contains(.shift) ? vm.copyFile() : vm.copyPath()
            return true

        case kVK_ANSI_W where cmd:
            // ⌘W 在面板上等同于关面板。
            // ⚠️ 不能放给主菜单的 performClose: —— 这个面板是 borderless、没有关闭按钮，
            // performClose: 遇到关不掉的窗口会**响一声系统提示音**，很难受。
            hide(); return true

        case kVK_ANSI_Comma where cmd:
            hide()
            NotificationCenter.default.post(name: .starFindOpenSettings, object: nil)
            return true

        default:
            return false
        }
    }
}

extension Notification.Name {
    static let starFindOpenSettings = Notification.Name("starFindOpenSettings")
}
