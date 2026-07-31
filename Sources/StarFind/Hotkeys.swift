import AppKit
import Carbon.HIToolbox

/// 全局快捷键。
///
/// 用 Carbon 的 RegisterEventHotKey 而不是 NSEvent 全局监听 ——
/// 后者要「辅助功能」权限（等于让用户授权你监听全部键盘输入），
/// 前者只注册你声明的那几个组合，不需要任何权限。为了几个快捷键
/// 去要辅助功能权限是不成比例的。
final class HotkeyManager {

    private var registered: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    /// Carbon 回调里拿不到 self，用 id → action 的表在全局侧转发
    private static var routes: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1

    var onAction: ((HotkeyAction) -> Void)?

    init() {
        installHandler()
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hkID
                )
                guard status == noErr else { return status }
                HotkeyManager.routes[hkID.id]?()
                return noErr
            },
            1, &spec, nil, &handler
        )
    }

    /// 按当前设置重新注册全部快捷键。改任何一个都整体重来，省得追增量状态。
    func reload(from settings: AppSettings) {
        unregisterAll()
        for action in HotkeyAction.allCases {
            guard let spec = settings.hotkeys[action.rawValue] else { continue }
            register(action, spec)
        }
    }

    private func register(_ action: HotkeyAction, _ spec: HotkeySpec) {
        let id = HotkeyManager.nextID
        HotkeyManager.nextID += 1
        HotkeyManager.routes[id] = { [weak self] in
            DispatchQueue.main.async {
                NSLog("[StarFind] 快捷键触发 %@", action.rawValue)
                self?.onAction?(action)
            }
        }

        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x53544644 /* 'STFD' */), id: id)
        let status = RegisterEventHotKey(
            UInt32(spec.keyCode),
            HotkeySpec.carbonModifiers(from: spec.modifiers),
            hkID, GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref {
            registered[action] = ref
            // 注册成功也打一条 —— 「快捷键没反应」时能直接用
            // `log show --predicate 'process == "StarFind"'` 分清是没注册上还是别的问题
            NSLog("[StarFind] 快捷键已注册 %@ = %@", action.rawValue, spec.displayString)
        } else {
            HotkeyManager.routes[id] = nil
            NSLog("[StarFind] 快捷键注册失败 %@ status=%d（多半是被别的 app 占了）",
                  action.rawValue, status)
        }
    }

    private func unregisterAll() {
        for (_, ref) in registered { UnregisterEventHotKey(ref) }
        registered.removeAll()
        HotkeyManager.routes.removeAll()
    }
}

// MARK: - 组合键的显示与转换

extension HotkeySpec {
    /// NSEvent.ModifierFlags → Carbon 的修饰键位
    static func carbonModifiers(from raw: UInt) -> UInt32 {
        let flags = NSEvent.ModifierFlags(rawValue: raw)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// 显示成 ⌃⌥⇧⌘K 这种
    var displayString: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + HotkeySpec.keyName(for: keyCode)
    }

    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeyNames[Int(keyCode)] { return special }
        // 普通按键按当前键盘布局翻译成字符
        if let layout = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let dataRef = TISGetInputSourceProperty(layout, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(dataRef).takeUnretainedValue() as Data
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            var deadKeys: UInt32 = 0
            let ok = data.withUnsafeBytes { raw -> Bool in
                guard let ptr = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return false }
                return UCKeyTranslate(
                    ptr, keyCode, UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeys, 4, &length, &chars
                ) == noErr
            }
            if ok, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "#\(keyCode)"
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
        kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// 只保留有意义的修饰键位，去掉 NSEvent 带的设备相关脏位
    static func cleanModifiers(_ flags: NSEvent.ModifierFlags) -> UInt {
        flags.intersection([.command, .option, .control, .shift]).rawValue
    }

    /// 没有修饰键的全局快捷键会把普通打字都吃掉，必须挡住
    static func isValid(keyCode: UInt16, modifiers: UInt) -> Bool {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return !flags.intersection([.command, .option, .control]).isEmpty
    }
}
