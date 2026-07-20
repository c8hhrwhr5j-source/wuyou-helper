//
//  无忧辅助App.swift
//  无忧辅助 - TrollStore IPA
//
// == 权限说明 ==
//   TrollStore 安装的应用以 mobile 用户运行 (UID=501)，
//   在 UID=501 下 setuid(0) 永远被内核拒绝。
//   重启操作通过 spawn roothelper 子进程完成：
//   子进程独立尝试 setuid(0) → kfd 提权 → reboot(RB_AUTOBOOT)。
//   子进程不受 Swift 主进程 UID 限制，可独立完成提权并触发重启。
//
// == 启动诊断 ==
//   init() 中异步执行权限诊断，输出 UID/EUID/关键文件等信息到日志。
//

import SwiftUI

@main
struct 无忧辅助App: App {
    init() {
        // 启动时异步执行权限诊断（不阻塞 UI）
        DispatchQueue.global(qos: .userInitiated).async {
            Self.startupDiagnostics()
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }

    // MARK: - 启动诊断

    private static func startupDiagnostics() {
        Log.shared.add("===== 无忧辅助 启动 =====")
        Log.shared.add("   UID=\(getuid())  EUID=\(geteuid())  GID=\(getgid())  EGID=\(getegid())")

        // 检查 roothelper 是否存在
        if let path = RootHelper.shared.helperPath {
            Log.shared.add("   roothelper 已找到: \(path)")

            // 检查 roothelper 是否可执行
            if FileManager.default.isExecutableFile(atPath: path) {
                Log.shared.add("   roothelper 可执行 ✅")
            } else {
                Log.shared.add("   ⚠️ roothelper 不可执行！请检查编译和签名")
            }
        } else {
            Log.shared.add("   ❌ roothelper 未嵌入 App Bundle！")
        }

        // 检查关键系统文件
        let paths = [
            "/sbin/reboot",
            "/usr/sbin/shutdown",
            "/sbin/shutdown"
        ]
        for p in paths {
            let exists = FileManager.default.fileExists(atPath: p)
            Log.shared.add("   \(p): \(exists ? "存在" : "不存在")")
        }

        // 自动执行完整权限诊断
        RootHelper.shared.diagnoseRoot()

        Log.shared.add("===== 启动诊断完成 =====")
    }
}
