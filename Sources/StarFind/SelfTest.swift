import Foundation
import AppKit
import SwiftUI

/// 不碰界面的自检。`make test`
///
/// 设置层的读写竞态很难靠手工点击稳定复现，因此这里同时覆盖
/// UserDefaults、查询解析、排序以及真实的 Spotlight 查询。
enum SelfTest {

    private static var passed = 0
    private static var failed = 0

    /// ⚠️⚠️ **自检不碰用户的真实设置域**，整层切到一次性 suite 再测
    /// （见 `AppSettings.useDefaultsSuite`）。
    ///
    /// 直接翻转真实设置有两个无法靠「测后还原」解决的问题：
    /// ① 进程可能在还原前被终止；
    /// ② 另一个正在运行的实例可能把中间值读入内存，并在还原后再写回。
    ///
    /// 所以现在的答案不是「还原得更小心」，是根本不碰。
    /// 这个键只留着修旧版本留下的残留。
    private static let backupKey = "selftestBackup"

    private static let managedKeys = [
        "scope", "filterNoise", "includeApps", "maxResults", "minQueryLength",
        "language", "showPreview", "panelWidth", "rowCount", "defaultAction",
        "panelAppearance", "panelMaterial", "panelTintHex", "panelTintOpacity",
        "highlightHex", "highlightOpacity", "panelSpaceBehavior",
    ]

    /// 自检专用的一次性设置域。⚠️ 见 `AppSettings.useDefaultsSuite`
    private static let testSuiteName = "io.github.starsdaisuki.starfind.selftest"
    private static var testSuite: UserDefaults?

    static func run() {
        // 管道里 stdout 是块缓冲的，卡住时一个字都看不见 —— 关掉缓冲
        setvbuf(stdout, nil, _IONBF, 0)
        print("\n════ StarFind 自检 ════\n")

        // 先修上一次（旧版本）留下的残留，这一步必须在切 suite 之前，跑的是真实域
        restoreLeftoverBackup()

        // ⚠️⚠️ 把设置层整个搬到一次性 suite 再开测。
        // 直接翻转真实设置域会与正在运行的 app 产生跨进程竞态，
        // 因此自检始终使用一次性 suite。
        let realDomain = snapshotRealDomain()
        let suite = UserDefaults(suiteName: testSuiteName)!
        suite.removePersistentDomain(forName: testSuiteName)
        testSuite = suite
        AppSettings.shared.useDefaultsSuite(suite)
        testQueryParsing()
        testNoiseFilter()
        testScoring()
        testSettingsPersistence()
        testSettingsViewLayout()
        testLiveSpotlightQuery()
        testNoAccumulationAcrossSearches()
        testColorSupport()
        testSelectionAnchoring()
        testPanelVisibilityIntent()
        testEmitThrottle()
        testMainMenu()
        testCJKRelaxation()
        testFocusRestorePolicy()
        testFileAccess()

        // ⭐ 最后一关：证明这一整轮自检**一个字节都没动过用户的真实设置**
        verifyRealDomainUntouched(realDomain)
        AppSettings.shared.useDefaultsSuite(.standard)
        suite.removePersistentDomain(forName: testSuiteName)
        testSuite = nil

        print("\n────────────────────────")
        print(failed == 0 ? "✅ 全部通过（\(passed) 项）" : "❌ \(failed) 项失败 / 共 \(passed + failed) 项")
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: 断言

    private static func check(_ label: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("  ✓ \(label)")
        } else {
            failed += 1
            let d = detail()
            print("  ✗ \(label)\(d.isEmpty ? "" : "  —— \(d)")")
        }
    }

    private static func section(_ title: String) { print("\n【\(title)】") }

    // MARK: 真实设置域不许被碰

    /// 开测前把用户真实域里那些键抄一份
    private static func snapshotRealDomain() -> [String: String] {
        let d = UserDefaults.standard
        var snap: [String: String] = [:]
        for k in managedKeys {
            snap[k] = d.object(forKey: k).map { String(describing: $0) } ?? "<不存在>"
        }
        return snap
    }

    /// 跑完再抄一份对比。**任何一项对不上就是自检自己在破坏用户配置。**
    ///
    /// 老办法（翻转真实域 → 跑完还原）挡不住这个：用户的 app 正跑着的时候，
    /// 它会把翻转值读进内存，等自检还原完磁盘之后再自己 save() 一次盖回去。
    private static func verifyRealDomainUntouched(_ before: [String: String]) {
        section("没碰用户的真实设置")
        let after = snapshotRealDomain()
        let changed = managedKeys.filter { before[$0] != after[$0] }
        check("真实设置域 \(managedKeys.count) 项全部原封不动", changed.isEmpty,
              changed.map { "\($0): \(before[$0] ?? "?") → \(after[$0] ?? "?")" }.joined(separator: "，"))
        // 再直接验一次隔离：往自检 suite 里写个哨兵键，standard 里不该看得见
        let sentinel = "__selftestSentinel"
        let suite = UserDefaults(suiteName: testSuiteName)!
        suite.set("42", forKey: sentinel)
        check("写进自检 suite 的键不会漏到 standard",
              UserDefaults.standard.string(forKey: sentinel) == nil)
        suite.removeObject(forKey: sentinel)
    }

