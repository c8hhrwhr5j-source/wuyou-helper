//
//  无忧辅助App.swift
//  无忧辅助 - TrollStore IPA
//
// == 为什么启动时自动提权 ==
//   TrollStore 安装的应用以 mobile 用户运行 (UID=501)，
//   重启/关机等操作需要 root 权限。
//   init() 中异步调用 roothelper escalate 子进程，
//   roothelper 通过 setuid(0) / kfd (task_for_pid(0)) 修改内核 ucred.uid=0，
//   实现整个应用进程的 root 提权。
//   提权后 getuid()==0，后续所有 syscall 都具备 root 权限。
//
// == 重启机制 ==
//   Swift 端 reboot() spawn roothelper reboot 子进程，
//   子进程内部: setuid(0) → kfd 提权 → sync() → reboot(RB_AUTOBOOT) → shutdown -r now
//   子进程不受 Swift 进程 UID 限制，可独立完成提权并触发整机重启。
//

import SwiftUI

@main
struct 无忧辅助App: App {
    init() {
        // 启动时自动提权（异步，不阻塞 UI）
        // 用 static 方法避免 escaping 闭包捕获未初始化的 self
        DispatchQueue.global(qos: .userInitiated).async {
            Self.autoEscalateIfNeeded()
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }

    // MARK: - 自动提权

    private static func autoEscalateIfNeeded() {
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
