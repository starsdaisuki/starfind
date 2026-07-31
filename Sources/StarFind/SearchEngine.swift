import Foundation
import AppKit

// MARK: - 一条结果

struct SearchHit: Identifiable, Hashable {
    let path: String
    let name: String
    var score: Int
    var lastUsed: Date?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var isApp: Bool { path.hasSuffix(".app") }

    /// 把以 `$HOME/` 开头的目录显示成 `~/...`。
    var displayDirectory: String {
        let dir = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        if dir == home { return "~" }
        if dir.hasPrefix(home + "/") { return "~" + dir.dropFirst(home.count) }
        return dir
    }

    static func == (a: SearchHit, b: SearchHit) -> Bool { a.path == b.path }
    func hash(into h: inout Hasher) { h.combine(path) }
}

// MARK: - 引擎

/// Spotlight 查询封装。
///
/// 关键事实：**macOS 上只有一套文件索引**。Raycast / Alfred / LaunchBar 全都是查它
/// （NSMetadataQuery / mdfind），没有谁自己建索引。所以这里不损失任何检索能力，
/// 差别只在前端排序和呈现。
final class SearchEngine {

    /// 每次查询最多从 Spotlight 里取多少条来打分。
    /// 短关键词能匹配到几十万个文件，全取会卡住主线程；取前若干条打分足够用了。
    private let scanCap = 4000

    /// ⚠️⚠️ **每次搜索都要新建一个 NSMetadataQuery，不能复用。**
    ///
    /// 复用的写法（`stop()` → 改 `predicate` → `start()`）会**把新结果堆在旧结果上**，
    /// 连续输入时 `resultCount` 会异常增长。
    ///
    /// 后果不只是数字难看：`result(at: 0)` 开始是**上一次查询残留的旧条目**，
    /// 而那些正好都在 `~/Library/` 下、全被噪音过滤砍掉 ——
    /// 于是界面表现成「0/12 个结果」「搜什么都搜不出来」，而引擎单独跑完全正常。
    ///
    /// 排查时另外两个看着很像的嫌疑都已排除：
    /// `values(forAttributes:)` 可以正常获取 `kMDItemPath`，缺 `lastUsedDate` 也不会让字典返回 nil；
    /// `sortDescriptors = []` 也不影响 `result(at:)`。
    private var query: NSMetadataQuery?
    private var observers: [NSObjectProtocol] = []
    private var currentQuery = ParsedQuery()
    /// 代次。旧 query 的迟到通知按这个丢弃。
    private var generation = 0
    private var settings: AppSettings { AppSettings.shared }

    /// `STARFIND_TRACE=1` 打开：把每一条 Spotlight 通知、每一次节流跳过都打出来。
    /// 「界面停在旧结果」这种问题只有看通知时间线才判得出来。
    static let traceEnabled = ProcessInfo.processInfo.environment["STARFIND_TRACE"] == "1"
    private static let traceStart = Date()
    static func trace(_ msg: @autoclosure () -> String) {
        guard traceEnabled else { return }
        print(String(format: "    [trace %7.0fms] %@", -traceStart.timeIntervalSinceNow * 1000, msg()))
    }

    /// (结果, 是否还在收集中, Spotlight 报告的总命中数)
    var onResults: (([SearchHit], Bool, Int) -> Void)?

    deinit { teardown() }

    // MARK: 发起搜索

    func search(_ raw: String) {
        let parsed = ParsedQuery.parse(raw)
        currentQuery = parsed

        guard !parsed.isEmpty,
              let predicate = parsed.buildPredicate(includeApps: settings.includeApps) else {
            stop(); onResults?([], false, 0); return
        }

        didRelax = false
        postFilter = nil
        startQuery(predicate, raw: raw)
    }

    /// 中文整串查不到时退一步重查（见 `Term.relaxedPredicate`）。
    /// 只退一次，退完带上内存里的真子串过滤，所以结果不会变松。
    private var didRelax = false
    private var postFilter: ((String) -> Bool)?

