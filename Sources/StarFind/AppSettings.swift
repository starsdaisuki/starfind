import Foundation
import AppKit
import Combine

/// 搜索范围
enum SearchScope: String, CaseIterable, Identifiable {
    case home       // 只搜个人目录（默认，噪音最少）
    case computer   // 整机

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .home: return T("scope.home")
        case .computer: return T("scope.computer")
        }
    }

    var metadataScope: String {
        switch self {
        case .home: return NSMetadataQueryUserHomeScope
        case .computer: return NSMetadataQueryLocalComputerScope
        }
    }
}

/// 回车时的默认动作
enum DefaultAction: String, CaseIterable, Identifiable {
    case open       // 用默认程序打开
    case reveal     // 在访达中显示

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .open: return T("action.open")
        case .reveal: return T("action.reveal")
        }
    }
}

/// 搜索面板切换 macOS Space 时的行为。
enum PanelSpaceBehavior: String, CaseIterable, Identifiable {
    /// 跟系统 Spotlight 一样：面板属于召唤它的 Space，切走就结束这次会话。
    case spotlight
    /// 面板跟着用户进入每一个 Space，直到再次按热键或主动关闭。
    case followAllSpaces

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .spotlight: return T("spaceBehavior.spotlight")
        case .followAllSpaces: return T("spaceBehavior.followAllSpaces")
        }
    }
}

/// 能绑全局快捷键的动作。目前只有一个：唤起搜索面板。
enum HotkeyAction: String, CaseIterable, Identifiable {
    case toggleSearch

    var id: String { rawValue }
    var localizedLabel: String {
        switch self {
        case .toggleSearch: return T("hotkey.toggleSearch")
        }
    }
}

struct HotkeySpec: Codable, Equatable {
    var keyCode: UInt16
    var modifiers: UInt
}

