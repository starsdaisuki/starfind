# StarFind

[English](README.md) · **简体中文**

StarFind 是一个轻量的 macOS 文件搜索面板。按下全局快捷键，输入文件名或筛选条件，
然后直接打开、在访达中显示或复制路径。

StarFind 直接查询 macOS Spotlight 索引，不建立自己的文件数据库，不联网，也不包含遥测。

## 下载

从 [GitHub Releases](https://github.com/starsdaisuki/starfind/releases/latest) 下载最新版 Apple 芯片构建。
打开 DMG，把 StarFind 拖入「应用程序」；当前版本需要 macOS 14 或更高版本。

应用目前使用 ad-hoc 签名，尚未经过 Apple 公证。如果 macOS 提示下载的应用“已损坏”，
复制到「应用程序」后移除 quarantine 属性：

```bash
xattr -dr com.apple.quarantine /Applications/StarFind.app
open /Applications/StarFind.app
```

## 功能

- 全局快捷键唤起 Spotlight 式无边框面板
- Everything 式查询：AND、OR、排除、通配符、扩展名、类型、大小、日期和目录筛选
- 通过 Spotlight 全文索引搜索文件内容
- Quick Look 预览、中英文界面、开机启动和可自定义快捷键
- 可配置的深浅外观、毛玻璃材质、叠加色和选中色
- 两种跨 Space 行为：跟随召唤桌面，或在所有 Space 显示
- 153 项内建自检，覆盖查询解析、排序、设置、窗口和真实 Spotlight 查询

## 系统要求

- macOS 14 或更高版本
- Swift 6 工具链（源码使用 Swift 5 语言模式）

## 从源码安装

```bash
git clone https://github.com/starsdaisuki/starfind.git
cd starfind
make install
```

`make install` 会构建 ad-hoc 签名的应用，并安装到 `~/Applications/StarFind.app`。
默认快捷键是 `⌥'`，可在设置中修改。

如果只想构建：

```bash
make bundle
open build/StarFind.app
```

## 查询语法

### 基本运算

| 输入 | 含义 |
|---|---|
| `会议 记录` | 文件名同时包含两个词，顺序无关 |
| `报告|汇报` | 包含任意一个词 |
| `笔记 !草稿` | 包含「笔记」但排除「草稿」 |
| `"Application Support"` | 引号内容按字面量处理 |
| `*.mp3` | 有通配符时对整个文件名匹配 |

### 筛选器

| 输入 | 含义 |
|---|---|
| `ext:jpg;png` | 扩展名列表 |
| `image:` `video:` `audio:` `doc:` `code:` `app:` | 类型宏 |
| `file:` `folder:` | 只要文件或文件夹 |
| `size:>10mb` `size:2mb..10mb` | 文件大小 |
| `dm:today` `dm:7d` | 修改时间；`dc:` 表示创建，`da:` 表示上次打开 |
| `dm:>2025-01-01` `dm:2025-01-01..2025-01-31` | ISO 8601 日期比较 |
| `dir:~/Documents` | 限定目录及其子目录 |
| `content:会议纪要` | 搜索 Spotlight 全文索引 |

组合示例：

```text
ext:md 报告 !archive dm:7d
image: 壁纸 size:>2mb
content:会议纪要 dir:~/Documents
```

`|` 只在同一个 token 内生效。StarFind 没有实现 Everything 的跨 token 分组表达式。

## 权限与隐私

StarFind 的搜索和排序都在本机完成。源码中没有网络请求、账号系统或遥测 SDK。

macOS 会按应用的 TCC 权限过滤 Spotlight 结果。如果没有授权，「桌面」、「文稿」和「下载」
中的普通文件可能不会出现。StarFind 会在启动时请求这些目录的访问权限，并在设置里显示状态。

StarFind 不需要辅助功能权限。

## 快捷键

| 按键 | 动作 |
|---|---|
| `↑` / `↓` | 切换结果 |
| `↩` | 执行默认动作 |
| `⌘↩` | 在访达中显示 |
| `⌥↩` | 使用「打开方式」 |
| `⌘C` | 有文本选区时复制文本，否则复制结果路径 |
| `Space` | 显示或隐藏预览 |
| `Esc` | 关闭面板 |

## 开发与验证

```bash
make test
```

自检在一次性 UserDefaults suite 中运行，不会修改用户的正式设置域。

还可以使用三个诊断命令：

```bash
make query Q=report   # 打印谓词、Spotlight 结果和排序
make type Q=report    # 模拟连续输入
make panel Q=report   # 在真实面板中跑端到端验证
```

`make panel` 会真正显示窗口并发送键盘事件，不建议在无图形会话的 CI 环境中运行。

## 代码结构

| 路径 | 职责 |
|---|---|
| `SearchEngine.swift` | NSMetadataQuery 生命周期、排序、过滤和节流 |
| `QuerySyntax.swift` | 查询分词、筛选器和 NSPredicate 生成 |
| `SearchViewModel.swift` | 结果、选中态和文件动作 |
| `SearchPanel.swift` | NSPanel、快捷键、焦点和 Space 行为 |
| `SearchView.swift` | SwiftUI 结果列表和预览布局 |
| `AppSettings.swift` | UserDefaults 设置层 |
| `FileAccess.swift` | TCC 受保护目录的权限检查 |
| `SelfTest.swift` | 153 项自检与回归验证 |

## 实现笔记

- [中文文件名的 Spotlight 分词](docs/spotlight-cjk-tokenization.zh-CN.md)
- [Spotlight 结果与 TCC 权限](docs/spotlight-permission-filtering.zh-CN.md)
- [面板通知、节流与键盘事件](docs/panel-layer-bugs.zh-CN.md)
- [跨 Space 窗口行为](docs/window-space-behavior.zh-CN.md)

这些文档保留可复用的技术结论和验证方法，不依赖特定机器或用户数据。

## 已知限制

- 当前构建使用 ad-hoc 签名，尚未提供 Apple Developer ID 签名和公证。
- 无权访问受 TCC 保护的目录时，Spotlight 会过滤部分结果。
- 查询能力受 Spotlight 索引范围和分词规则限制。

## 许可

[MIT](LICENSE)
