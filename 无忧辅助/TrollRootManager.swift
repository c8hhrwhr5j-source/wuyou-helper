import Foundation

/// 巨魔权限管理器 — 封装提权、注销操作
/// 内部委托 RootHelper.shared 执行实际逻辑
final class TrollRootManager {
    static let shared = TrollRootManager()

    private init() {}

    /// kfd 内核提权到 root
    func getFullRoot() -> Bool {
        return RootHelper.shared.escalateToRoot()
    }

    /// 桌面注销
    func deviceRespring() -> Bool {
        return RootHelper.shared.respring()
    }
}