    // MARK: 设置快照（防「测试被 kill，用户设置留在翻转状态」）

    private static func clearSnapshot() {
        UserDefaults.standard.removeObject(forKey: backupKey)
        UserDefaults.standard.synchronize()
    }

    private static func applySnapshot(_ snap: [String: Any]) {
        let d = UserDefaults.standard
        let present = Set((snap["__present"] as? [String]) ?? [])
        for k in managedKeys {
            if present.contains(k), let v = snap[k] { d.set(v, forKey: k) }
            else { d.removeObject(forKey: k) }
        }
        d.synchronize()
        AppSettings.shared.load()
    }

    /// 上一次跑到一半被 kill 掉留下的残留
    private static func restoreLeftoverBackup() {
        guard let snap = UserDefaults.standard.dictionary(forKey: backupKey) else { return }
        print("⚠️ 检测到上次自检没跑完留下的设置快照，先还原用户设置")
        applySnapshot(snap)
        clearSnapshot()
    }

    // MARK: 查询解析

    private static func testQueryParsing() {
        section("查询解析")

        /// 把 groups 拍平成 "a|b + c" 这种好断言的形式
        func shape(_ q: ParsedQuery) -> String {
            q.groups.map { $0.map(\.text).joined(separator: "|") }.joined(separator: " + ")
        }

        let a = ParsedQuery.parse("报告")
        check("单个关键词", shape(a) == "报告" && a.content == nil, shape(a))

        let b = ParsedQuery.parse("会议 记录")
        check("空格 = AND（两组）", shape(b) == "会议 + 记录", shape(b))

        let c = ParsedQuery.parse("报告|汇报 2026")
        check("| = OR（只在 token 内）", shape(c) == "报告|汇报 + 2026", shape(c))

        let d = ParsedQuery.parse("笔记 !草稿")
        check("! = 排除", shape(d) == "笔记" && d.excluded.map(\.text) == ["草稿"],
              "groups=\(shape(d)) excluded=\(d.excluded.map(\.text))")

        let e = ParsedQuery.parse("\"Application Support\" 笔记")
        check("引号 = 字面（空格不当分隔）",
              e.groups.first?.first?.text == "Application Support"
                  && e.groups.first?.first?.isLiteral == true
                  && e.groups.count == 2,
              shape(e))

        let f = ParsedQuery.parse("dir:~/Documents 笔记")
        check("dir: 展开 ~", f.dir == NSHomeDirectory() + "/Documents" && shape(f) == "笔记",
              "dir=\(f.dir ?? "nil")")

        // MARK: 通配符
        let w1 = Term(text: "*.mp3")
        check("通配符 → 整名匹配", w1.hasWildcard
              && w1.predicate().predicateFormat.contains("\"*.mp3\""),
              w1.predicate().predicateFormat)
        let w2 = Term(text: "报告")
        check("无通配符 → 子串匹配", !w2.hasWildcard
              && w2.predicate().predicateFormat.contains("\"*报告*\""),
              w2.predicate().predicateFormat)
        let w3 = Term(text: "a*b", isLiteral: true)
        check("引号里的星号是字面", !w3.hasWildcard
              && w3.predicate().predicateFormat.contains("\\\\*"),
              w3.predicate().predicateFormat)

        // MARK: ext / 类型宏
        let g = ParsedQuery.parse("ext:jpg;png 壁纸")
        check("ext: 分号列表", g.extensions == ["jpg", "png"] && shape(g) == "壁纸",
              "ext=\(g.extensions)")
        check("ext: 带点也认", ParsedQuery.parse("ext:.pdf").extensions == ["pdf"])
        let h = ParsedQuery.parse("image: 壁纸")
        check("类型宏 image:", h.kind == .image && shape(h) == "壁纸",
              "kind=\(String(describing: h.kind))")
        check("类型宏 kind:image 等价", ParsedQuery.parse("kind:image").kind == .image)
        check("中文类型宏 图片:", ParsedQuery.parse("图片:").kind == .image)
        check("folder: = 只要文件夹", ParsedQuery.parse("folder: x").onlyFolders)
        check("file: = 只要文件", ParsedQuery.parse("file: x").onlyFiles)

        // MARK: content
        let i = ParsedQuery.parse("content:会议纪要")
        check("content: 搜内容", i.content == "会议纪要" && i.groups.isEmpty, i.content ?? "nil")

        // MARK: size
        check("size:>10mb", NumericFilter.parseSize(">10mb")
              == NumericFilter(op: .gt, value: 10 * 1048576))
        check("size 用 1024 不是 1000", NumericFilter.parseSize("1kb")?.value == 1024)
        check("size:2mb..10mb 是区间",
              NumericFilter.parseSize("2mb..10mb")
              == NumericFilter(op: .range(10 * 1048576), value: 2 * 1048576))
        check("size:<=100kb", NumericFilter.parseSize("<=100kb")
              == NumericFilter(op: .lte, value: 100 * 1024))
        check("size 乱写返回 nil", NumericFilter.parseSize("abc") == nil)

        // MARK: date（固定 now，避免跨天抖动）
        let now = DateFilter.parse("2025-01-30", now: Date())!.from!   // 2025-01-30 00:00 本地
        let cal = Calendar.current
        check("dm:today 从今天零点起",
              DateFilter.parse("today", now: now)?.from == cal.startOfDay(for: now))
        check("dm:7d 是 7 天前",
              DateFilter.parse("7d", now: now)?.from == cal.date(byAdding: .day, value: -7, to: now))
        check("dm:2w 是 2 周前",
              DateFilter.parse("2w", now: now)?.from == cal.date(byAdding: .weekOfYear, value: -2, to: now))
        check("dm:>2025-01-01 只有下界",
              DateFilter.parse(">2025-01-01", now: now)?.to == nil
                  && DateFilter.parse(">2025-01-01", now: now)?.from != nil)
        check("dm:a..b 两头都有",
              DateFilter.parse("2025-01-01..2025-01-31", now: now)?.from != nil
                  && DateFilter.parse("2025-01-01..2025-01-31", now: now)?.to != nil)
        check("date 乱写返回 nil", DateFilter.parse("下周三", now: now) == nil)
        let j = ParsedQuery.parse("报告 dm:today")
        check("dm: 接到修改时间属性上",
              j.date?.attribute == "kMDItemContentModificationDate" && shape(j) == "报告",
              j.date?.attribute ?? "nil")

        // MARK: 半截 token
        let k = ParsedQuery.parse("ext:")
        check("半截 ext: 不算关键词", k.groups.isEmpty && k.extensions.isEmpty && k.isEmpty)
        let l = ParsedQuery.parse("size:")
        check("半截 size: 不算关键词", l.groups.isEmpty && l.size == nil && l.isEmpty)

        // MARK: 谓词能建出来 + 单条件不包 compound
        let single = ParsedQuery.parse("报告").buildPredicate(includeApps: true)
        check("单条件不包成 NSCompoundPredicate", !(single is NSCompoundPredicate),
              String(describing: type(of: single!)))
        let multi = ParsedQuery.parse("会议 记录 ext:md").buildPredicate(includeApps: true)
        check("多条件是 AND compound",
              (multi as? NSCompoundPredicate)?.compoundPredicateType == .and)
        check("光一个排除词建不出谓词",
              ParsedQuery.parse("!草稿").buildPredicate(includeApps: true) == nil)
    }

