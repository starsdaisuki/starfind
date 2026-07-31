APP      := StarFind
BUNDLE   := build/$(APP).app
BIN      := .build/release/$(APP)
INSTALL_DIR := $(HOME)/Applications
# 发布二进制不携带调试信息，避免嵌入本机构建路径。
RELEASE_SWIFT_FLAGS := -Xswiftc -gnone

.PHONY: all build bundle run install clean kill dmg icon test

all: bundle

build:
	swift build -c release --disable-sandbox $(RELEASE_SWIFT_FLAGS)

bundle: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp $(BIN) $(BUNDLE)/Contents/MacOS/$(APP)
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(BUNDLE)/Contents/Resources/AppIcon.icns
	@printf 'APPL????' > $(BUNDLE)/Contents/PkgInfo
	@codesign --force --sign - --timestamp=none $(BUNDLE) >/dev/null 2>&1 || true
	@echo "→ $(BUNDLE)"

# 改完代码重跑必用
kill:
	@pkill -x $(APP) 2>/dev/null || true
	@sleep 0.3

run: kill bundle
	@open $(BUNDLE)
	@echo "→ StarFind 已启动。按 ⌥' 唤起搜索面板 ✧"

install: kill bundle
	@mkdir -p $(INSTALL_DIR)
	@rm -rf $(INSTALL_DIR)/$(APP).app
	@cp -R $(BUNDLE) $(INSTALL_DIR)/
	@echo "→ 已装到 $(INSTALL_DIR)/$(APP).app"

# 自检：查询解析 / 噪音过滤 / 排序 / 设置读写 / 真跑一次 Spotlight
# ⚠️ 改 AppSettings 之后必跑，那一层踩过「点一下就弹回去」的坑
test: bundle
	@STARFIND_SELFTEST=1 ./$(BUNDLE)/Contents/MacOS/$(APP)

# 查询诊断：make query Q=report
# 「搜不出来」时用它，能看到谓词 / Spotlight 原始条数 / 噪音过滤砍掉了哪些 / 排序结果
query: bundle
	@STARFIND_QUERY="$(Q)" ./$(BUNDLE)/Contents/MacOS/$(APP)

# 重新生成图标（改了 tools/make-icon.swift 之后跑）
icon:
	@swift tools/make-icon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "→ Resources/AppIcon.icns"

dmg: bundle
	@rm -f build/$(APP).dmg
	@rm -rf build/dmgroot && mkdir -p build/dmgroot
	@cp -R $(BUNDLE) build/dmgroot/
	@ln -s /Applications build/dmgroot/Applications
	@hdiutil create -volname $(APP) -srcfolder build/dmgroot -ov -format UDZO build/$(APP).dmg >/dev/null
	@rm -rf build/dmgroot
	@echo "→ build/$(APP).dmg"
	@echo "  ad-hoc 签名的 app 别人下载后会报「已损坏」，需要 xattr -dr com.apple.quarantine"

clean:
	rm -rf .build build

# 打字模拟：make type Q=report
# 复现「引擎单独跑正常，但面板上 0 结果」这类只在 UI 层出现的问题
type: bundle
	@STARFIND_TYPE="$(Q)" ./$(BUNDLE)/Contents/MacOS/$(APP)

# 真面板模拟：make panel Q=report
# 会真的把面板显示出来，往真实输入框里一个字一个字敲，最后跟干净引擎对账。
# make type 只跑到 ViewModel；「引擎 5 条、面板 3 条」这种只有这里能抓。
# 加 STARFIND_TRACE=1 还能看到每条 Spotlight 通知和每次节流跳过。
panel: bundle
	@STARFIND_PANEL="$(Q)" ./$(BUNDLE)/Contents/MacOS/$(APP)
