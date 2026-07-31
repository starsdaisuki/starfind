import Foundation
import ServiceManagement

/// 开机自启。走 SMAppService（macOS 13+），不写 LaunchAgent plist，
/// 系统「登录项」面板里能看到也能关，用户随时能收回控制权。
enum LoginItem {

    enum State {
        case enabled
        case disabled
        case requiresApproval   // 用户在系统设置里禁用过，要他自己去批准
        case unsupported
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .unsupported
        }
    }

    static var isEnabled: Bool { state == .enabled }

    /// 打开 / 关闭自启。返回 nil 表示成功，否则是给用户看的错误描述。
    @discardableResult
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // 已注册时再 register 会抛错，先判一下
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 当前 app 是不是跑在一个「稳定位置」。
    ///
    /// 自启记录的是注册那一刻的 bundle 路径。从 build/ 目录注册的话，
    /// 一次 make clean 就把自启指向了不存在的路径 —— 所以要提醒用户先 install。
    static var isInStableLocation: Bool {
        let path = Bundle.main.bundlePath
        return !path.contains("/.build/") && !path.contains("/build/")
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