    private func startQuery(_ predicate: NSPredicate, raw: String) {
        teardown()
        generation += 1
        let gen = generation

        let q = NSMetadataQuery()
        // ⚠️ 千万别设 q.operationQueue = .main。
        // 在主线程调 start() 会直接死锁 —— start() 内部要往那个队列上排一个操作并等它，
        // 而主队列正被 start() 自己占着。踩过：进程卡死，一行日志都不出。
        // 不设的话，通知就在启动查询的那个线程（这里就是主线程）上发，正是我们要的。
        q.notificationBatchingInterval = 0.15
        q.predicate = predicate
        q.searchScopes = scopes(for: currentQuery)

        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSMetadataQueryGatheringProgress,
                     NSNotification.Name.NSMetadataQueryDidFinishGathering,
                     NSNotification.Name.NSMetadataQueryDidUpdate] {
            observers.append(center.addObserver(forName: name, object: q, queue: .main) { [weak self] note in
                guard let self else { return }
                Self.trace("gen\(gen) \(Self.tag(note.name)) resultCount=\(q.resultCount)"
                           + (gen == self.generation ? "" : "  ← 过期，丢弃"))
                guard gen == self.generation else { return }

                // ⚠️ 整串一条都没查到 → 换「中文逐字 AND」再来一次。
                // Spotlight 对中文是按分词匹配的，`中文报告-1-年度总结.md`
                // 这种（汉字里夹着数字和连字符）整串查是 0 条，连 `==` 精确等于都查不到。
                // 见 Term.relaxedPredicate。退避之后带内存过滤，结果不会变松。
                if note.name == .NSMetadataQueryDidFinishGathering,
                   q.resultCount == 0, !self.didRelax,
                   let relaxed = self.currentQuery.buildRelaxedPredicate(
                       includeApps: self.settings.includeApps) {
                    self.didRelax = true
                    let parsed = self.currentQuery
                    self.postFilter = { parsed.matchesName($0) }
                    Self.trace("整串 0 条 → 换「中文逐字 AND + 内存过滤」重查")
                    self.startQuery(relaxed, raw: raw)
                    return
                }

                // ⚠️ 转圈圈只看 GatheringProgress。
                // DidUpdate 是**收工之后**的实时更新，用它把 isSearching 翻回 true
                // 会让转圈圈莫名其妙地一直转下去。
                self.emit(from: q,
                          gathering: note.name == .NSMetadataQueryGatheringProgress,
                          isFinal: note.name == .NSMetadataQueryDidFinishGathering)
            })
        }