/// 全局设置。
///
/// ⚠️⚠️ `isSaving` / `hasUnsavedChanges` 用来防止写入期间的通知回读覆盖未落盘值：
/// save() 是逐键写 UserDefaults 的，写第一个键就会触发 didChangeNotification，
/// 如果这时候 load() 回读，还没写的键会被磁盘上的旧值覆盖回去 ——
/// 表现就是「界面上点一下就弹回原样」。改这个文件之后必须跑 `make test`。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// ⚠️ 是 var 不是 let —— 自检要把整个设置层切到一次性 suite，
    /// 绝对不能碰用户的真实设置域。见 `useDefaultsSuite(_:)`。
    private var defaults = UserDefaults.standard
    private var defaultsObserver: NSObjectProtocol?
    private var loading = true
    private var isSaving = false
    private var hasUnsavedChanges = false

    // MARK: 搜索
    @Published var scope: SearchScope = .home
    @Published var filterNoise = true          // 过滤 Library / node_modules / 缓存等
    @Published var includeApps = true          // 结果里带上 .app
    @Published var maxResults = 60
    @Published var minQueryLength = 2

    // MARK: 界面
    @Published var language: Lang = .zh
    @Published var showPreview = true
    /// 面板明暗。默认强制深色，保持面板对比度。
    @Published var panelAppearance: PanelAppearance = .dark
    @Published var panelMaterial: PanelMaterial = .hudWindow
    /// 盖在毛玻璃上的一层颜色。opacity = 0 就是纯系统外观。
    @Published var panelTintHex = "#000000"
    @Published var panelTintOpacity: Double = 0.28
    /// 选中行的底色。**不用 Color.accentColor** —— 见 SearchView 里的注释
    @Published var highlightHex = "#2F6FE0"
    @Published var highlightOpacity: Double = 0.95
    @Published var panelWidth: Double = 760
    @Published var rowCount = 9                // 面板里一次显示几行
    @Published var defaultAction: DefaultAction = .open
    @Published var panelSpaceBehavior: PanelSpaceBehavior = .spotlight

    // MARK: 通用
    @Published var launchAtLogin = false
    @Published var hotkeys: [String: HotkeySpec] = [
        // 默认 ⌥'：macOS 未占用这个组合，且单手容易按到。
        HotkeyAction.toggleSearch.rawValue: HotkeySpec(
            keyCode: 39 /* kVK_ANSI_Quote */,
            modifiers: NSEvent.ModifierFlags.option.rawValue
        )
    ]

    private var bag = Set<AnyCancellable>()

    private init() {
        load()
        loading = false

        // 立刻标记「有未写盘的改动」，不能等 debounce —— 那 300ms 正是危险窗口
        objectWillChange
            .sink { [weak self] in self?.hasUnsavedChanges = true }
            .store(in: &bag)

        objectWillChange
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
            .store(in: &bag)

        observeDefaults()
    }

    /// 外部（CLI / `defaults` 命令）改了偏好时同步进来，但要躲开自己写盘的那一段
    private func observeDefaults() {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            guard let self, !self.isSaving, !self.hasUnsavedChanges else { return }
            self.load()
        }
    }

    /// 把整个设置层切到另一个 UserDefaults suite。**只给自检用。**
    ///
    /// ⚠️⚠️ 为什么必须有这个：自检要翻转设置才能验读写，原来是直接翻真实域再还原。
    /// 「进程被 kill 就还原不了」那个坑早就修了（快照落盘），但还有**第二个坑**，
    /// 而且它在正常跑完的情况下也会发生 ——
    ///
    /// **用户的 app 这时候正跑着。** 自检往磁盘写翻转值 → 跑着的那个实例收到
    /// `didChangeNotification`、把翻转值读进内存 → 自检还原磁盘 → 那个实例过一会儿
    /// 自己 `save()`，把内存里的翻转值又写回磁盘。**还原被覆盖掉了。**
    ///
    /// 这是一个典型的跨进程竞态：测试即使在磁盘上还原了设置，
    /// 另一个正在运行的实例仍可能把内存中的中间值写回。
    /// 正解是让测试使用完全独立的 UserDefaults suite。
    func useDefaultsSuite(_ suite: UserDefaults) {
        let wasLoading = loading
        loading = true
        defaults = suite
        observeDefaults()
        loading = wasLoading
        load()
    }

    // MARK: - 读写

    func load() {
        let wasLoading = loading
        loading = true
        defer { loading = wasLoading }

        if let v = defaults.string(forKey: "scope"), let s = SearchScope(rawValue: v) { setIfChanged(\.scope, s) }
        if defaults.object(forKey: "filterNoise") != nil { setIfChanged(\.filterNoise, defaults.bool(forKey: "filterNoise")) }
        if defaults.object(forKey: "includeApps") != nil { setIfChanged(\.includeApps, defaults.bool(forKey: "includeApps")) }
        if defaults.object(forKey: "maxResults") != nil { setIfChanged(\.maxResults, max(10, min(300, defaults.integer(forKey: "maxResults")))) }
        if defaults.object(forKey: "minQueryLength") != nil { setIfChanged(\.minQueryLength, max(1, min(4, defaults.integer(forKey: "minQueryLength")))) }

        if let v = defaults.string(forKey: "language"), let l = Lang(rawValue: v) { setIfChanged(\.language, l) }
        if defaults.object(forKey: "showPreview") != nil { setIfChanged(\.showPreview, defaults.bool(forKey: "showPreview")) }
        if let v = defaults.string(forKey: "panelAppearance"), let a = PanelAppearance(rawValue: v) { setIfChanged(\.panelAppearance, a) }
        if let v = defaults.string(forKey: "panelMaterial"), let m = PanelMaterial(rawValue: v) { setIfChanged(\.panelMaterial, m) }
        if let v = defaults.string(forKey: "panelTintHex"), HexColor.nsColor(v) != nil { setIfChanged(\.panelTintHex, v) }
        if defaults.object(forKey: "panelTintOpacity") != nil { setIfChanged(\.panelTintOpacity, min(1, max(0, defaults.double(forKey: "panelTintOpacity")))) }
        if let v = defaults.string(forKey: "highlightHex"), HexColor.nsColor(v) != nil { setIfChanged(\.highlightHex, v) }
        if defaults.object(forKey: "highlightOpacity") != nil { setIfChanged(\.highlightOpacity, min(1, max(0.2, defaults.double(forKey: "highlightOpacity")))) }
        if defaults.object(forKey: "panelWidth") != nil { setIfChanged(\.panelWidth, max(520, min(1200, defaults.double(forKey: "panelWidth")))) }
        if defaults.object(forKey: "rowCount") != nil { setIfChanged(\.rowCount, max(4, min(16, defaults.integer(forKey: "rowCount")))) }
        if let v = defaults.string(forKey: "defaultAction"), let a = DefaultAction(rawValue: v) { setIfChanged(\.defaultAction, a) }
        if let v = defaults.string(forKey: "panelSpaceBehavior"),
           let behavior = PanelSpaceBehavior(rawValue: v) {
            setIfChanged(\.panelSpaceBehavior, behavior)
        }

        setIfChanged(\.launchAtLogin, LoginItem.isEnabled)

        if let data = defaults.data(forKey: "hotkeys"),
           let map = try? JSONDecoder().decode([String: HotkeySpec].self, from: data) {
            setIfChanged(\.hotkeys, map)
        }
    }

    func save() {
        guard !loading else { return }
        isSaving = true
        defer { isSaving = false; hasUnsavedChanges = false }

        defaults.set(scope.rawValue, forKey: "scope")
        defaults.set(filterNoise, forKey: "filterNoise")
        defaults.set(includeApps, forKey: "includeApps")
        defaults.set(maxResults, forKey: "maxResults")
        defaults.set(minQueryLength, forKey: "minQueryLength")

        defaults.set(language.rawValue, forKey: "language")
        defaults.set(showPreview, forKey: "showPreview")
        defaults.set(panelAppearance.rawValue, forKey: "panelAppearance")
        defaults.set(panelMaterial.rawValue, forKey: "panelMaterial")
        defaults.set(panelTintHex, forKey: "panelTintHex")
        defaults.set(panelTintOpacity, forKey: "panelTintOpacity")
        defaults.set(highlightHex, forKey: "highlightHex")
        defaults.set(highlightOpacity, forKey: "highlightOpacity")
        defaults.set(panelWidth, forKey: "panelWidth")
        defaults.set(rowCount, forKey: "rowCount")
        defaults.set(defaultAction.rawValue, forKey: "defaultAction")
        defaults.set(panelSpaceBehavior.rawValue, forKey: "panelSpaceBehavior")

        if let data = try? JSONEncoder().encode(hotkeys) {
            defaults.set(data, forKey: "hotkeys")
        }
    }

    /// 幂等赋值 —— 让 load() 可以被外部变更重复调用而不产生多余的 objectWillChange
    private func setIfChanged<V: Equatable>(_ kp: ReferenceWritableKeyPath<AppSettings, V>, _ new: V) {
        if self[keyPath: kp] != new { self[keyPath: kp] = new }
    }
}