    // MARK: 设置窗口不能塌成 0 高

    /// TabView 里套 Form、外层没有高度约束时，
    /// 整个内容会塌掉。这里离屏量一次 fittingSize，不用截图也能验。
    private static func testSettingsViewLayout() {
        section("设置窗口布局")

        let host = NSHostingView(rootView: SettingsView())
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        check("设置视图有合理宽度", size.width >= 400, "实测宽 \(Int(size.width))")
        check("设置视图有合理高度", size.height >= 300, "实测高 \(Int(size.height))")
        check("跟声明的 contentSize 一致",
              abs(size.width - SettingsView.contentSize.width) < 1
                  && abs(size.height - SettingsView.contentSize.height) < 1,
              "实测 \(Int(size.width))×\(Int(size.height))，声明 "
                + "\(Int(SettingsView.contentSize.width))×\(Int(SettingsView.contentSize.height))")
    }

    // MARK: 噪音过滤

    private static func testNoiseFilter() {
        section("噪音过滤")
        let home = NSHomeDirectory()

        check("放行个人文件", !SearchEngine.isNoise("\(home)/Documents/报告.md"))
        check("挡掉 /System", SearchEngine.isNoise("/System/Library/Foo.plist"))
        check("挡掉 ~/Library", SearchEngine.isNoise("\(home)/Library/Caches/x.db"))
        check("挡掉 node_modules", SearchEngine.isNoise("\(home)/code/p/node_modules/lodash/LICENSE"))
        check("挡掉废纸篓", SearchEngine.isNoise("\(home)/.Trash/old.md"))
        check("挡掉隐藏文件", SearchEngine.isNoise("\(home)/.zshrc"))
        check("挡掉 .app 内部", SearchEngine.isNoise("/Applications/Safari.app/Contents/Info.plist"))
        check("但放行 .app 本体", !SearchEngine.isNoise("\(home)/Applications/Example.app"))
        // 系统自带 app 住在 /System/ 下（甚至 Cryptex 里），不能被前缀规则一起挡掉，
        // 否则搜「备忘录」「邮件」会一条都没有
        check("放行 /System/Applications 里的 app",
              !SearchEngine.isNoise("/System/Applications/Notes.app"))
        check("放行 Cryptex 里的 Safari",
              !SearchEngine.isNoise("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"))
        check("但仍挡掉 /System 下的普通文件",
              SearchEngine.isNoise("/System/Library/Fonts/Helvetica.ttc"))
        check("Cryptex 路径归一化",
              SearchEngine.canonicalize("/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app")
                == "/System/Applications/Safari.app")
    }

