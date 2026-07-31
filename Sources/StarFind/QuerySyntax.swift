import Foundation

// MARK: - 一个关键词

/// 单个关键词。`isLiteral` 来自引号里的内容 —— 内部一律当纯文本，不再解析运算符。
struct Term: Equatable {
    var text: String
    var isLiteral: Bool = false

    /// 带 `*` 或 `?` 时语义会变（见 predicate(on:)）
    var hasWildcard: Bool {
        !isLiteral && (text.contains("*") || text.contains("?"))
    }

    /// LIKE 里 `*` `?` 是通配符，用户想搜字面的星号问号就必须转义
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "*", with: "\\*")
         .replacingOccurrences(of: "?", with: "\\?")
    }

    /// 抄 Everything 的一条关键语义：
    /// **一旦关键词里出现通配符，就从「子串包含」切换成「整个文件名匹配」**。
    /// 不这么做的话 `*.mp3` 会退化成「文件名里含 .mp3」，`foo*` 也不再是「以 foo 开头」。
    /// 来源：voidtools 官方 Searching 页「Wildcards match the whole filename」。
    func predicate(on attribute: String = "kMDItemFSName") -> NSPredicate {
        if hasWildcard {
            return NSPredicate(format: "\(attribute) LIKE[cd] %@", text)
        }
        return NSPredicate(format: "\(attribute) LIKE[cd] %@", "*\(Term.escape(text))*")
    }

    /// 这个词里有没有中日韩汉字
    var cjkCharacters: [Character] {
        text.filter { ch in
            ch.unicodeScalars.allSatisfy { s in
                (0x4E00...0x9FFF).contains(s.value)     // 基本汉字
                    || (0x3400...0x4DBF).contains(s.value)  // 扩展 A
                    || (0xF900...0xFAFF).contains(s.value)  // 兼容汉字
                    || (0x3040...0x30FF).contains(s.value)  // 日文假名
                    || (0xAC00...0xD7AF).contains(s.value)  // 谚文
            }
        }
    }

    /// 退一步的写法：**把每个汉字拆开 AND**。
    ///
    /// ⚠️⚠️ 为什么要有这个：**Spotlight 对中文是按「分词」匹配的，不是字符级子串。**
    /// 使用专门生成的 `中文报告-1-年度总结.md` 可稳定复现：
    ///
    /// | 查询 | 命中 |
    /// |---|---|
    /// | `中文报告` | ✓ |
    /// | `中文报告-1` | ✓ |
    /// | `中文报告-1-年` | **✗** |
    /// | `kMDItemFSName == 整个文件名`（精确等于！） | **✗** |
    /// | `年度总结与数据复盘`（11 字） | ✓ |
    /// | `为什么天`（切在「为什么」中间） | **✗**，而 `为什么天空是蓝色的` ✓ |
    ///
    /// **不是长度问题**：纯英文名和纯中文名都可以正常匹配。
    /// 断的是「模式串的分词跟索引里的分词对不齐」：数字/连字符夹在汉字中间、
    /// 或者切在一个词的半截上，就查不到。Raycast 也有同样的毛病。
    ///
    /// 拆成单字 AND 之后一定是原结果的**超集**（含子串必然含其中每个字），
    /// 再在内存里用真正的子串判断过滤一遍（`ParsedQuery.matchesName`），
    /// 所以**结果精确、不引入噪音**。
    func relaxedPredicate(on attribute: String = "kMDItemFSName") -> NSPredicate {
        let chars = Array(Set(cjkCharacters))
        guard !chars.isEmpty else { return predicate(on: attribute) }
        let subs = chars.map {
            NSPredicate(format: "\(attribute) LIKE[cd] %@", "*\(Term.escape(String($0)))*")
        }
        // ⚠️ 只有一个子谓词时不能包 NSCompoundPredicate，见 README 踩坑 1
        return subs.count == 1 ? subs[0]
             : NSCompoundPredicate(andPredicateWithSubpredicates: subs)
    }
}

// MARK: - 数值比较

/// `size:>1mb`、`size:2mb..10mb` 这类。Everything 所有数值型 function 共用同一套运算符。
struct NumericFilter: Equatable {
    enum Op: Equatable { case eq, lt, lte, gt, gte, range(Double) }
    var op: Op
    var value: Double

