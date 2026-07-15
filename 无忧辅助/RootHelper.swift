//
//  RootHelper.swift
//  无忧辅助
//
//  TrollServer 参考实现，关键发现：
//   - 注销 (respring): 直接用 proc_listpids + kill(pid, SIGKILL)，无需 helper
//     TrollStore no-sandbox 环境下 UID=501 即可杀 SpringBoard
//   - 重启 (reboot): 必须 root 权限，使用 helper + trollstorehelper 多策略回退
//

import Foundation
import Darwin

@_silgen_name("proc_listpids")
private func _proc_listpids(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer, _ buffersize: Int32) -> Int32

@_silgen_name("proc_name")
private func _proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

final class RootHelper {
    static let shared = RootHelper()

    /// helper 二进制名称
    private let helperName = "roothelper"

    /// helper 二进制完整路径
    var helperPath: String? {
        guard let path = Bundle.main.path(forResource: helperName, ofType: nil) else {
            Log.shared.add("❌ 未找到 \(helperName) 二进制文件")
            return nil
        }
        return path
    }

    private init() {}

    // MARK: - 公共接口

    /// 强制重启手机 — 多策略回退（helper reboot + trollstorehelper + launchctl）
    func reboot() -> Bool {
        guard let path = helperPath else {
            Log.shared.add("❌ 找不到 helper 二进制，跳过重启")
            return false
        }
        Log.shared.add("🔧 请求强制重启...")

        // 策略1: 使用自己的 roothelper
        Log.shared.add("   [策略1] roothelper reboot...")
        if spawnHelper(path: path, command: "reboot") {
            return true
        }

        // 策略2: 使用 trollstorehelper（如果存在）
        Log.shared.add("   [策略2] trollstorehelper...")
        if spawnTrollStoreHelper(command: "reboot") {
            return true
        }

        // 策略3: launchctl reboot
        Log.shared.add("   [策略3] launchctl reboot...")
        if spawnCommand("/bin/launchctl", args: ["reboot"]) {
            return true
        }

        Log.shared.add("❌ 所有重启策略均失败")
        return false
    }

    /// 重启桌面（注销） — 直接用 proc_listpids 找 SpringBoard PID 再 kill
    /// 参考 TrollServer 实现，在 no-sandbox 环境下 UID=501 即可生效
    func respring() -> Bool {
        Log.shared.add("🔧 请求注销桌面...")

        // 方法1: kill SpringBoard
        Log.shared.add("   [1/2] 查找并 kill SpringBoard...")
        if let pid = findProcessPID(named: "SpringBoard") {
            Log.shared.add("      找到 SpringBoard PID=\(pid)")
            let ret = kill(pid, SIGKILL)
            Log.shared.add("      kill(\(pid), SIGKILL) => \(ret) errno=\(errno)")
            if ret == 0 {
                Log.shared.add("✅ SpringBoard 已终止，正在注销...")
                return true
            }
        } else {
            Log.shared.add("      ⚠️ 未找到 SpringBoard 进程")
        }

        // 方法2: 备用方案 kill backboardd
        Log.shared.add("   [2/2] 查找并 kill backboardd...")
        if let pid = findProcessPID(named: "backboardd") {
            Log.shared.add("      找到 backboardd PID=\(pid)")
            let ret = kill(pid, SIGKILL)
            Log.shared.add("      kill(\(pid), SIGKILL) => \(ret) errno=\(errno)")
            if ret == 0 {
                Log.shared.add("✅ backboardd 已终止，正在注销...")
                return true
            }
        } else {
            Log.shared.add("      ⚠️ 未找到 backboardd 进程")
        }

        Log.shared.add("❌ 注销失败：未找到目标进程")
        return false
    }

    // MARK: - 进程查找 (proc_listpids)

    /// 遍历所有进程，按名称找 PID（纯 libproc，无 shell 依赖）
    private func findProcessPID(named: String) -> pid_t? {
        let maxPids = 4096
        let bufferSize = MemoryLayout<pid_t>.size * maxPids
        var buffer = [pid_t](repeating: 0, count: maxPids)
        let count = _proc_listpids(1, 0, &buffer, Int32(bufferSize))
        let numPids = Int(count) / MemoryLayout<pid_t>.size

        for i in 0..<numPids {
            let pid = buffer[i]
            if pid <= 0 { continue }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let nameLen = _proc_name(pid, &nameBuffer, 256)
            if nameLen > 0 {
                let name = String(cString: nameBuffer)
                if name == named {
                    return pid
                }
            }
        }
        return nil
    }

    // MARK: - 进程 spawn

    /// spawn 自己的 roothelper 二进制
    private func spawnHelper(path: String, command: String) -> Bool {
        Log.shared.add("   spawnHelper cmd=\(command)")
        var pid: pid_t = 0
        let pathC = strdup(path)
        let cmdC  = strdup(command)
        defer { free(pathC); free(cmdC) }
        var argv: [UnsafeMutablePointer<CChar>?] = [pathC, cmdC, nil]
        let ret = posix_spawn(&pid, path, nil, nil, &argv, environ)
        if ret == 0 {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let code = ((status & 0o177) == 0) ? ((status >> 8) & 0xff) : -1
            Log.shared.add("   exitCode=\(code)")
            return code == 0
        }
        Log.shared.add("   posix_spawn 失败: \(ret)")
        return false
    }

    /// 尝试通过 trollstorehelper (TrollStore 内置 setuid root 代理) 执行命令
    private func spawnTrollStoreHelper(command: String) -> Bool {
        let candidates = [
            "/var/jb/usr/bin/trollstorehelper",
            "/usr/bin/trollstorehelper",
            "/usr/local/bin/trollstorehelper",
        ]
        for hp in candidates {
            guard access(hp, X_OK) == 0 else { continue }
            Log.shared.add("   找到 trollstorehelper: \(hp)")
            if spawnCommand(hp, args: [command]) {
                return true
            }
            if spawnCommand(hp, args: ["system", command]) {
                return true
            }
        }
        Log.shared.add("   trollstorehelper 未找到或执行失败")
        return false
    }

    /// 通用 spawn 任意程序
    private func spawnCommand(_ path: String, args: [String]) -> Bool {
        var pid: pid_t = 0
        let pathC = strdup(path)
        var argvC = args.map { strdup($0) }
        argvC.append(nil)
        defer {
            free(pathC)
            argvC.forEach { $0.map { free($0) } }
        }
        let ret = posix_spawn(&pid, path, nil, nil, argvC, environ)
        if ret == 0 {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let code = ((status & 0o177) == 0) ? ((status >> 8) & 0xff) : -1
            Log.shared.add("   exitCode=\(code)")
            return true // reboot 成功时进程可能不返回，能执行到说明发送了请求
        }
        return false
    }
}
