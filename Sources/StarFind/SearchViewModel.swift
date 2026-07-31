import AppKit
import Combine

/// 面板的状态机。UI 只读它，按键只调它的方法。
final class SearchViewModel: ObservableObject {

    @Published var queryText = "" { didSet { scheduleSearch() } }
    @Published private(set) var results: [SearchHit] = []
    @Published var selection = 0
    @Published private(set) var isSearching = false
    @Published private(set) var totalCount = 0
    /// 输入了但还没到最少字数
    @Published private(set) var needsMoreInput = false

    /// 关面板。参数 = 要不要把焦点还给召唤面板之前那个 app。
    ///
    /// ⚠️ **打开 / 在访达中显示时必须传 false**：我们刚把 Finder（或目标 app）
    /// 拉到前台，紧接着又 `prev.activate()` 把焦点抢回去，就等于自己撤销了自己。
    /// 症状是「⌘↩ 之后 Finder 确实开了，但停在原来那个全屏桌面上，没跳过去」。
    var onRequestClose: ((_ restoreFocus: Bool) -> Void)?
    var onResultsChanged: (() -> Void)?

    /// ⚠️ 选中项要按**路径**锚定，不能只记索引。
    /// gather 是分批来的（6 条 → 55 条），结果数组每次都整体替换。
    /// 只记索引的话，新一批到达后同一个索引指向的已经是另一个文件了；
    /// 更糟的是选中项在新列表里位置变了、或者被 clamp 到别处，
    /// 界面上就表现成「选中的蓝底没掉了」。
    private var anchorPath: String?

    private let engine = SearchEngine()
    private var debounce: DispatchWorkItem?
    private var settings: AppSettings { AppSettings.shared }

    init() {
        engine.onResults = { [weak self] hits, gathering, total in
            guard let self else { return }
            let resolved = SearchViewModel.resolveSelection(
                anchor: self.anchorPath, previous: self.selection, in: hits)
            self.selection = resolved.index
            self.anchorPath = resolved.anchor
            self.results = hits
            self.totalCount = total
            self.isSearching = gathering
            self.onResultsChanged?()
        }
    }

    /// 新一批结果到达时，选中项该落在哪一行。
    ///
    /// 抽成静态纯函数是为了能直接测 —— 「选中的蓝底偶尔没掉」就是这段的锅：
    /// 只按索引记选中项，gather 分批替换结果数组之后同一个索引已经指向别的文件了。
    static func resolveSelection(anchor: String?, previous: Int,
                                 in hits: [SearchHit]) -> (index: Int, anchor: String?) {
        // 锚定的文件还在 → 跟着它走
        if let anchor, let idx = hits.firstIndex(where: { $0.path == anchor }) {
            return (idx, anchor)
        }
        guard !hits.isEmpty else { return (0, nil) }
        let idx = min(max(0, previous), hits.count - 1)
        return (idx, hits[idx].path)
    }

    var selectedHit: SearchHit? {
        results.indices.contains(selection) ? results[selection] : nil
    }

    // MARK: 搜索

    /// 打字防抖。120ms —— 再短会在快速输入时把 Spotlight 反复起停，再长手感就发黏了。
    private func scheduleSearch() {
        debounce?.cancel()
        let raw = queryText.trimmingCharacters(in: .whitespaces)

        if raw.isEmpty {
            engine.stop()
            results = []; totalCount = 0; isSearching = false; needsMoreInput = false
            selection = 0; anchorPath = nil
            onResultsChanged?()
            return
        }

        // token 只写了一半（比如刚打完 `ext:`）不算正文，别急着查
        let parsed = ParsedQuery.parse(raw)
        // 「最少输入字符」只管纯关键词搜索。
        // `size:>100mb` / `image:` / `dm:today` 这种筛选本身就是完整意图，
        // 它们的 rankingKey 是空字符串，不能被这条规则挡住（挡住就永远搜不出来）。
        let hasFilter = !parsed.extensions.isEmpty || parsed.kind != nil || parsed.size != nil
            || parsed.date != nil || parsed.content != nil
            || parsed.onlyFolders || parsed.onlyFiles
        if !hasFilter, parsed.rankingKey.count < settings.minQueryLength {
            engine.stop()
            results = []; totalCount = 0; isSearching = false
            needsMoreInput = true
            onResultsChanged?()
            return
        }
        needsMoreInput = false
        isSearching = true
        // 换了关键词，上一次选中的文件不该继续锚定
        anchorPath = nil

        let work = DispatchWorkItem { [weak self] in self?.engine.search(raw) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func reset() {
        debounce?.cancel()
        engine.stop()
        queryText = ""
        results = []
        selection = 0
        anchorPath = nil
        totalCount = 0
        isSearching = false
        needsMoreInput = false
    }

    // MARK: 选择

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        select(max(0, min(results.count - 1, selection + delta)))
    }

    func moveToEdge(_ toEnd: Bool) {
        guard !results.isEmpty else { return }
        select(toEnd ? results.count - 1 : 0)
    }

    /// 所有改选中项的入口都走这里，好保证锚定路径同步更新
    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selection = index
        anchorPath = results[index].path
    }

    // MARK: 动作

    /// 面板能干的四件事。抽出来是为了把「关面板之后要不要还焦点」写成可测的规则。
    enum PanelAction: CaseIterable {
        case open, reveal, copyPath, copyFile

        /// 拷贝完要回到原来那个 app 接着粘贴，所以还焦点；
        /// 打开 / 访达中显示是**要你去那边**，还焦点等于白干。
        var restoresFocus: Bool {
            switch self {
            case .copyPath, .copyFile: return true
            case .open, .reveal:       return false
            }
        }
    }

    func activate(alternate: Bool = false) {
        guard let hit = selectedHit else { return }
        let action = settings.defaultAction
        let doReveal = alternate ? (action == .open) : (action == .reveal)
        if doReveal { reveal(hit) } else { open(hit) }
        onRequestClose?((doReveal ? PanelAction.reveal : .open).restoresFocus)
    }

    func open(_ hit: SearchHit) {
        // 用带 configuration 的新 API 而不是 `open(_:)`：能拿到最终是哪个 app 接手了，
        // 好在它把窗口开出来之后再明确激活一次。
        // 光靠 `activates = true` 不够 —— 打开一张图片时，预览 app 的窗口可能在**别的桌面**，
        // 你人还留在原来那个全屏空间里，看起来就像「按了没反应」。
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open(hit.url, configuration: cfg) { app, _ in
            guard let app else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                app.activate(options: [.activateAllWindows])
            }
        }
    }

    func reveal(_ hit: SearchHit) {
        NSWorkspace.shared.activateFileViewerSelecting([hit.url])
        // 再明确激活一次 Finder。
        // `activateFileViewerSelecting` 只保证「选中」，在别的 app 全屏时不一定把你
        // 送过去；显式 activate 才会让 macOS 切到 Finder 窗口所在的那个桌面。
        // 延一拍是等 Finder 把窗口开出来 —— 窗口还没有的时候 activate 没有目的地。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.finder")
                .first?
                .activate(options: [.activateAllWindows])
        }
    }

    func copyPath() {
        guard let hit = selectedHit else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hit.path, forType: .string)
        onRequestClose?(PanelAction.copyPath.restoresFocus)
    }

    func copyFile() {
        guard let hit = selectedHit else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([hit.url as NSURL])
        onRequestClose?(PanelAction.copyFile.restoresFocus)
    }
}