    func predicate(on attribute: String) -> NSPredicate {
        switch op {
        case .eq:  return NSPredicate(format: "\(attribute) == %@", NSNumber(value: value))
        case .lt:  return NSPredicate(format: "\(attribute) < %@", NSNumber(value: value))
        case .lte: return NSPredicate(format: "\(attribute) <= %@", NSNumber(value: value))
        case .gt:  return NSPredicate(format: "\(attribute) > %@", NSNumber(value: value))
        case .gte: return NSPredicate(format: "\(attribute) >= %@", NSNumber(value: value))
        case .range(let upper):
            return NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "\(attribute) >= %@", NSNumber(value: value)),
                NSPredicate(format: "\(attribute) <= %@", NSNumber(value: upper)),
            ])
        }
    }

    /// `>1mb` / `<=100kb` / `2mb..10mb` / `1024`
    /// ⚠️ 单位按 JEDEC（1kb = 1024），跟 Everything 默认一致，**不是 1000**。
    static func parseSize(_ raw: String) -> NumericFilter? {
        if let r = raw.range(of: "..") {
            guard let lo = bytes(String(raw[raw.startIndex..<r.lowerBound])),
                  let hi = bytes(String(raw[r.upperBound...])) else { return nil }
            return NumericFilter(op: .range(hi), value: lo)
        }
        let ops: [(String, Op)] = [(">=", .gte), ("<=", .lte), (">", .gt), ("<", .lt), ("=", .eq)]
        for (prefix, op) in ops where raw.hasPrefix(prefix) {
            guard let v = bytes(String(raw.dropFirst(prefix.count))) else { return nil }
            return NumericFilter(op: op, value: v)
        }
        guard let v = bytes(raw) else { return nil }
        return NumericFilter(op: .eq, value: v)
    }

    private static func bytes(_ s: String) -> Double? {
        let t = s.lowercased().trimmingCharacters(in: .whitespaces)
        let units: [(String, Double)] = [("gb", 1073741824), ("mb", 1048576), ("kb", 1024), ("b", 1)]
        for (suffix, mult) in units where t.hasSuffix(suffix) {
            guard let n = Double(t.dropLast(suffix.count)) else { return nil }
            return n * mult
        }
        return Double(t)
    }
}

// MARK: - 日期比较

/// `dm:today` / `dm:7d` / `dm:>2025-01-01` / `dm:2025-01-01..2025-01-31`
struct DateFilter: Equatable {
    var from: Date?
    var to: Date?

    var isEmpty: Bool { from == nil && to == nil }

    func predicate(on attribute: String) -> NSPredicate? {
        var parts: [NSPredicate] = []
        if let from { parts.append(NSPredicate(format: "\(attribute) >= %@", from as NSDate)) }
        if let to { parts.append(NSPredicate(format: "\(attribute) <= %@", to as NSDate)) }
        if parts.isEmpty { return nil }
        return parts.count == 1 ? parts[0]
             : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }

