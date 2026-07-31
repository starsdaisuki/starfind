import SwiftUI
import AppKit

/// 图标很贵，缓存住。普通文件按扩展名缓存就够（同扩展名图标一样），
/// 只有 .app 和文件夹才按路径缓存 —— 它们可能有自定义图标。
enum IconCache {
    private static var byKey: [String: NSImage] = [:]

    static func icon(forPath path: String) -> NSImage {
        let ext = (path as NSString).pathExtension.lowercased()
        let isSpecial = ext == "app" || ext.isEmpty
        let key = isSpecial ? path : "ext:" + ext
        if let cached = byKey[key] { return cached }

        let img = NSWorkspace.shared.icon(forFile: path)
        img.size = NSSize(width: 32, height: 32)
        if byKey.count > 600 { byKey.removeAll() }   // 粗暴但够用
        byKey[key] = img
        return img
    }
}

struct SearchView: View {
    @ObservedObject var vm: SearchViewModel
    @ObservedObject var settings = AppSettings.shared
    var focusToken: Int

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            if showsBody {
                Divider().opacity(0.6)
                bodyArea
                Divider().opacity(0.6)
                footer
            }
        }
        .background(
            VisualEffect(material: settings.panelMaterial.nsMaterial)
                .overlay(tintColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }

    private var showsBody: Bool { SearchView.shouldShowBody(vm) }

    /// 盖在毛玻璃上的一层色。opacity = 0 就是纯系统外观。
    private var tintColor: Color {
        HexColor.color(settings.panelTintHex, fallback: .black)
            .opacity(settings.panelTintOpacity)
    }

    /// ⚠️ 选中行的底色**不用 `Color.accentColor`**。
    /// accent 会跟着窗口 key 状态和系统强调色变，而这个面板是 nonactivating panel，
    /// 预览窗格里 QLPreviewView 加载视频/文件夹时还可能抢走 key ——
    /// 表现就是「选中的蓝底偶尔没掉」。用一个自己存的确定颜色，跟 key 状态彻底脱钩。
    private var highlightColor: Color {
        HexColor.color(settings.highlightHex, fallback: Color(red: 0.18, green: 0.44, blue: 0.88))
            .opacity(settings.highlightOpacity)
    }

    // MARK: 尺寸（PanelController 要用同一套算法，所以放静态方法里，避免两边算出不同的高度）

    static let barHeight: CGFloat = 58
    static let footerHeight: CGFloat = 30
    static let messageHeight: CGFloat = 62
    static let rowHeightValue: CGFloat = 46

    /// 缺权限时给一句人话；权限齐全就返回 nil（照常显示语法提示）。
    /// 抽成静态方法是为了能在 `make test` 里直接量。
    static func missingAccessHint(_ missing: [ProtectedFolder] = FileAccess.missing()) -> String? {
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.localizedLabel).joined(separator: " / ")
        return T("panel.needAccess").replacingOccurrences(of: "%@", with: names)
    }

    static func shouldShowBody(_ vm: SearchViewModel) -> Bool {
        !vm.results.isEmpty || vm.needsMoreInput || (!vm.queryText.isEmpty && !vm.isSearching)
    }

    static func bodyListHeight(_ vm: SearchViewModel, _ settings: AppSettings) -> CGFloat {
        let rows = CGFloat(min(vm.results.count, settings.rowCount))
        let natural = rows * rowHeightValue
        return settings.showPreview ? max(natural, 300) : natural
    }

    /// 面板总高度。搜索栏 + 分隔线 + 主体 + 分隔线 + 底部条。
    static func contentHeight(vm: SearchViewModel, settings: AppSettings) -> CGFloat {
        guard shouldShowBody(vm) else { return barHeight }
        let body = (vm.needsMoreInput || vm.results.isEmpty) ? messageHeight : bodyListHeight(vm, settings)
        return barHeight + 1 + body + 1 + footerHeight
    }

    // MARK: 搜索栏

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(.secondary)

            QueryField(text: $vm.queryText,
                       placeholder: T("panel.placeholder"),
                       focusToken: focusToken)
                .frame(height: 32)

            if vm.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: SearchView.barHeight)
    }

    // MARK: 主体

    @ViewBuilder
    private var bodyArea: some View {
        if vm.needsMoreInput {
            message(T("panel.typeMore"), hint: T("panel.hintTokens"))
        } else if vm.results.isEmpty {
            // 「搜不到」最常见的原因不是关键词写错，是**没有文件访问权限** ——
            // 没授权的话 Spotlight 压根不把「文稿 / 桌面 / 下载」里的东西回给我们。
            // 与其让用户以为是自己没搜对，不如直接说破。见 FileAccess.swift
            message(T("panel.noResults"),
                    hint: SearchView.missingAccessHint() ?? T("panel.hintTokens"))
        } else {
            HStack(spacing: 0) {
                resultList
                if settings.showPreview, let hit = vm.selectedHit {
                    Divider().opacity(0.6)
                    VStack(spacing: 0) {
                        PreviewPane(url: hit.url)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider().opacity(0.4)
                        FileInfoStrip(hit: hit)
                    }
                    .frame(width: previewWidth)
                }
            }
            .frame(height: listHeight)
        }
    }

    private var previewWidth: CGFloat { max(240, settings.panelWidth * 0.42) }

    private var listHeight: CGFloat { SearchView.bodyListHeight(vm, settings) }

    private func message(_ title: String, hint: String) -> some View {
        VStack(spacing: 5) {
            Text(title).font(.system(size: 13)).foregroundStyle(.secondary)
            Text(hint).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: SearchView.messageHeight)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(vm.results.enumerated()), id: \.element.id) { idx, hit in
                        ResultRow(hit: hit,
                                  selected: idx == vm.selection,
                                  highlight: highlightColor)
                            // ⚠️ 滚动用的 id 要跟 ForEach 的身份一致（都用路径）。
                            // 之前 ForEach 按 hit.id 认身份、这里又 .id(idx)，
                            // 两套身份混用会让 SwiftUI 在列表更新时错配视图。
                            .id(hit.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { vm.select(idx); vm.activate() }
                            .onTapGesture { vm.select(idx) }
                    }
                }
            }
            .onChange(of: vm.selection) { _, _ in
                guard let id = vm.selectedHit?.id else { return }
                withAnimation(.easeOut(duration: 0.08)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 14) {
            Text("\(vm.totalCount > vm.results.count ? "\(vm.results.count)/\(vm.totalCount)" : "\(vm.results.count)") \(T("panel.resultsCount"))")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            keyHint("↩", settings.defaultAction == .open ? T("key.open") : T("key.reveal"))
            keyHint("⌘↩", settings.defaultAction == .open ? T("key.reveal") : T("key.open"))
            keyHint("⌘C", T("key.copyPath"))
            keyHint("⎋", T("key.close"))
        }
        .padding(.horizontal, 14)
        .frame(height: SearchView.footerHeight)
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 单行

private struct ResultRow: View {
    let hit: SearchHit
    let selected: Bool
    let highlight: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: IconCache.icon(forPath: hit.path))
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(hit.name)
                    .font(.system(size: 13, weight: selected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hit.displayDirectory)
                    .font(.system(size: 10.5))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
        }
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 14)
        .frame(height: SearchView.rowHeightValue)
        .background(selected ? highlight : Color.clear)
    }
}

// MARK: - 毛玻璃背景

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        // .active 而不是 .followsWindowActiveState —— 面板是 nonactivating 的，
        // 跟随窗口状态会让它在失焦时突然变灰
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        if v.material != material { v.material = material }
    }
}