    // MARK: 排序

    private static func testScoring() {
        section("排序")
        let home = NSHomeDirectory()
        let key = "report"

        func s(_ name: String, _ path: String? = nil, used: Date? = nil) -> Int {
            SearchEngine.score(name: name,
                               path: path ?? "\(home)/Documents/\(name)",
                               key: key, lastUsed: used)
        }

        check("完全同名 > 前缀匹配", s("report.md") > s("report-final-v3.md"),
              "\(s("report.md")) vs \(s("report-final-v3.md"))")
        check("前缀匹配 > 中间匹配", s("report-v3.md") > s("q3-report-v3.md"),
              "\(s("report-v3.md")) vs \(s("q3-report-v3.md"))")
        check("词首匹配 > 词中匹配", s("q3-report.md") > s("myreportdraft.md"),
              "\(s("q3-report.md")) vs \(s("myreportdraft.md"))")
        check("最近用过的往前排",
              s("report-a.md", used: Date()) > s("report-a.md", used: Date(timeIntervalSinceNow: -400 * 86400)))
        check("路径浅的往前排",
              s("report.md", "\(home)/report.md") > s("report.md", "\(home)/a/b/c/d/e/report.md"))
        check("大小写不敏感", s("REPORT.md") == s("report.md"))
        check("Library 里的沉底",
              s("report.md", "\(home)/Library/x/report.md") < s("report.md"))
        check("应用程序加权", s("Report.app", "/Applications/Report.app") > s("report.md"))
    }

    // MARK: 设置读写（就是抓「点一下弹回去」那个 bug 的）

    private static func testSettingsPersistence() {
        section("设置读写")
        let s = AppSettings.shared
        // ⚠️ 用自检自己的 suite，**不是** UserDefaults.standard ——
        // 碰真实域会改坏用户正在用的配置，见 AppSettings.useDefaultsSuite 的注释
        let defaults = testSuite!

        // 存好原值，测完还回去
        let backup = (s.scope, s.filterNoise, s.includeApps, s.maxResults,
                      s.language, s.showPreview, s.rowCount, s.defaultAction,
                      s.panelSpaceBehavior)

        // 一次改多项 —— bug 版本里，写第一个键就会把后面几项冲回旧值
        s.scope = (s.scope == .home) ? .computer : .home
        s.filterNoise.toggle()
        s.includeApps.toggle()
        s.maxResults = s.maxResults == 60 ? 90 : 60
        s.language = (s.language == .zh) ? .en : .zh
        s.showPreview.toggle()
        s.rowCount = s.rowCount == 9 ? 7 : 9
        s.defaultAction = (s.defaultAction == .open) ? .reveal : .open
        s.panelSpaceBehavior = (s.panelSpaceBehavior == .spotlight)
            ? .followAllSpaces : .spotlight

        let expected = (s.scope, s.filterNoise, s.includeApps, s.maxResults,
                        s.language, s.showPreview, s.rowCount, s.defaultAction,
                        s.panelSpaceBehavior)

        // 等 debounce（300ms）写盘 + 通知回环
        spin(seconds: 1.2)

        check("内存 scope", s.scope == expected.0, "期望 \(expected.0.rawValue)，实际 \(s.scope.rawValue)")
        check("内存 filterNoise", s.filterNoise == expected.1)
        check("内存 includeApps", s.includeApps == expected.2)
        check("内存 maxResults", s.maxResults == expected.3, "期望 \(expected.3)，实际 \(s.maxResults)")
        check("内存 language", s.language == expected.4, "期望 \(expected.4.rawValue)，实际 \(s.language.rawValue)")
        check("内存 showPreview", s.showPreview == expected.5)
        check("内存 rowCount", s.rowCount == expected.6, "期望 \(expected.6)，实际 \(s.rowCount)")
        check("内存 defaultAction", s.defaultAction == expected.7)
        check("内存 panelSpaceBehavior", s.panelSpaceBehavior == expected.8,
              "期望 \(expected.8.rawValue)，实际 \(s.panelSpaceBehavior.rawValue)")

        defaults.synchronize()
        check("磁盘 scope", defaults.string(forKey: "scope") == expected.0.rawValue,
              "磁盘上是 \(defaults.string(forKey: "scope") ?? "nil")")
        check("磁盘 language", defaults.string(forKey: "language") == expected.4.rawValue,
              "磁盘上是 \(defaults.string(forKey: "language") ?? "nil")")
        check("磁盘 maxResults", defaults.integer(forKey: "maxResults") == expected.3)
        check("磁盘 rowCount", defaults.integer(forKey: "rowCount") == expected.6)
        check("磁盘 panelSpaceBehavior",
              defaults.string(forKey: "panelSpaceBehavior") == expected.8.rawValue)

        // 外部改动（相当于 `defaults write`）应该能被读回来
        let outsideValue = expected.6 == 9 ? 12 : 9
        defaults.set(outsideValue, forKey: "rowCount")
        spin(seconds: 0.6)
        check("外部写入能同步进来", s.rowCount == outsideValue,
              "期望 \(outsideValue)，实际 \(s.rowCount)")

        // 还原
        s.scope = backup.0; s.filterNoise = backup.1; s.includeApps = backup.2
        s.maxResults = backup.3; s.language = backup.4; s.showPreview = backup.5
        s.rowCount = backup.6; s.defaultAction = backup.7
        s.panelSpaceBehavior = backup.8
        spin(seconds: 0.6)
        check("还原成功",
              s.rowCount == backup.6
                  && s.language == backup.4
                  && s.panelSpaceBehavior == backup.8)
    }

