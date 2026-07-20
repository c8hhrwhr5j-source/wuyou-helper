//
//  无忧辅助App.swift
//  无忧辅助 - TrollStore IPA
//
// == 为什么启动时自动提权 ==
//   TrollStore 安装的应用以 mobile 用户运行 (UID=501)，
//   重启/关机等操作需要 root 权限。
//   init() 中异步调用 roothelper escalate 子进程，
//   roothelper 通过 kfd (task_for_pid(0)) 修改内核 ucred.uid=0，
//   实现整个应用进程的 root 提权。
//   提权后 getuid()==0，后续所有 syscall 都具备 root 权限。
//
// == 为什么用子进程(roothelper)而不是直接提权 ==
//   Swift 进程的 sandbox 限制使 setuid(0) 无效。
//   独立 C 子进程 handles kfd 内核操作更可靠。
//   roothelper 提权后会同步修改父进程(Swift)的 ucred，
//   这样主进程也获得 root 权限。
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
