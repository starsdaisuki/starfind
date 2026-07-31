import Foundation
import AppKit

/// 命令行诊断：`make query Q=report`
///
/// 「搜不出来」时用它，一次看清整条链的每一步：
/// 解析出什么谓词 → Spotlight 报了多少条 → 噪音过滤砍掉哪些 → 最后排序结果。
/// 面板上只能看到「0/12 个结果」，看不出 12 是哪 12 条、为什么全没了。
enum QueryDump {

    static func short(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    /// 模拟「一个字一个字打进去」，走真实的 SearchViewModel + 防抖 + 反复重启 query。
    /// `make type Q=report`
    ///
    /// 面板 bug（引擎单独跑正常、UI 上却 0 结果）只能在这一层复现。
    static func simulateTyping(_ raw: String) {
        setvbuf(stdout, nil, _IONBF, 0)
        print("\n════ StarFind 打字模拟 ════")
        let vm = SearchViewModel()
        var log: [String] = []
        vm.onResultsChanged = {
            log.append("      → results=\(vm.results.count) total=\(vm.totalCount) searching=\(vm.isSearching)")
        }

        let chars = Array(raw)
        for i in 1...chars.count {
            let partial = String(chars[0..<i])
            log = []
            vm.queryText = partial
            // 每个字之间 130ms —— 刚好越过 120ms 防抖，最接近真实打字
            RunLoop.current.run(until: Date().addingTimeInterval(0.13))
            print("  「\(partial)」")
            log.forEach { print($0) }
        }

        print("\n  停手，等它收工……")
        let deadline = Date().addingTimeInterval(10)
        var settled = 0
        while Date() < deadline {
            log = []
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            if log.isEmpty { settled += 1; if settled >= 4 { break } } else { settled = 0; log.forEach { print($0) } }
        }

        print("\n  最终：results=\(vm.results.count) total=\(vm.totalCount) searching=\(vm.isSearching)")
        if let first = vm.selectedHit { print("  第一条：\(first.path)") }
        if vm.results.isEmpty && vm.totalCount > 0 {
            print("  ❌ 复现了：Spotlight 有 \(vm.totalCount) 条命中，但 UI 层拿到 0 条")
        } else if vm.results.isEmpty {
            print("  ❌ 复现了：连 total 都是 0")
        } else {
            print("  ✅ 正常")
        }
        print("")
        exit(vm.results.isEmpty ? 1 : 0)
    }

    /// 真面板模拟：`make panel Q=starfind`
    ///
    /// `simulateTyping` 只跑到 SearchViewModel，跑不到面板那一层。
    /// 「引擎和 make type 都是 5 条、面板上却停在 3 条」这种只能在这里复现 ——
    /// 它把面板真的显示出来，往真实的字段编辑器里一个字一个字 insertText，
    /// 走的是 NSTextField delegate → SwiftUI binding → ViewModel 的完整链路，
    /// 通知也在同一个跑着 SwiftUI 渲染的主 runloop 上派发。
    static func simulatePanel(_ raw: String, controller: PanelController) {
        setvbuf(stdout, nil, _IONBF, 0)
        print("\n════ StarFind 真面板模拟 ════")
        if !SearchEngine.traceEnabled { print("（想看 Spotlight 通知时间线：STARFIND_TRACE=1 make panel Q=…）") }

        let vm = controller.vm

        // ⚠️ 基准查两次：刚启动一次、跑完一次。
        // 实测过「同一个进程里，刚启动那次少几条、几秒后再查就全了」——
        // Spotlight 对刚起来的客户端做权限判定要一会儿。两个数不一样就得往这个方向查，
        // 别再怀疑排序或过滤。
        let truthEarly = groundTruth(raw)
        print("  启动瞬间基准：\(truthEarly.count) 条")

        controller.show()
        spin(0.5)

        guard let editor = controller.diagnosticFieldEditor else {
            print("❌ 面板起来了但拿不到输入框 —— 焦点没进 NSTextField"); exit(1)
        }
        print("  面板已显示，输入框拿到焦点 ✓\n")

        for ch in raw {
            editor.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
            spin(0.09)   // 90ms/字 ≈ 正常打字速度，比防抖 120ms 短
            print("  「\(vm.queryText)」 → results=\(vm.results.count) total=\(vm.totalCount) searching=\(vm.isSearching)")
        }

        print("\n  停手，盯 5 秒看它还会不会变……")
        var last = (vm.results.count, vm.totalCount, vm.isSearching)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            spin(0.2)
            let now = (vm.results.count, vm.totalCount, vm.isSearching)
            if now != last {
                print("    ↻ results=\(now.0) total=\(now.1) searching=\(now.2)")
                last = now
            }
        }

        print("\n  面板上真正显示的 \(vm.results.count) 行：")
        for (i, hit) in vm.results.enumerated() {
            print(String(format: "   %2d. %5d  %@", i + 1, hit.score, hit.path))
        }
        print("  底部计数条：\(vm.totalCount > vm.results.count ? "\(vm.results.count)/\(vm.totalCount)" : "\(vm.results.count)") 个结果")

        // 跟干净引擎的结果对一遍 —— 不一致就是面板层把结果吃掉了。
        // ⚠️ 必须在快捷键那一节**之前**比，⌘C 那一下会关掉面板、把 vm 清空。
        let truth = groundTruth(raw)
        let shown = Set(vm.results.map(\.path))
        let missing = truth.filter { !shown.contains($0) }
        print("\n  引擎直查（同进程、同谓词）：启动瞬间 \(truthEarly.count) 条 → 现在 \(truth.count) 条")
        if truthEarly.count != truth.count {
            print("  ⚠️ 两次基准不一样 —— 是「刚启动时权限还没判定完」，不是排序/过滤的锅")
        }
        if missing.isEmpty {
            print("  ✅ 面板显示的和引擎查到的一致")
        } else {
            print("  ❌ 面板少了 \(missing.count) 条")
            missing.forEach { print("       · \($0)") }
            let blocked = missing.filter { path in
                FileAccess.missing().contains { path.hasPrefix($0.url.path + "/") || path == $0.url.path }
            }
            if !blocked.isEmpty {
                print("  → 其中 \(blocked.count) 条在**没授权**的目录里，"
                      + "Spotlight 不会把它们回给这个身份（见 FileAccess.swift）。这不是代码 bug。")
            }
            print("  → 当前缺权限的目录：" + (FileAccess.missing().map(\.rawValue).joined(separator: ", ")
                                             .isEmpty ? "无" : FileAccess.missing().map(\.rawValue).joined(separator: ", ")))
        }

        checkEditingShortcuts(controller: controller, typed: raw)
        let closeOK = checkSettingsCloseShortcut()
        print("")
        exit(missing.isEmpty && closeOK ? 0 : 1)
    }

