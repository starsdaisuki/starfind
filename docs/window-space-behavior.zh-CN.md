# StarFind 跨 Space 窗口行为

[English](window-space-behavior.md) · **简体中文**

StarFind 的搜索面板是一个 `NSPanel`。macOS 的 Space、全屏应用、Mission Control 和窗口集合行为
会共同决定面板在哪个桌面出现，以及切换桌面后是否仍然可见。

## 设计目标

- 快捷键应在当前 Space 上可用
- 面板不应在切换 Space 时意外失去焦点或瞬移
- 用户可选择 Spotlight 式的「只属于召唤桌面」行为
- 也可选择让同一个面板跟随到所有 Space

## 状态模型

StarFind 分开记录：

- 用户是否明确要求显示面板
- 面板当前是否可见
- 当前显示代次
- Space 切换前后的窗口标识

不能仅依赖 `window.isVisible`。在 Space 过渡期间，AppKit 可能短暂报告旧窗口状态，
延迟到达的关闭事件也不能关掉新 Space 上刚刚召唤的面板。

## Spotlight 模式

Spotlight 模式是默认选项：

- 面板属于召唤它的 Space
- 切换 Space 会结束旧面板会话
- 在新 Space 上再次按快捷键会创建新的显示代次

此模式不使用 `.canJoinAllSpaces`，避免面板在多个桌面之间保持同一窗口实例。

## 所有 Space 模式

该模式使用 `.canJoinAllSpaces`：

- 同一个面板可以在所有 Space 显示
- Space 切换本身不会结束查询会话
- 关闭、打开结果或再次按快捷键才会结束面板会话

## 配置更新

切换模式时需要同时更新：

1. `NSPanel.collectionBehavior`
2. 当前的显示意图
3. Space 变更观察者对旧代次的处理

只改设置值而不重新应用 `collectionBehavior` 会导致界面显示已切换，窗口行为却仍是旧模式。

## 回归验证

`SelfTest.testPanelVisibilityIntent` 验证显示意图和代次规则。手工验证应覆盖：

- 普通 Space 之间切换
- 普通 Space 与全屏应用之间切换
- 在切换动画中快速重复按快捷键
- 打开文件、在访达中显示与 `Esc` 关闭时的焦点去向
