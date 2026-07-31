import AppKit

// LSUIElement app：没有 Dock 图标，只有菜单栏和那个搜索面板。
// 入口手写而不是用 @main —— SwiftPM 的可执行 target 里 main.swift 就是入口，
// 用 @main 反而会跟它冲突。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