    // MARK: 真跑一次 Spotlight

    /// 真跑一次 Spotlight，确认「预测 → 谓词 → 取结果 → 排序」整条链是通的。
    ///
    /// ⚠️ 目标目录必须挑 `/Applications` 这种**不受 TCC 保护**的位置。
    /// 早先这里写的是 `~/Documents`，一列目录就触发「允许 StarFind 访问文稿」的系统弹窗，
    /// 无头跑的时候没人点，进程直接挂死 5 分钟。查询本身不需要 TCC 授权
    /// （Spotlight 只回路径），只有**读文件内容**（预览窗格）才会弹。
    private static func testLiveSpotlightQuery() {
        section("Spotlight 实查")

        guard FileManager.default.fileExists(atPath: "/Applications/Safari.app") else {
            print("  ⚠️ 这台机器没有 Safari，跳过实查")
            return
        }

        // ⚠️ 这一节的结论依赖 includeApps / filterNoise / scope，不能听环境里是什么。
        // 之前就是因为 includeApps 被上一节改成 false 没恢复，这里凭空失败了两项。
        let s = AppSettings.shared
        let saved = (s.includeApps, s.filterNoise, s.scope)
        s.includeApps = true; s.filterNoise = true; s.scope = .home
        spin(seconds: 0.5)
        defer {
            s.includeApps = saved.0; s.filterNoise = saved.1; s.scope = saved.2
            spin(seconds: 0.5)
            clearSnapshot()
        }

        let engine = SearchEngine()
        var got: [SearchHit] = []
        var finished = false
        engine.onResults = { hits, gathering, _ in
            got = hits
            if !gathering { finished = true }
        }
        engine.search("dir:/Applications Safari")

        let deadline = Date().addingTimeInterval(10)
        while !finished && Date() < deadline { spin(seconds: 0.1) }
        engine.stop()

        check("查询有返回", finished, "10 秒内没收到 DidFinishGathering")
        check("能搜到 Safari.app", got.contains { $0.name == "Safari.app" },
              "返回 \(got.count) 条，头几条：\(got.prefix(3).map(\.name).joined(separator: ", "))")
        check("最相关的排第一", got.first?.name == "Safari.app",
              "第一条是 \(got.first?.name ?? "（空）")")
        check("路径已归一化（不出现 Cryptexes）",
              !(got.first?.path.contains("Cryptexes") ?? false),
              "第一条路径 \(got.first?.path ?? "（空）")")
    }

    // MARK: 同一个引擎连续搜多次不能累积结果

    /// 这是「搜什么都搜不出来」那个 bug 的回归测试。
    ///
    /// 根因：复用同一个 NSMetadataQuery（stop → 改 predicate → start）会把新结果
    /// **堆在旧结果上**，使 resultCount 在连续输入时异常增长。
    /// 更糟的是 result(at: 0) 起头全是上次查询的残留，被噪音过滤一砍就成了 0 条。
    private static func testNoAccumulationAcrossSearches() {
        section("连续搜索不累积")

        func finalCount(of engine: SearchEngine, query: String, warmups: [String] = []) -> (Int, Int) {
            var results = 0, total = 0
            var finished = false
            engine.onResults = { hits, gathering, t in
                results = hits.count; total = t
                if !gathering { finished = true }
            }
            // 先用别的关键词把引擎「弄脏」，模拟一个字一个字打
            for w in warmups {
                finished = false
                engine.search(w)
                spin(seconds: 0.13)
            }
            finished = false
            engine.search(query)
            let deadline = Date().addingTimeInterval(10)
            while !finished && Date() < deadline { spin(seconds: 0.1) }
            engine.stop()
            return (results, total)
        }

        let clean = finalCount(of: SearchEngine(), query: "Safari")
        let dirty = finalCount(of: SearchEngine(), query: "Safari",
                               warmups: ["Sa", "Saf", "Safa", "Safar"])

        check("干净引擎能搜到东西", clean.0 > 0, "results=\(clean.0) total=\(clean.1)")
        check("连打 5 次之后 total 不膨胀", dirty.1 == clean.1,
              "干净=\(clean.1)，连打之后=\(dirty.1)")
        check("连打 5 次之后结果数一致", dirty.0 == clean.0,
              "干净=\(clean.0)，连打之后=\(dirty.0)")
    }