    /// 真面板里实测编辑快捷键。
    ///
    /// ⌘A / ⌘V / ⌘X / ⌘Z 靠的是 `NSApp.mainMenu` 的 key equivalent；
    /// 这个 app 以前根本没建过主菜单，所以搜索框里一个都不灵。
    /// 这里把真的 ⌘A 键盘事件按 AppKit 的派发顺序走一遍，看光标是不是真选中了整段词
    /// —— 不看菜单里「有没有那一项」，看**按下去有没有效果**。
    ///
    /// ⚠️ 故意不测 ⌘C / ⌘V 的实际拷贝：那会往系统剪贴板里写东西，
    /// 污染用户的剪贴板历史（Maccy 会记一条）。⌘C 只验「有选中文字时放行给菜单」。
    private static func checkEditingShortcuts(controller: PanelController, typed: String) {
        print("\n  ── 编辑快捷键（⌘A / ⌘C）──")
        guard let panel = controller.diagnosticPanel,
              let editor = controller.diagnosticFieldEditor else {
            print("  ⚠️ 拿不到面板，跳过"); return
        }

        func key(_ ch: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                             timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: panel.windowNumber, context: nil,
                             characters: ch, charactersIgnoringModifiers: ch,
                             isARepeat: false, keyCode: code)
        }

        editor.setSelectedRange(NSRange(location: typed.count, length: 0))
        print("  输入框里现在是「\(editor.string)」，光标在 \(editor.selectedRange().location)")

        // 对照组：直接调 selectAll: —— 分清「菜单派发没到」还是「选中读不出来」
        editor.selectAll(nil)
        print("  直接调 selectAll(nil)：选中 \(editor.selectedRange().length) 字")
        editor.setSelectedRange(NSRange(location: typed.count, length: 0))

        // 从终端直接跑起来的进程不一定拿得到活动状态；key equivalent 要走
        // keyWindow 的响应链，所以这里明确把面板顶成 key window 再测。
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        for _ in 0..<10 where !panel.isKeyWindow { spin(0.1) }

        print("  NSApp.isActive=\(NSApp.isActive)  面板是 key window=\(panel.isKeyWindow)"
              + "  NSApp.keyWindow=\(NSApp.keyWindow === panel ? "就是面板" : String(describing: NSApp.keyWindow))")
        let viaSendAction = NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        print("  走响应链 sendAction(selectAll:)：接手=\(viaSendAction) 选中 \(editor.selectedRange().length) 字")
        editor.setSelectedRange(NSRange(location: typed.count, length: 0))

