//
//  无忧辅助App.swift
//  无忧辅助 - TrollStore IPA
//
//  启动时自动通过 roothelper 提权到 root（kfd 内核漏洞）
//  提权后 UID=0，后续操作（重启/关机）无需额外提权
//

import SwiftUI

@main
struct 无忧辅助App: App {
    init() {
        // 启动时自动提权（异步，不阻塞 UI）
        DispatchQueue.global(qos: .userInitiated).async {
            autoEscalateIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }

    // MARK: - 自动提权

    private func autoEscalateIfNeeded() {
        // 如果已经是 root，跳过
        if RootHelper.shared.isRoot {
            Log.shared.add("✅ 应用已以 root 运行 (UID=\(getuid()) EUID=\(geteuid()))")
            return
        }

        Log.shared.add("🔑 应用启动，尝试提权到 root ...")
        Log.shared.add("   当前 UID=\(getuid()) EUID=\(geteuid()) GID=\(getgid())")

        let success = RootHelper.shared.escalateToRoot()

        // 提权后重新检查权限
        sleep(1)
        Log.shared.add("   提权后: UID=\(getuid()) EUID=\(geteuid()) GID=\(getgid())")
        if getuid() == 0 || geteuid() == 0 {
            Log.shared.add("✅ 成功以 root 权限运行！")
        } else if success {
            Log.shared.add("⚠️ roothelper 提权成功但当前进程 UID 未变 (可能需要父进程提权)")
        } else {
            Log.shared.add("⚠️ 自动提权未成功，重启等操作将经由 roothelper 子进程执行")
        }
    }
}
