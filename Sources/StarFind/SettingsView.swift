import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    /// ⚠️ 必须写死宽高。TabView 里套 Form 时，外层没有高度约束的话整个内容会塌成 0 高
    /// —— 现象是「设置窗口打开是空的」。SelfTest 里有一项就是量这个 fittingSize。
    static let contentSize = NSSize(width: 560, height: 500)

    var body: some View {
        TabView {
            SearchTab(settings: settings)
                .tabItem { Label(T("tab.search"), systemImage: "magnifyingglass") }
            AppearanceTab(settings: settings)
                .tabItem { Label(T("tab.appearance"), systemImage: "paintbrush") }
            GeneralTab(settings: settings)
                .tabItem { Label(T("tab.general"), systemImage: "gearshape") }
        }
        .padding(14)
        .frame(width: SettingsView.contentSize.width,
               height: SettingsView.contentSize.height)
    }
}

// MARK: - 搜索

private struct SearchTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Picker(T("scope.label"), selection: $settings.scope) {
                ForEach(SearchScope.allCases) { Text($0.localizedLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            note(T("scope.note"))

            Divider().padding(.vertical, 4)

            Toggle(T("search.filterNoise"), isOn: $settings.filterNoise)
            note(T("search.filterNoiseNote"))

            Toggle(T("search.includeApps"), isOn: $settings.includeApps)

            Divider().padding(.vertical, 4)

            Stepper(value: $settings.maxResults, in: 10...300, step: 10) {
                Text("\(T("search.maxResults"))  \(settings.maxResults)")
            }
            Stepper(value: $settings.minQueryLength, in: 1...4) {
                Text("\(T("search.minQueryLength"))  \(settings.minQueryLength)")
            }
            note(T("search.minQueryNote"))
        }
        .formStyle(.grouped)
    }
}

// MARK: - 外观

private struct AppearanceTab: View {
    @ObservedObject var settings: AppSettings

    /// ColorPicker 要 Color，设置里存的是 hex 字符串 —— 中间搭个桥
    private func colorBinding(_ hexPath: ReferenceWritableKeyPath<AppSettings, String>,
                              fallback: Color) -> Binding<Color> {
        Binding(
            get: { HexColor.color(settings[keyPath: hexPath], fallback: fallback) },
            set: { settings[keyPath: hexPath] = HexColor.hex($0) }
        )
    }