    // MARK: 颜色

    private static func testColorSupport() {
        section("颜色")
        check("#RRGGBB 解析", HexColor.nsColor("#2F6FE0") != nil)
        check("不带 # 也认", HexColor.nsColor("2F6FE0") != nil)
        check("带 alpha 的 8 位也认", HexColor.nsColor("#2F6FE0FF") != nil)
        check("乱写返回 nil", HexColor.nsColor("不是颜色") == nil)
        check("长度不对返回 nil", HexColor.nsColor("#FFF") == nil)
        check("往返一致", HexColor.hex(HexColor.nsColor("#2F6FE0")!) == "#2F6FE0",
              HexColor.hex(HexColor.nsColor("#2F6FE0")!))
        check("纯黑往返", HexColor.hex(HexColor.nsColor("#000000")!) == "#000000")
        check("纯白往返", HexColor.hex(HexColor.nsColor("#FFFFFF")!) == "#FFFFFF")
        check("坏值有 fallback",
              HexColor.color("垃圾", fallback: .red) == Color.red)
    }

    // MARK: 选中项锚定（「选中的蓝底偶尔没掉」的回归测试）

    private static func testSelectionAnchoring() {
        section("选中项锚定")

        func hit(_ p: String) -> SearchHit { SearchHit(path: p, name: (p as NSString).lastPathComponent, score: 0) }
        let batch1 = [hit("/a"), hit("/b"), hit("/c")]
        // gather 第二批：条数变多，而且原来的 /b 位置变了
        let batch2 = [hit("/x"), hit("/y"), hit("/a"), hit("/b"), hit("/c"), hit("/d")]

        let r1 = SearchViewModel.resolveSelection(anchor: "/b", previous: 1, in: batch2)
        check("结果重排后仍选中同一个文件", r1.index == 3 && r1.anchor == "/b",
              "index=\(r1.index) anchor=\(r1.anchor ?? "nil")")

        let r2 = SearchViewModel.resolveSelection(anchor: "/gone", previous: 1, in: batch2)
        check("锚定的文件没了 → 退回就近索引", r2.index == 1 && r2.anchor == "/y",
              "index=\(r2.index) anchor=\(r2.anchor ?? "nil")")

        let r3 = SearchViewModel.resolveSelection(anchor: "/c", previous: 2, in: [])
        check("结果空了 → 索引 0、锚定清空", r3.index == 0 && r3.anchor == nil)

        let r4 = SearchViewModel.resolveSelection(anchor: nil, previous: 99, in: batch1)
        check("索引越界 → 夹到最后一条", r4.index == 2 && r4.anchor == "/c",
              "index=\(r4.index)")

        let r5 = SearchViewModel.resolveSelection(anchor: nil, previous: 0, in: batch1)
        check("没有锚定 → 建立锚定", r5.anchor == "/a")
    }

    // MARK: 跨 Space 的面板显示意图

    private static func testPanelVisibilityIntent() {
        section("跨 Space 面板显示意图")

        var intent = PanelVisibilityIntent()
        check("初始隐藏", !intent.wantsVisible)
        check("第一次热键 → 显示", intent.toggle() && intent.wantsVisible)
        check("第二次热键 → 隐藏", !intent.toggle() && !intent.wantsVisible)

        // 关键回归：窗口在 Space 动画里可能短暂 visible=false / key=false，
        // 但这些 AppKit 状态不参与用户意图，因此连续热键仍严格按奇偶翻转。
        let sequence = (0..<20).map { _ in intent.toggle() }
        check("连续 20 次热键严格交替",
              sequence.enumerated().allSatisfy { index, value in value == (index % 2 == 0) })
        check("偶数次之后回到隐藏", !intent.wantsVisible)

        intent.show()
        check("显式 show", intent.wantsVisible)
        intent.hide()
        check("显式 hide", !intent.wantsVisible)
    }

    // MARK: emit 节流（「面板停在旧结果上再也不动」的回归测试）