        query = q
        // 上一次搜索的节流时间戳不能带到新一轮来，否则新查询的第一批结果会被白白推迟
        lastEmitAt = .distantPast
        Self.trace("search(\"\(raw)\") gen\(gen) 启动")
        q.start()
    }

    private static func tag(_ name: Notification.Name) -> String {
        switch name {
        case .NSMetadataQueryGatheringProgress:  return "Progress"
        case .NSMetadataQueryDidFinishGathering: return "Finish  "
        default:                                 return "Update  "
        }
    }

    func stop() { teardown() }

    private func teardown() {
        pendingEmit?.cancel()
        pendingEmit = nil
        pendingVerify?.cancel()
        pendingVerify = nil
        lastEmittedTotal = -1
        query?.stop()
        query = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    func scopes(for q: ParsedQuery) -> [Any] {
        if let dir = q.dir {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue {
                return [URL(fileURLWithPath: dir)]
            }
        }
        return [settings.scope.metadataScope]
    }

    // MARK: 取结果 + 排序

    /// 「最近用过的往前排」需要 kMDItemLastUsedDate，但那个属性很贵。
    /// 所以先按不含它的分数粗排，只给前这么多条补查一次，再精排。
    private let recencyProbeCount = 250

    /// 两次 emit 之间的最小间隔。gather 期间进度通知很密，
    /// 每次都全量重扫会让主线程持续忙着，打字就发顿。
    static let minEmitInterval: TimeInterval = 0.08
    private var lastEmitAt = Date.distantPast
    private var pendingEmit: DispatchWorkItem?

    /// 节流决策。
    ///
    /// ⚠️⚠️ **被节流掉的那一次必须补，不能丢。**
    /// 这是「面板停在旧结果上再也不动」的根因：Spotlight 的通知是按
    /// `notificationBatchingInterval` 成批发的，实测 Progress 和 Finish 会挨到
    /// 只差 1~3ms。所以完全可能出现
    ///
    /// ```
    /// Finish(3 条)  →  emit 3 条、转圈圈灭掉
    /// Update(5 条)  →  距上次才 3ms，被节流跳过
    /// ……然后再也没有下一条通知
    /// ```
    ///
    /// 界面于是永久停在 3 条上，而且**看不出还在搜** —— 转圈圈已经灭了。
    /// 这类问题的特征是：引擎诊断能看到最终结果，长期运行的 UI 进程
    /// 却停在中间批次。因此被节流的 emit 必须延后补做。
    ///
    /// 所以这里返回「等多久之后补一次」，调用方去排一个延后任务，而不是 return 了事。
    enum EmitDecision: Equatable {
        case now
        /// 等这么久之后补做（秒）
        case after(TimeInterval)
    }

    static func emitDecision(isFinal: Bool, sinceLastEmit: TimeInterval,
                             minInterval: TimeInterval = SearchEngine.minEmitInterval) -> EmitDecision {
        // 收工那一次永远立刻做
        if isFinal { return .now }
        if sinceLastEmit >= minInterval { return .now }
        return .after(minInterval - sinceLastEmit)
    }

    /// 收工之后隔多久复核一次 `resultCount`。
    ///
    /// 上面那条节流补做管的是「通知来了但被节流吃掉」。这一层管的是更没底的一种：
    /// **万一 Spotlight 对最后那批结果压根没发通知**，界面就会安安静静地少几条，
    /// 而且转圈圈已经灭了，看上去像是「搜完了，就这么多」—— 是最难发现的那种错。
    /// 一次查询只多排一个定时器，数对得上就什么都不做。
    private let verifyDelay: TimeInterval = 0.35
    private var pendingVerify: DispatchWorkItem?
    private var verifiedGeneration = -1
    private var lastEmittedTotal = -1

    private func emit(from query: NSMetadataQuery, gathering: Bool, isFinal: Bool) {
        switch Self.emitDecision(isFinal: isFinal, sinceLastEmit: -lastEmitAt.timeIntervalSinceNow) {
        case .after(let wait):
            Self.trace("  emit 太密，推迟 \(Int(wait * 1000))ms 后补做（不丢）")
            pendingEmit?.cancel()
            let gen = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, gen == self.generation, self.query === query else { return }
                self.pendingEmit = nil
                self.emit(from: query, gathering: gathering, isFinal: true)   // 补做这次不再被节流
            }
            pendingEmit = work
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
            return
        case .now:
            pendingEmit?.cancel()
            pendingEmit = nil
        }
        lastEmitAt = Date()

        query.disableUpdates()
        defer { query.enableUpdates() }

        let total = query.resultCount
        let limit = min(total, scanCap)
        let key = Self.fold(currentQuery.rankingKey)
        let filterNoise = settings.filterNoise

        // ⚠️ 性能关键：这个循环里**只能掏 kMDItemPath**。
        // `kMDItemFSName` 和 `kMDItemLastUsedDate` 可能没有被 NSMetadataItem 预取，
        // 在这个循环内逐条读取会触发大量跨进程请求。
        // 而这段跑在主线程、gather 期间还会被反复触发 —— 就是「打几个字母卡一下」的来源。
        // 文件名直接从路径取（lastPathComponent 跟 kMDItemFSName 实际一致）。
        var hits: [SearchHit] = []
        hits.reserveCapacity(min(limit, 512))
        var items: [NSMetadataItem] = []
        items.reserveCapacity(min(limit, 512))

        for i in 0..<limit {
            guard let item = query.result(at: i) as? NSMetadataItem else { continue }
            guard let raw = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if filterNoise && Self.isNoise(raw) { continue }

            let path = Self.canonicalize(raw)
            let name = (path as NSString).lastPathComponent
            // 退避重查时才有：把「候选集」收回到用户真正输入的那个子串上
            if let postFilter, !postFilter(name) { continue }
            hits.append(SearchHit(
                path: path,
                name: name,
                score: Self.score(name: name, path: path, key: key, lastUsed: nil),
                lastUsed: nil
            ))
            items.append(item)
        }

        // 粗排 → 只给头部补查 lastUsedDate → 精排
        var order = Array(hits.indices)
        order.sort { Self.before(hits[$0], hits[$1]) }

        let probe = order.prefix(recencyProbeCount)
        for idx in probe {
            guard let used = items[idx].value(forAttribute: NSMetadataItemLastUsedDateKey) as? Date
            else { continue }
            hits[idx].lastUsed = used
            hits[idx].score = Self.score(name: hits[idx].name, path: hits[idx].path,
                                         key: key, lastUsed: used)
        }

        var top = probe.map { hits[$0] }
        top.sort(by: Self.before)

        let out = Array(top.prefix(settings.maxResults))
        // 退避重查时 resultCount 是**放宽后的候选数**（可能几百条），拿它当「共几条」
        // 会让底部显示成「2/137」，误导。这时候用过滤之后的真实条数。
        let shownTotal = postFilter == nil ? total : hits.count
        Self.trace("  emit → \(out.count) 条 / total=\(shownTotal) gathering=\(gathering)")
        lastEmittedTotal = total
        onResults?(out, gathering, shownTotal)

        // 不再 gather 了 = 这是用户看到的「最终态」，复核一次
        if !gathering { scheduleVerify(for: query) }
    }

    /// 收工后复核：数对不上就补发一次。
    /// **每次搜索只复核一次** —— 否则补发本身又会排一次复核，
    /// 遇到「文件一直在变」的查询（搜 log 之类）就变成每 350ms 醒一次，没完没了。
    private func scheduleVerify(for query: NSMetadataQuery) {
        guard verifiedGeneration != generation else { return }
        verifiedGeneration = generation
        pendingVerify?.cancel()
        let gen = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, self.query === query else { return }
            self.pendingVerify = nil
            let now = query.resultCount
            guard now != self.lastEmittedTotal else { return }
            Self.trace("  收工后复核：resultCount \(self.lastEmittedTotal) → \(now)，补发")
            self.emit(from: query, gathering: false, isFinal: true)
        }
        pendingVerify = work
        DispatchQueue.main.asyncAfter(deadline: .now() + verifyDelay, execute: work)
    }

    /// 分数相同时名字短的在前 —— `report.md` 该排在 `report-2024-final-v3.md` 前面
    private static func before(_ a: SearchHit, _ b: SearchHit) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.name.count != b.name.count { return a.name.count < b.name.count }
        return a.path < b.path
    }

    // MARK: 噪音过滤

    /// 默认滤掉的路径。理由跟 `sf` 脚本一样 ——
    /// 你要找的几乎总是自己的文件，不是 node_modules 里第 8000 个 LICENSE。
    private static let noiseFragments = [
        "/Library/", "/System/", "/.git/", "/node_modules/", "/.build/",
        "/.venv/", "/__pycache__/", "/Caches/", "/.Trash/", "/DerivedData/",
        "/.cache/", "/opt/homebrew/Cellar/", "/site-packages/", "/.gradle/",
        "/Pods/", "/.next/", "/dist/", "/.npm/", "/.cargo/registry/",
    ]

    private static let noisePrefixes = [
        "/System/", "/Library/", "/private/", "/usr/", "/bin/", "/sbin/", "/dev/",
    ]

    /// 系统自带 app 的真实位置。
    ///
    /// macOS 13+ 把 Safari 这些放进了 Cryptex，真实路径长成
    /// `/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app`；
    /// 「备忘录」「邮件」「音乐」则在 `/System/Applications/`。
    /// 这些都以 `/System/` 打头，如果只按前缀滤噪音，**搜系统自带 app 会一条都搜不到**。
    /// 所以 .app 本体单独放行。（.app *内部*的文件仍然滤掉。）
    private static let appLocations = [
        "/Applications/",
        "/System/Applications/",
        "/System/Library/CoreServices/Applications/",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/",
        NSHomeDirectory() + "/Applications/",
    ]

    private static func isAppBundleInAppLocation(_ path: String) -> Bool {
        guard path.hasSuffix(".app") else { return false }
        return appLocations.contains { path.hasPrefix($0) }
    }

    /// Cryptex 的真实路径太丑，映射回大家认得的 `/System/Applications/…`。
    /// 两个路径 NSWorkspace 都能打开。
    static func canonicalize(_ path: String) -> String {
        let cryptex = "/System/Volumes/Preboot/Cryptexes/App"
        return path.hasPrefix(cryptex) ? String(path.dropFirst(cryptex.count)) : path
    }

    static func isNoise(_ path: String) -> Bool {
        // .app 内部的文件几乎从来不是你要找的，但 .app 本身要留着
        if let r = path.range(of: ".app/"), r.upperBound < path.endIndex { return true }
        if isAppBundleInAppLocation(path) { return false }
        for p in noisePrefixes where path.hasPrefix(p) { return true }
        for f in noiseFragments where path.contains(f) { return true }
        // 隐藏文件
        if (path as NSString).lastPathComponent.hasPrefix(".") { return true }
        return false
    }

    // MARK: 打分

    /// 归一化：忽略大小写、变音符号、全半角。中文不受影响。
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static let favoredDirs: [String] = {
        let home = NSHomeDirectory()
        return ["Documents", "Desktop", "Downloads", "Projects", "Pictures", "Movies", "Music", "Code"]
            .map { home + "/" + $0 + "/" }
    }()

    /// 排序的全部逻辑都在这里。改这里就能调「手感」。
    static func score(name: String, path: String, key: String, lastUsed: Date?) -> Int {
        guard !key.isEmpty else { return 0 }
        let n = fold(name)
        let stem = (n as NSString).deletingPathExtension

        var s: Int
        if stem == key            { s = 1000 }
        else if n == key          { s = 950 }
        else if stem.hasPrefix(key) { s = 700 }
        else if n.hasPrefix(key)  { s = 650 }
        else if hasWordBoundaryPrefix(n, key) { s = 450 }
        else if n.contains(key)   { s = 250 }
        else                      { s = 120 }   // 内容命中但文件名不含关键词

        // 名字越接近关键词长度越好
        s -= min(80, max(0, n.count - key.count) * 2)

        // 路径越浅越好
        let depth = path.reduce(0) { $1 == "/" ? $0 + 1 : $0 }
        s -= min(60, depth * 3)

        // 应用程序单独加权 —— 名字对上了的话，你多半就是想打开它
        if path.hasSuffix(".app") { s += 130 }

        // 常用目录
        if favoredDirs.contains(where: { path.hasPrefix($0) }) { s += 60 }

        // 最近用过的往前排
        if let used = lastUsed {
            let days = -used.timeIntervalSinceNow / 86400
            if days < 1        { s += 130 }
            else if days < 7   { s += 85 }
            else if days < 30  { s += 45 }
            else if days < 180 { s += 15 }
        }

        // 关了噪音过滤时这些仍然应该沉底
        if path.contains("/Library/") || path.hasPrefix("/System/") { s -= 220 }

        return s
    }

    /// 关键词是否落在词首（`-` `_` `.` 空格 之后，或字符串开头）
    private static func hasWordBoundaryPrefix(_ name: String, _ key: String) -> Bool {
        let separators: Set<Character> = ["-", "_", ".", " ", "(", "[", "@", "+", "·", "—"]
        var idx = name.startIndex
        while let r = name.range(of: key, range: idx..<name.endIndex) {
            if r.lowerBound == name.startIndex { return true }
            let before = name[name.index(before: r.lowerBound)]
            if separators.contains(before) { return true }
            idx = name.index(after: r.lowerBound)
            if idx >= name.endIndex { break }
        }
        return false
    }
}