    var body: some View {
        Form {
            Picker(T("appearance.language"), selection: $settings.language) {
                ForEach(Lang.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)

            Section(T("appearance.colorSection")) {
                // 一键预设，省得自己一项项调
                HStack(spacing: 8) {
                    Button(T("preset.system")) { applyPreset(.system) }
                    Button(T("preset.dark")) { applyPreset(.dark) }
                    Button(T("preset.darker")) { applyPreset(.darker) }
                    Button(T("preset.black")) { applyPreset(.black) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Picker(T("appearance.mode"), selection: $settings.panelAppearance) {
                    ForEach(PanelAppearance.allCases) { Text($0.localizedLabel).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker(T("appearance.material"), selection: $settings.panelMaterial) {
                    ForEach(PanelMaterial.allCases) { Text($0.localizedLabel).tag($0) }
                }
                note(T("appearance.materialNote"))

                ColorPicker(T("appearance.tintColor"),
                            selection: colorBinding(\.panelTintHex, fallback: .black),
                            supportsOpacity: false)
                VStack(alignment: .leading) {
                    Text("\(T("appearance.tintOpacity"))  \(Int(settings.panelTintOpacity * 100))%")
                    Slider(value: $settings.panelTintOpacity, in: 0...0.85, step: 0.01)
                }
                note(T("appearance.tintNote"))

                ColorPicker(T("appearance.highlightColor"),
                            selection: colorBinding(\.highlightHex,
                                                    fallback: Color(red: 0.18, green: 0.44, blue: 0.88)),
                            supportsOpacity: false)
                VStack(alignment: .leading) {
                    Text("\(T("appearance.highlightOpacity"))  \(Int(settings.highlightOpacity * 100))%")
                    Slider(value: $settings.highlightOpacity, in: 0.3...1, step: 0.01)
                }

                // 现场预览，不用反复开面板对比
                preview
            }

            Section {
                Toggle(T("appearance.showPreview"), isOn: $settings.showPreview)
                note(T("appearance.previewNote"))

                VStack(alignment: .leading) {
                    Text("\(T("appearance.panelWidth"))  \(Int(settings.panelWidth)) pt")
                    Slider(value: $settings.panelWidth, in: 520...1200, step: 20)
                }
                Stepper(value: $settings.rowCount, in: 4...16) {
                    Text("\(T("appearance.rowCount"))  \(settings.rowCount)")
                }
                Picker(T("appearance.defaultAction"), selection: $settings.defaultAction) {
                    ForEach(DefaultAction.allCases) { Text($0.localizedLabel).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 缩略预览：毛玻璃 + 叠色 + 一条选中行 + 一条普通行
    private var preview: some View {
        VStack(spacing: 0) {
            row(T("appearance.previewSelected"), selected: true)
            row(T("appearance.previewNormal"), selected: false)
        }
        .background(
            VisualEffect(material: settings.panelMaterial.nsMaterial)
                .overlay(HexColor.color(settings.panelTintHex, fallback: .black)
                    .opacity(settings.panelTintOpacity))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .preferredColorScheme(settings.panelAppearance == .dark ? .dark
                              : settings.panelAppearance == .light ? .light : nil)
    }

    private func row(_ text: String, selected: Bool) -> some View {
        HStack {
            Image(systemName: "doc")
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(selected
                    ? HexColor.color(settings.highlightHex,
                                     fallback: Color(red: 0.18, green: 0.44, blue: 0.88))
                        .opacity(settings.highlightOpacity)
                    : Color.clear)
    }

    private enum Preset { case system, dark, darker, black }

    private func applyPreset(_ p: Preset) {
        switch p {
        case .system:
            settings.panelAppearance = .system
            settings.panelMaterial = .sidebar
            settings.panelTintHex = "#000000"
            settings.panelTintOpacity = 0
        case .dark:
            settings.panelAppearance = .dark
            settings.panelMaterial = .sidebar
            settings.panelTintHex = "#000000"
            settings.panelTintOpacity = 0.18
        case .darker:
            settings.panelAppearance = .dark
            settings.panelMaterial = .hudWindow
            settings.panelTintHex = "#000000"
            settings.panelTintOpacity = 0.32
        case .black:
            settings.panelAppearance = .dark
            settings.panelMaterial = .hudWindow
            settings.panelTintHex = "#000000"
            settings.panelTintOpacity = 0.62
        }
    }
}

// MARK: - 通用

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @State private var loginError: String?
    /// 缺哪几个目录的权限。放 @State 里是为了点完「请求访问」能立刻刷新。
    @State private var missingAccess: [ProtectedFolder] = FileAccess.missing()

    var body: some View {
        Form {
            // ⚠️ 放在最前面：没这个权限的话「文稿 / 桌面 / 下载」里的文件
            // **搜索结果里根本不会出现**（只有 .app 例外）。见 FileAccess.swift
            Section(T("access.section")) {
                ForEach(ProtectedFolder.allCases) { folder in
                    HStack {
                        let ok = !missingAccess.contains(folder)
                        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(ok ? Color.green : Color.orange)
                        Text(folder.localizedLabel)
                        Spacer()
                        Text(ok ? T("access.granted") : T("access.denied"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                note(T("access.note"))
                HStack {
                    Button(T("access.request")) {
                        FileAccess.requestAll()
                        missingAccess = FileAccess.missing()
                    }
                    Button(T("access.openSettings")) { FileAccess.openSystemSettings() }
                }
                if !missingAccess.isEmpty { note(T("access.deniedNote")) }
            }

            Section(T("general.hotkey")) {
                ForEach(HotkeyAction.allCases) { action in
                    HotkeyRow(action: action, settings: settings)
                }
                note(T("hotkey.note"))
            }

            Section(T("general.spaceBehavior")) {
                Picker(T("general.spaceBehavior"), selection: $settings.panelSpaceBehavior) {
                    ForEach(PanelSpaceBehavior.allCases) {
                        Text($0.localizedLabel).tag($0)
                    }
                }
                .pickerStyle(.segmented)
                note(T("spaceBehavior.note"))
            }

            Section {
                Toggle(T("general.launchAtLogin"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { on in
                        loginError = LoginItem.set(on)
                        settings.launchAtLogin = LoginItem.isEnabled
                    }
                ))
                if !LoginItem.isInStableLocation {
                    note(T("general.loginUnstable"))
                } else {
                    note(T("general.loginNote"))
                }
                if LoginItem.state == .requiresApproval {
                    note(T("general.loginNeedsApproval"))
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Button(T("general.openLoginItems")) { LoginItem.openLoginItemsSettings() }
            }

            Section(T("general.rebuildIndex")) {
                note(T("general.rebuildNote"))
                note(T("general.about"))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 快捷键录制

private struct HotkeyRow: View {
    let action: HotkeyAction
    @ObservedObject var settings: AppSettings
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(action.localizedLabel)
            Spacer()
            Button(label) { recording ? stop() : start() }
                .buttonStyle(.bordered)
                .frame(minWidth: 130)
            Button(T("hotkey.clear")) {
                settings.hotkeys[action.rawValue] = nil
                NotificationCenter.default.post(name: .starFindHotkeysChanged, object: nil)
            }
            .buttonStyle(.borderless)
            .disabled(settings.hotkeys[action.rawValue] == nil)
        }
    }

    private var label: String {
        if recording { return T("hotkey.recording") }
        if let spec = settings.hotkeys[action.rawValue] { return spec.displayString }
        return T("hotkey.record")
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = HotkeySpec.cleanModifiers(event.modifierFlags)
            if Int(event.keyCode) == 53 { stop(); return nil }          // Esc = 取消
            guard HotkeySpec.isValid(keyCode: event.keyCode, modifiers: mods) else { return nil }
            settings.hotkeys[action.rawValue] = HotkeySpec(keyCode: event.keyCode, modifiers: mods)
            NotificationCenter.default.post(name: .starFindHotkeysChanged, object: nil)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - 小工具

@ViewBuilder
private func note(_ text: String) -> some View {
    Text(text)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
}

extension Notification.Name {
    static let starFindHotkeysChanged = Notification.Name("starFindHotkeysChanged")
}