    private static func testEmitThrottle() {
        section("emit 节流不丢结果")

        let min = SearchEngine.minEmitInterval

        check("收工那一次永远立刻发",
              SearchEngine.emitDecision(isFinal: true, sinceLastEmit: 0.001) == .now)
        check("间隔够了就立刻发",
              SearchEngine.emitDecision(isFinal: false, sinceLastEmit: min + 0.01) == .now)
        check("刚好卡在阈值上也立刻发",
              SearchEngine.emitDecision(isFinal: false, sinceLastEmit: min) == .now)

        // ⚠️ 核心：太密的那一次是**推迟**，不是丢掉。
        // 丢掉的话，如果它恰好是最后一条通知（Finish 之后 3ms 才到的那批更新），
        // 界面就永远停在旧结果上，而且转圈圈已经灭了，看不出还有后续。
        let dense = SearchEngine.emitDecision(isFinal: false, sinceLastEmit: 0.003)
        if case .after(let wait) = dense {
            check("太密的那一次是推迟不是丢弃", abs(wait - (min - 0.003)) < 0.0001,
                  "推迟 \(Int(wait * 1000))ms")
        } else {
            check("太密的那一次是推迟不是丢弃", false, "返回了 \(dense)")
        }

        // 连着来 5 条密集通知：每一条都该排上补做，没有一条是「直接扔」
        let dense5 = (1...5).map {
            SearchEngine.emitDecision(isFinal: false, sinceLastEmit: Double($0) * 0.005)
        }
        check("连续 5 条密集通知全部推迟补做、一条都不丢",
              dense5.allSatisfy { if case .after = $0 { return true } else { return false } },
              "\(dense5)")
        check("0 间隔也只是推迟一整个窗口",
              SearchEngine.emitDecision(isFinal: false, sinceLastEmit: 0) == .after(min))
    }

    // MARK: 主菜单（⌘A / ⌘V / ⌘X / ⌘Z 失效的回归测试）