    /// `now` 由外部传入，方便测试时固定时间
    static func parse(_ raw: String, now: Date) -> DateFilter? {
        let cal = Calendar.current
        let t = raw.lowercased().trimmingCharacters(in: .whitespaces)

        switch t {
        case "today", "今天":
            return DateFilter(from: cal.startOfDay(for: now), to: now)
        case "yesterday", "昨天":
            let todayStart = cal.startOfDay(for: now)
            return DateFilter(from: cal.date(byAdding: .day, value: -1, to: todayStart), to: todayStart)
        case "thisweek", "week", "本周":
            return DateFilter(from: cal.date(byAdding: .day, value: -7, to: now), to: now)
        case "thismonth", "month", "本月":
            return DateFilter(from: cal.date(byAdding: .month, value: -1, to: now), to: now)
        case "thisyear", "year", "今年":
            return DateFilter(from: cal.date(byAdding: .year, value: -1, to: now), to: now)
        default:
            break
        }

        // 区间 a..b（结束日含当天整天）
        if let r = t.range(of: "..") {
            let lo = absoluteDate(String(t[t.startIndex..<r.lowerBound]))
            let hi = absoluteDate(String(t[r.upperBound...])).map {
                cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: $0))!
            }
            guard lo != nil || hi != nil else { return nil }
            return DateFilter(from: lo, to: hi)
        }

        // 比较运算符 + 绝对日期
        let ops: [(String, Bool)] = [(">=", true), (">", true), ("<=", false), ("<", false)]
        for (prefix, isLowerBound) in ops where t.hasPrefix(prefix) {
            guard let d = absoluteDate(String(t.dropFirst(prefix.count))) else { return nil }
            return isLowerBound ? DateFilter(from: d, to: nil) : DateFilter(from: nil, to: d)
        }

        // 相对时长：7d / 3days / 2w / 6months
        if let since = relative(t, now: now) { return DateFilter(from: since, to: now) }

        // 光一个绝对日期 = 那一整天
        if let d = absoluteDate(t) {
            let start = cal.startOfDay(for: d)
            return DateFilter(from: start, to: cal.date(byAdding: .day, value: 1, to: start))
        }
        return nil
    }

    /// `7d` `3days` `2w` `6months` `1y`
    private static func relative(_ t: String, now: Date) -> Date? {
        let units: [(String, Calendar.Component)] = [
            ("years", .year), ("year", .year), ("y", .year),
            ("months", .month), ("month", .month), ("mo", .month),
            ("weeks", .weekOfYear), ("week", .weekOfYear), ("w", .weekOfYear),
            ("days", .day), ("day", .day), ("d", .day),
            ("hours", .hour), ("hour", .hour), ("h", .hour),
            ("mins", .minute), ("min", .minute), ("m", .minute),
        ]
        for (suffix, component) in units where t.hasSuffix(suffix) {
            guard let n = Int(t.dropLast(suffix.count)), n > 0 else { continue }
            return Calendar.current.date(byAdding: component, value: -n, to: now)
        }
        return nil
    }

    /// 只认 ISO 8601（`2025-01-30` / `2025-01` / `2025`）。
    /// 斜杠形式（`1/30/2025` vs `30/1/2025`）在 Everything 里取决于系统 locale，
    /// 那种歧义不值得引进来。
    private static func absoluteDate(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        for format in ["yyyy-MM-dd", "yyyy-MM", "yyyy"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
}

// MARK: - 类型

enum FileKind: String, CaseIterable {
    case image, movie, audio, pdf, text, folder, app, archive, doc, code

    /// 除了 `kind:image`，也支持直接写 `image:`（Everything 的类型宏那套）。
    /// Spotlight 的 kMDItemContentTypeTree 是苹果维护的类型树 ——
    /// Everything 得靠硬编码扩展名列表模拟的东西，这里是白拿的。
    static let macros: [String: FileKind] = [
        "image": .image, "pic": .image, "picture": .image, "图片": .image,
        "video": .movie, "movie": .movie, "视频": .movie,
        "audio": .audio, "music": .audio, "音乐": .audio,
        "pdf": .pdf,
        "text": .text, "txt": .text, "文本": .text,
        "folder": .folder, "文件夹": .folder,
        "app": .app, "application": .app, "应用": .app,
        "archive": .archive, "zip": .archive, "压缩包": .archive,
        "doc": .doc, "document": .doc, "文档": .doc,
        "code": .code, "代码": .code,
    ]

    var contentTypeTree: String {
        switch self {
        case .image:   return "public.image"
        case .movie:   return "public.movie"
        case .audio:   return "public.audio"
        case .pdf:     return "com.adobe.pdf"
        case .text:    return "public.text"
        case .folder:  return "public.folder"
        case .app:     return "com.apple.application-bundle"
        case .archive: return "public.archive"
        case .doc:     return "public.composite-content"
        case .code:    return "public.source-code"
        }
    }
}

// MARK: - 整条查询

/// 查询语法。语法参考 voidtools Everything，
/// 只保留在 Spotlight 上能真正落地的部分。
///
/// ```
/// 会议 记录                  两个词都要含，顺序无关
/// 报告|汇报 2026             (报告 或 汇报) 且 含 2026
/// 笔记 !草稿                 含「笔记」但不含「草稿」
/// "Application Support"      引号 = 字面，里面的空格和运算符都不解析
/// *.mp3                      有通配符 → 整个文件名匹配（= mp3 文件）
/// ext:jpg;png                扩展名列表
/// image: 壁纸                类型宏；也可写 kind:image
/// size:>10mb                 大小；单位 kb/mb/gb（1kb = 1024）
/// dm:today  dm:7d  dm:>2025-01-01  dm:2025-01-01..2025-01-31
/// dir:~/Documents            限目录
/// content:会议纪要             搜文件内容（Spotlight 全文索引，这块比 Everything 强）
/// ```
///
/// ⚠️ **跟 Everything 有意不同的两点**：
/// 1. Everything 里 `OR` 优先于 `AND`（`a b|c` = `a AND (b OR c)`）。这里 `|` 只在
///    **同一个 token 内部**生效，结果跟 Everything 一致，但不支持跨 token 的 `a b | c`，
///    也没有 `<>` 分组 —— 那要写完整表达式解析器，实际用不到。
/// 2. 引号在 Everything 里是「字面化」而不是「短语」，这里照抄它的语义。
///    所以内容搜索改用 `content:`（也是 Everything 的函数名），不再占用引号。
struct ParsedQuery {
    /// AND 的每一项；每一项内部是 OR（来自 `a|b`）
    var groups: [[Term]] = []
    /// `!词`：文件名里不能含
    var excluded: [Term] = []
    var content: String?
    /// `ext:jpg;png`
    var extensions: [String] = []
    var dir: String?
    var kind: FileKind?
    var size: NumericFilter?
    var date: (attribute: String, filter: DateFilter)?
    var onlyFolders = false
    var onlyFiles = false

    /// 用来算分的关键词：取最长的那个词，区分度最高
    var rankingKey: String {
        let all = groups.flatMap { $0 }.map(\.text)
        if let longest = all.max(by: { $0.count < $1.count }) { return longest }
        return content ?? ""
    }

    /// 有没有「能拿去问 Spotlight」的正向条件
    var isEmpty: Bool {
        groups.isEmpty && content == nil && extensions.isEmpty
            && kind == nil && size == nil && date == nil && !onlyFolders && !onlyFiles
    }

    // MARK: 解析

    static func parse(_ raw: String, now: Date = Date()) -> ParsedQuery {
        var q = ParsedQuery()

        for token in tokenize(raw) {
            // 引号里的内容整体当字面关键词，不再看有没有 `:` `!` `|`
            if token.isLiteral {
                q.groups.append([Term(text: token.text, isLiteral: true)])
                continue
            }

            var t = token.text
            var negated = false
            if t.hasPrefix("!"), t.count > 1 { negated = true; t.removeFirst() }

            // function:value（value 可以是空的 —— 正在打字的中间状态也要吃掉，
            // 否则会拿 "ext:" 这种半截 token 去搜一遍）
            if let colon = t.firstIndex(of: ":") {
                let name = String(t[t.startIndex..<colon]).lowercased()
                let value = String(t[t.index(after: colon)...])
                if apply(function: name, value: value, negated: negated, now: now, to: &q) { continue }
                // 不认识的 function 就当普通关键词（文件名里真的带冒号的情况）
            }

            let alternatives = t.split(separator: "|", omittingEmptySubsequences: true)
                .map { Term(text: String($0)) }
            guard !alternatives.isEmpty else { continue }
            if negated { q.excluded.append(contentsOf: alternatives) }
            else { q.groups.append(alternatives) }
        }
        return q
    }

    /// 返回 true = 这个 token 被当成 function 消化了
    private static func apply(function name: String, value: String,
                              negated: Bool, now: Date, to q: inout ParsedQuery) -> Bool {
        switch name {
        case "ext", "extension", "扩展名":
            q.extensions = value.split(separator: ";")
                .map { $0.hasPrefix(".") ? String($0.dropFirst()) : String($0) }
                .filter { !$0.isEmpty }
            return true

        case "dir", "in", "目录":
            if !value.isEmpty { q.dir = (value as NSString).expandingTildeInPath }
            return true

        case "kind", "type", "类型":
            q.kind = FileKind.macros[value.lowercased()] ?? FileKind(rawValue: value.lowercased())
            return true

        case "content", "内容":
            if !value.isEmpty { q.content = value }
            return true

        case "size", "大小":
            if !value.isEmpty { q.size = NumericFilter.parseSize(value) }
            return true

        case "dm", "datemodified", "modified", "修改":
            setDate("kMDItemContentModificationDate", value, now, &q)
            return true

        case "dc", "datecreated", "created", "创建":
            setDate("kMDItemContentCreationDate", value, now, &q)
            return true

        case "da", "dateaccessed", "used", "打开":
            setDate("kMDItemLastUsedDate", value, now, &q)
            return true

        case "file", "文件":
            guard value.isEmpty else { return false }
            if negated { q.onlyFolders = true } else { q.onlyFiles = true }
            return true

        case "folder", "文件夹":
            // `folder:` 不带值 = 只要文件夹；`folder:~/x` 当成 dir:
            if value.isEmpty {
                if negated { q.onlyFiles = true } else { q.onlyFolders = true }
            } else {
                q.dir = (value as NSString).expandingTildeInPath
            }
            return true

        default:
            // 类型宏：image: / audio: / video: / doc: …（不带值）
            if value.isEmpty, let kind = FileKind.macros[name] {
                if kind == .folder { q.onlyFolders = true } else { q.kind = kind }
                return true
            }
            return false
        }
    }

    private static func setDate(_ attribute: String, _ value: String,
                                _ now: Date, _ q: inout ParsedQuery) {
        guard !value.isEmpty, let f = DateFilter.parse(value, now: now), !f.isEmpty else { return }
        q.date = (attribute, f)
    }

    // MARK: 分词（尊重引号）

    struct RawToken { var text: String; var isLiteral: Bool }

    static func tokenize(_ raw: String) -> [RawToken] {
        var out: [RawToken] = []
        var current = ""
        var inQuotes = false

        func flush(literal: Bool) {
            if !current.isEmpty { out.append(RawToken(text: current, isLiteral: literal)) }
            current = ""
        }

        for ch in raw {
            if ch == "\"" {
                flush(literal: inQuotes)
                inQuotes.toggle()
            } else if ch == " ", !inQuotes {
                flush(literal: false)
            } else {
                current.append(ch)
            }
        }
        flush(literal: inQuotes)
        return out
    }

    // MARK: 建谓词

    /// 建给 NSMetadataQuery 用的谓词。返回 nil = 没有任何可查条件。
    func buildPredicate(includeApps: Bool) -> NSPredicate? {
        build(includeApps: includeApps) { $0.predicate() }
    }

    /// 整串查不到时的退避写法：中文逐字 AND（见 `Term.relaxedPredicate`）。
    /// 返回 nil = 没有可退的余地（没中文 / 带通配符 / 是内容搜索），engine 就别白跑一趟。
    func buildRelaxedPredicate(includeApps: Bool) -> NSPredicate? {
        guard isRelaxable else { return nil }
        return build(includeApps: includeApps) { $0.relaxedPredicate() }
    }

    /// 能不能退一步重查。
    /// - 有通配符：语义是「整名匹配」，不能拿子串判断在内存里复核，不碰
    /// - `content:`：命中的是文件内容，用文件名过滤会把对的结果误杀
    var isRelaxable: Bool {
        content == nil
            && !groups.flatMap { $0 }.contains { $0.hasWildcard }
            && groups.flatMap { $0 }.contains { !$0.cjkCharacters.isEmpty }
    }

    /// 退避重查之后在内存里做的**真正的子串判断** —— 这一步保证放宽只是扩大候选，
    /// 最终结果跟用户输入的语义完全一致，不会多出噪音。
    func matchesName(_ name: String) -> Bool {
        let n = SearchEngine.fold(name)
        for group in groups {
            guard group.contains(where: { n.contains(SearchEngine.fold($0.text)) }) else { return false }
        }
        for term in excluded where n.contains(SearchEngine.fold(term.text)) { return false }
        return true
    }

    private func build(includeApps: Bool, termPredicate: (Term) -> NSPredicate) -> NSPredicate? {
        var parts: [NSPredicate] = []

        if let content, !content.isEmpty {
            parts.append(NSPredicate(format: "kMDItemTextContent CONTAINS[cd] %@", content))
        }

        // 每组内部 OR，组之间 AND
        for group in groups {
            let subs = group.map(termPredicate)
            parts.append(subs.count == 1 ? subs[0]
                         : NSCompoundPredicate(orPredicateWithSubpredicates: subs))
        }

        if !extensions.isEmpty {
            let subs = extensions.map {
                NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*.\(Term.escape($0))")
            }
            parts.append(subs.count == 1 ? subs[0]
                         : NSCompoundPredicate(orPredicateWithSubpredicates: subs))
        }

        if let kind {
            parts.append(NSPredicate(format: "kMDItemContentTypeTree == %@", kind.contentTypeTree))
        }
        if onlyFolders {
            parts.append(NSPredicate(format: "kMDItemContentTypeTree == %@", "public.folder"))
        }
        if onlyFiles {
            parts.append(NSPredicate(format: "NOT (kMDItemContentTypeTree == %@)", "public.folder"))
        }
        if let size {
            parts.append(size.predicate(on: "kMDItemFSSize"))
        }
        if let date, let p = date.filter.predicate(on: date.attribute) {
            parts.append(p)
        }

        // 至少要有一个正向条件，否则等于「把整个磁盘拉出来再排除几个词」
        guard !parts.isEmpty else { return nil }

        for term in excluded {
            parts.append(NSCompoundPredicate(notPredicateWithSubpredicate: term.predicate()))
        }
        if !includeApps && kind != .app {
            parts.append(NSPredicate(format: "NOT (kMDItemContentTypeTree == %@)",
                                     "com.apple.application-bundle"))
        }

        // ⚠️ 只有一个条件时必须直接返回它，不能包成 NSCompoundPredicate ——
        // NSMetadataQuery 会抛 "wrong number (1) of subpredicates"，见 README 踩坑 1
        return parts.count == 1 ? parts[0]
             : NSCompoundPredicate(andPredicateWithSubpredicates: parts)
    }
}
