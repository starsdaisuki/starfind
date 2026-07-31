# 面板通知、节流与键盘事件

StarFind 的引擎测试不能覆盖所有 UI 故障。`NSMetadataQuery` 的批量通知、SwiftUI 状态更新、
`NSPanel` 焦点和 macOS 主菜单会组合出只在真实面板中出现的问题。

## `make panel` 诊断模式

```bash
make panel Q=report
```

它会：

1. 通过 `open` 使用真实 app 身份启动 StarFind。
2. 显示真实搜索面板。
3. 将文字键事件逐个送入字段编辑器。
4. 对比面板最终状态与独立引擎查询。

验证键盘事件时必须确保 StarFind 是激活应用且面板拥有 key window。

## 收工后的更新不能被节流丢掉

`NSMetadataQuery` 会批量发送以下通知：

- `NSMetadataQueryGatheringProgress`
- `NSMetadataQueryDidFinishGathering`
- `NSMetadataQueryDidUpdate`

最终两个通知可能靠得非常近。如果节流逻辑对后一次更新直接 `return`，
而之后没有更多通知，界面就会永久停留在中间批次。

StarFind 的 `emitDecision` 只有两种结果：

- 立即 emit
- 在剩余节流窗口后补做一次 emit

延后任务会携带查询代次号，旧查询的任务不能覆盖新查询。查询收工后还会再复核一次结果数。

## 文本编辑快捷键需要主菜单

`NSApp.mainMenu == nil` 时，搜索框可以输入文字，但 `⌘A`、`⌘V`、`⌘X` 和 `⌘Z` 等标准操作
可能不会通过响应链正常分发。只给状态栏图标配置 `NSMenu` 不足以解决这个问题。

StarFind 创建一个符合 AppKit 预期的主菜单，并将 action 的 target 留为 `nil`，让响应链选择字段编辑器。
`⌘C` 需要特别处理：字段内有文本选区时保留系统复制，否则复制当前结果路径。

## 打开结果时不要抢回焦点

通过 `Esc` 关闭面板时，恢复之前的应用是合理的。但打开文件或在访达中显示时，
如果在目标窗口出现后又激活之前的应用，用户会被拉回原 Space。

`PanelAction.restoresFocus` 将规则写成可测试的纯函数：

- 关闭、复制路径：恢复原应用
- 打开、在访达中显示：不恢复，激活最终接管的目标应用

## 回归验证

`make test` 检查节流决策、主菜单键等价项和焦点恢复规则。
`make panel` 则覆盖必须依赖真实窗口、字段编辑器和键盘事件的端到端路径。