        // ⌘A：面板的 local monitor 先看（应该放行），再交给主菜单
        guard let cmdA = key("a", 0, .command) else { print("  ⚠️ 造不出事件"); return }
        let swallowedA = controller.diagnosticSend(cmdA)
        let menuHandledA = NSApp.mainMenu?.performKeyEquivalent(with: cmdA) ?? false
        let selected = editor.selectedRange().length
        print("  ⌘A：面板截键=\(swallowedA ? "是" : "否")  主菜单接手=\(menuHandledA ? "是" : "否")  选中字数=\(selected)/\(typed.count)")
        print(selected == typed.count ? "  ✅ ⌘A 全选生效" : "  ❌ ⌘A 没选中东西")

        // ⌘C：只有真的选中了才测 —— 没选中的话这一下会真的拷路径进剪贴板
        guard selected > 0, let cmdC = key("c", 8, .command) else {
            print("  ⌘C：跳过（没选中，测了会污染剪贴板）"); return
        }
        let swallowedC = controller.diagnosticSend(cmdC)
        print("  ⌘C（有选中文字）：面板截键=\(swallowedC ? "是" : "否")")
        print(swallowedC ? "  ❌ 还是被拿去拷路径了" : "  ✅ 放行给「拷贝文字」")
        editor.setSelectedRange(NSRange(location: typed.count, length: 0))
    }

    /// 真的把设置窗口打开，再真的按一下 ⌘W，看它关没关掉。
    ///
    /// ⚠️ 「菜单里有 ⌘W 这一项」**不等于**「按下去关得掉」——
    /// 这一条必须走 `NSApp.mainMenu.performKeyEquivalent` → 响应链 → `performClose:`
    /// 整条路才算验过。而且**必须用 `open` 启动**才有 key window（见本文件上面的注释）。
    @discardableResult
    private static func checkSettingsCloseShortcut() -> Bool {
        print("\n  ── 设置窗口 ⌘W ──")
        // 直接调，不走通知 —— 诊断模式在 AppDelegate 里是提前 return 的，
        // `.starFindOpenSettings` 的监听器那时候还没注册上
        (NSApp.delegate as? AppDelegate)?.openSettings()
        spin(0.6)

        guard let win = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else {
            print("  ⚠️ 设置窗口没起来，跳过"); return true
        }
        win.makeKeyAndOrderFront(nil)
        spin(0.3)
        print("  设置窗口已打开：「\(win.title)」 key=\(win.isKeyWindow)")

        guard let cmdW = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
            context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: 13) else { return true }

        let handled = NSApp.mainMenu?.performKeyEquivalent(with: cmdW) ?? false
        spin(0.4)
        let closed = !win.isVisible
        print("  ⌘W：主菜单接手=\(handled ? "是" : "否")  窗口还开着=\(win.isVisible ? "是" : "否")")
        print(closed ? "  ✅ ⌘W 真的把设置窗口关掉了" : "  ❌ 按了没关掉")
        return closed
    }

    /// 干净起一个 query 跑到底，当作「应该显示什么」的基准
    private static func groundTruth(_ raw: String) -> [String] {
        let parsed = ParsedQuery.parse(raw)
        guard let predicate = parsed.buildPredicate(includeApps: AppSettings.shared.includeApps) else { return [] }
        let q = NSMetadataQuery()
        q.predicate = predicate
        q.searchScopes = [AppSettings.shared.scope.metadataScope]
        var finished = false
        let o = NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in finished = true }
        q.start()
        let deadline = Date().addingTimeInterval(10)
        while !finished && Date() < deadline { spin(0.05) }
        spin(0.4)   // 收工后再等一拍，让迟到的那批也进来
        q.disableUpdates()
        var out: [String] = []
        for i in 0..<q.resultCount {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let p = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if AppSettings.shared.filterNoise && SearchEngine.isNoise(p) { continue }
            out.append(SearchEngine.canonicalize(p))
        }
        q.enableUpdates()
        q.stop()
        NotificationCenter.default.removeObserver(o)
        return out
    }

    /// 转主 runloop（NSApp 已经 run 起来了，这里只是让出时间片）
    private static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    static func run(_ raw: String) {
        setvbuf(stdout, nil, _IONBF, 0)
        let s = AppSettings.shared
        let parsed = ParsedQuery.parse(raw)
        let engine = SearchEngine()

        print("\n════ StarFind 查询诊断 ════")
        print("输入        : \(raw)")
        let groups = parsed.groups.map { $0.map(\.text).joined(separator: "|") }
        var parts: [String] = ["AND组=" + (groups.isEmpty ? "（空）" : groups.joined(separator: " + "))]
        if !parsed.excluded.isEmpty { parts.append("排除=" + parsed.excluded.map(\.text).joined(separator: ",")) }
        if let c = parsed.content { parts.append("content=" + c) }
        if !parsed.extensions.isEmpty { parts.append("ext=" + parsed.extensions.joined(separator: ";")) }
        if let d = parsed.dir { parts.append("dir=" + d) }
        if let k = parsed.kind { parts.append("kind=" + k.rawValue) }
        if parsed.onlyFolders { parts.append("只要文件夹") }
        if parsed.onlyFiles { parts.append("只要文件") }
        if parsed.size != nil { parts.append("size 有筛选") }
        if let dt = parsed.date {
            parts.append("date=\(dt.attribute) [\(dt.filter.from.map(Self.short) ?? "-") ~ \(dt.filter.to.map(Self.short) ?? "-")]")
        }
        print("解析        : " + parts.joined(separator: "  "))

        var cfg: [String] = ["scope=\(s.scope.rawValue)"]
        cfg.append("filterNoise=\(s.filterNoise)")
        cfg.append("includeApps=\(s.includeApps)")
        cfg.append("maxResults=\(s.maxResults)")
        cfg.append("minQueryLength=\(s.minQueryLength)")
        print("设置        : " + cfg.joined(separator: " "))

        guard let predicate = parsed.buildPredicate(includeApps: s.includeApps) else {
            print("❌ 没建出谓词（关键词是空的？）"); exit(1)
        }
        print("谓词        : \(predicate.predicateFormat)")
        print("范围        : \(engine.scopes(for: parsed))")

        // 自己起一个 query，好逐条看原始命中
        let q = NSMetadataQuery()
        q.notificationBatchingInterval = 0.15
        q.predicate = predicate
        q.searchScopes = engine.scopes(for: parsed)

        var finished = false
        let t0 = Date()
        var firstProgressMs: Double?
        var progressCount = 0

        let center = NotificationCenter.default
        let o1 = center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: q, queue: .main) { _ in
            progressCount += 1
            if firstProgressMs == nil { firstProgressMs = -t0.timeIntervalSinceNow * 1000 }
        }
        let o2 = center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: q, queue: .main) { _ in
            finished = true
        }

        q.start()
        let deadline = Date().addingTimeInterval(20)
        while !finished && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let totalMs = -t0.timeIntervalSinceNow * 1000

        q.disableUpdates()
        let total = q.resultCount
        var kept: [(String, Int)] = []
        var dropped: [String] = []
        for i in 0..<total {
            guard let item = q.result(at: i) as? NSMetadataItem,
                  let p = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if s.filterNoise && SearchEngine.isNoise(p) {
                dropped.append(p)
            } else {
                let path = SearchEngine.canonicalize(p)
                let name = (path as NSString).lastPathComponent
                let used = item.value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
                kept.append((path, SearchEngine.score(name: name, path: path,
                                                      key: SearchEngine.fold(parsed.rankingKey),
                                                      lastUsed: used)))
            }
        }
        q.enableUpdates()
        q.stop()
        center.removeObserver(o1); center.removeObserver(o2)

        print(String(format: "\n耗时        : 首个 progress %.0f ms · 完成 %.0f ms · progress 通知 %d 次%@",
                     firstProgressMs ?? -1, totalMs, progressCount, finished ? "" : "  ⚠️ 超时未完成"))
        print("Spotlight   : \(total) 条")
        print("过滤后      : 留下 \(kept.count) 条，砍掉 \(dropped.count) 条")

        if !kept.isEmpty {
            print("\n── 排序后前 15 条 ──")
            for (path, score) in kept.sorted(by: { $0.1 > $1.1 }).prefix(15) {
                print(String(format: "  %5d  %@", score, path))
            }
        }
        if !dropped.isEmpty {
            print("\n── 被噪音过滤砍掉的前 15 条 ──")
            for p in dropped.prefix(15) { print("         \(p)") }
            if dropped.count > 15 { print("         …… 还有 \(dropped.count - 15) 条") }
        }
        if kept.isEmpty && total > 0 {
            print("\n⚠️ Spotlight 有命中但全被噪音过滤砍了。设置里关掉「过滤噪音目录」再看。")
        }
        print("")
        exit(0)
    }
}
