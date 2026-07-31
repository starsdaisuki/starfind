# Spotlight 结果与 TCC 权限

[English](spotlight-permission-filtering.md) · **简体中文**

Spotlight 不会向应用返回所有已索引的路径。结果会按调用方的 TCC 权限过滤，
这使「缺权限」很容易伪装成「Spotlight 搜索失效」。

## 典型现象

- 可以搜到系统应用和部分用户文件
- 「桌面」、「文稿」或「下载」中的普通文件不出现
- 同一条查询在终端进程中和通过 `open` 启动的 app 中结果不同

从终端直接运行可能使用终端应用的权限上下文，而 `open StarFind.app` 使用 StarFind 自己的应用身份。
所以「命令行正常、打包后异常」不能直接证明引擎有 bug。

## 最小复现

在受保护目录中生成临时测试项，例如：

```text
~/Documents/starfind-fixture/sample.txt
~/Documents/starfind-fixture/sample.app
~/Downloads/starfind-fixture/sample.dmg
```

分别在已授权和未授权的应用身份下执行相同的 `NSMetadataQuery`。
测试后删除 fixture，不要使用真实用户文件作为回归样例。

## StarFind 的处理

`FileAccess.swift` 将受保护目录的访问封装为 `ProtectedFolder`：

1. 启动时对桌面、文稿和下载执行小范围的访问探测。
2. 在 TCC 尚未决定时由系统显示授权提示。
3. 在设置中显示每个目录的当前状态。
4. 结果明显缺失时，将权限作为可操作的排查方向。

## 签名的影响

ad-hoc 签名的本地开发构建在重新打包后可能被系统视为不同代码实例，已有授权可能需要重新确认。
正式发布应使用稳定的 bundle identifier、Developer ID 签名和公证。

## 排查顺序

1. 用 `mdfind` 确认文件已被 Spotlight 索引。
2. 使用实际 `.app` 身份复现，不只从终端运行可执行文件。
3. 检查系统设置中的「文件与文件夹」授权。
4. 在合成 fixture 上对比已授权和未授权的结果。
5. 最后再排查索引范围、谓词和 UI 结果节流。