    private static func testMainMenu() {
        section("主菜单编辑快捷键")

        let menu = AppDelegate.makeMainMenu(settingsTarget: nil, settingsAction: nil)
        // 平铺出所有子菜单项
        var items: [NSMenuItem] = []
        func walk(_ m: NSMenu) {
            for item in m.items {
                items.append(item)
                if let sub = item.submenu { walk(sub) }
            }
        }
        walk(menu)

        func find(_ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem? {
            items.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == mods }
        }

        // ⚠️ 这几项不是摆设 —— NSTextView 自己不处理 ⌘A/⌘V/⌘X/⌘Z，
        // 它们靠 NSApp.mainMenu.performKeyEquivalent 派发。以前没建主菜单，所以全不灵。
        let expected: [(String, String, Selector, NSEvent.ModifierFlags)] = [
            ("全选 ⌘A",   "a", #selector(NSText.selectAll(_:)), [.command]),
            ("拷贝 ⌘C",   "c", #selector(NSText.copy(_:)),      [.command]),
            ("粘贴 ⌘V",   "v", #selector(NSText.paste(_:)),     [.command]),
            ("剪切 ⌘X",   "x", #selector(NSText.cut(_:)),       [.command]),
            ("撤销 ⌘Z",   "z", NSSelectorFromString("undo:"),   [.command]),
            ("重做 ⌘⇧Z",  "z", NSSelectorFromString("redo:"),   [.command, .shift]),
        ]
        for (label, key, sel, mods) in expected {
            let item = find(key, mods)
            check("\(label) 在主菜单里且 action 正确",
                  item?.action == sel, item == nil ? "根本没有这一项" : "action=\(item!.action.map(NSStringFromSelector) ?? "nil")")
            check("\(label) 走响应链（target 为 nil）", item?.target == nil)
        }

        // ⌘W 关窗口 —— 没有它设置窗口只能用鼠标点左上角红点关
        let closeItem = find("w", [.command])
        check("关闭窗口 ⌘W 在主菜单里且 action 正确",
              closeItem?.action == #selector(NSWindow.performClose(_:)),
              closeItem == nil ? "根本没有这一项" : "action=\(closeItem!.action.map(NSStringFromSelector) ?? "nil")")
        check("关闭窗口 ⌘W 走响应链（target 为 nil）", closeItem?.target == nil)

        // 故意不放 Quit：面板弹出时 StarFind 是激活状态，
        // 放了的话在别的 app 上按 ⌘Q 会把 StarFind 自己关掉。
        check("主菜单里没有 ⌘Q", find("q", [.command]) == nil)
    }

    // MARK: 中文整串查不到时的退避（「输入全名反而搜不到」的回归测试）

    private static func testCJKRelaxation() {
        section("中文退避重查")

        // ⚠️ 背景：Spotlight 对中文按分词匹配，`项目示例-1-年度总结与数据复盘.md`
        // 整串查 0 条，连 kMDItemFSName == 精确等于都查不到。见 Term.relaxedPredicate。
        let full = "项目示例-1-年度总结与数据复盘.md"
        let t = Term(text: full)
        check("能认出中文字", t.cjkCharacters.count > 10, "\(t.cjkCharacters.count) 个")
        check("数字和连字符不算中文", !Term(text: "a-1-b").cjkCharacters.contains(where: { "-1ab".contains($0) }))
        check("纯英文没有中文字", Term(text: "sample-2025").cjkCharacters.isEmpty)

        let relaxed = t.relaxedPredicate().predicateFormat
        check("退避谓词是逐字 AND", relaxed.contains("AND") && relaxed.contains("\"*项*\""),
              relaxed.prefix(80).description)
        // 「例」在文件名里只出现一次，条件里也只该出现一次（Set 去重）
        check("同一个字不重复出条件",
              relaxed.components(separatedBy: "\"*例*\"").count - 1 == 1, relaxed)

        // 纯英文查询不需要退避。
        check("纯英文查询不退避", !ParsedQuery.parse("sample-release-notes-2025-01-30.md").isRelaxable)
        check("中文查询可以退避", ParsedQuery.parse(full).isRelaxable)
        check("带通配符不退避（语义是整名匹配，没法用子串复核）",
              !ParsedQuery.parse("*项目示例*").isRelaxable)
        check("content: 不退避（命中的是内容，用文件名过滤会误杀）",
              !ParsedQuery.parse("content:项目示例").isRelaxable)

        // ⭐ 退避之后靠这个内存过滤把候选收回到真正的子串语义，保证不引入噪音
        let q = ParsedQuery.parse(full)
        check("内存过滤：目标文件名通过", q.matchesName(full))
        check("内存过滤：只对上一半的不通过", !q.matchesName("项目示例-2-季度复盘与经验沉淀.md"))
        check("内存过滤：大小写不敏感", ParsedQuery.parse("SAMPLE").matchesName("sample.md"))

        let multi = ParsedQuery.parse("成长 故事 !草稿")
        check("内存过滤：多个词都要含", multi.matchesName("成长的故事.md"))
        check("内存过滤：少一个词就不算", !multi.matchesName("成长记录.md"))
        check("内存过滤：排除词生效", !multi.matchesName("成长的故事-草稿.md"))

        let or = ParsedQuery.parse("报告|汇报")
        check("内存过滤：OR 命中任一即可", or.matchesName("年度汇报.md") && or.matchesName("年度报告.md"))
        check("内存过滤：OR 都不含就排除", !or.matchesName("年度总结.md"))
    }

    // MARK: 动作之后要不要还焦点（「⌘↩ 不跳桌面」的回归测试）

    private static func testFocusRestorePolicy() {
        section("动作后的焦点归属")

        // ⚠️ 打开 / 访达中显示之后**不能**把焦点还给原来那个 app：
        // 刚把 Finder 拉到前台，紧接着 prev.activate() 又抢回去，
        // 表现就是「Finder 开了，但停在原来那个全屏桌面上没跳过去」。
        check("⌘↩ 在访达中显示 → 不还焦点", !SearchViewModel.PanelAction.reveal.restoresFocus)
        check("↩ 打开文件 → 不还焦点", !SearchViewModel.PanelAction.open.restoresFocus)
        // 拷完要回到原来的地方接着粘贴
        check("⌘C 拷路径 → 还焦点", SearchViewModel.PanelAction.copyPath.restoresFocus)
        check("⌘⇧C 拷文件 → 还焦点", SearchViewModel.PanelAction.copyFile.restoresFocus)
        check("四个动作都定义了归属", SearchViewModel.PanelAction.allCases.count == 4)
    }

    // MARK: 文件访问权限（「搜不到文稿里的东西」的回归测试）

    private static func testFileAccess() {
        section("文件访问权限")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        check("三个受保护目录都在", ProtectedFolder.allCases.count == 3)
        check("文稿路径对", ProtectedFolder.documents.url.path == home + "/Documents",
              ProtectedFolder.documents.url.path)
        check("桌面路径对", ProtectedFolder.desktop.url.path == home + "/Desktop")
        check("下载路径对", ProtectedFolder.downloads.url.path == home + "/Downloads")

        // 面板提示：权限齐全就别打扰用户，缺了就要说清缺哪个
        check("权限齐全时不显示权限提示", SearchView.missingAccessHint([]) == nil)
        let hint = SearchView.missingAccessHint([.documents, .desktop])
        check("缺权限时提示里点名了目录",
              hint?.contains(ProtectedFolder.documents.localizedLabel) == true
              && hint?.contains(ProtectedFolder.desktop.localizedLabel) == true,
              hint ?? "nil")
        check("提示里没有没替换掉的占位符", hint?.contains("%@") == false, hint ?? "nil")
    }

    // MARK: 工具

    /// 跑 runloop 而不是 sleep —— NSMetadataQuery 和 UserDefaults 通知都靠 runloop 送
    private static func spin(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
