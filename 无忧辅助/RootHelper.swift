//
//  RootHelper.swift
//  无忧辅助
//
//  完全对齐 TrollServer ViewController.swift 的注销/重启实现
//  - 注销: 直接调用 proc_listpids + proc_name + kill(SIGKILL)（同 TrollServer）
//  - 重启: reboot() syscall + HTTP daemon 回退（同 TrollServer）
//

import Foundation
import Darwin

// 对齐 TrollServer: 直接调用 proc_listpids / proc_name（librpoc, 通过 libSystem 链接）
// 某些 Xcode/SDK 版本可能需要 @_silgen_name 声明
#if swift(>=5.9)
@_silgen_name("proc_listpids")
private func proc_listpids(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer, _ buffersize: Int32) -> Int32

@_silgen_name("proc_name")
private func proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32
#endif

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

    /// 强制重启手机（对齐 TrollServer performReboot）
    func reboot() -> Bool {
        Log.shared.add("🔧 请求强制重启 (UID=\(getuid()))...")

        // 策略1: 直接 reboot() 尝试（同 TrollServer）
        sync()
        Log.shared.add("   [1/4] 直接 reboot(0)...")
        var ret = reboot(0)
        Log.shared.add("      reboot(0) => \(ret) errno=\(errno)")

        if ret != 0 {
            Log.shared.add("   [2/4] reboot(0x400)...")
            ret = reboot(0x400)
            Log.shared.add("      reboot(0x400) => \(ret) errno=\(errno)")
        }

        // 策略2: 通过 roothelper 尝试
        if let path = helperPath {
            Log.shared.add("   [3/4] roothelper reboot...")
            spawnHelper(path: path, command: "reboot")
        }

        // 策略3: launchctl reboot
        Log.shared.add("   [4/4] launchctl reboot...")
        spawnCommand("/bin/launchctl", args: ["reboot"])

        Log.shared.add("❌ 所有重启策略均失败 (UID=\(getuid()))")
        return false
    }

    /// 重启桌面（注销）— 完全对齐 TrollServer performRespring
    func respring() -> Bool {
        Log.shared.add("========== 开始注销 (Respring) UID=\(getuid()) ==========")

        // 方法1: 通过系统 API 获取 SpringBoard PID，直接 kill(SIGKILL)
        // 完全对齐 TrollServer ViewController.swift line 604-617
        Log.shared.add("[1/2] 查找 SpringBoard PID 并发送 SIGKILL...")
        if let pid = getProcessPID(named: "SpringBoard") {
            Log.shared.add("      找到 SpringBoard PID=\(pid)，发送 SIGKILL...")
            let ret = kill(pid, SIGKILL)
            Log.shared.add("      kill(\(pid), SIGKILL) => ret=\(ret) errno=\(errno)")
            if ret == 0 {
                Log.shared.add("✅ SIGKILL 已成功发送给 SpringBoard")
                return true
            } else {
                Log.shared.add("      ❌ kill 失败, errno=\(errno) \(String(cString: strerror(errno)))")
            }
        } else {
            Log.shared.add("      ⚠️ 未找到 SpringBoard 进程")
        }

        // 方法2: 杀死 backboardd
        Log.shared.add("[2/2] 查找 backboardd PID 并发送 SIGKILL...")
        if let pid = getProcessPID(named: "backboardd") {
            Log.shared.add("      找到 backboardd PID=\(pid)，发送 SIGKILL...")
            let ret = kill(pid, SIGKILL)
            Log.shared.add("      kill(\(pid), SIGKILL) => ret=\(ret) errno=\(errno)")
            if ret == 0 {
                Log.shared.add("✅ SIGKILL 已成功发送给 backboardd")
                return true
            } else {
                Log.shared.add("      ❌ kill 失败, errno=\(errno)")
            }
        } else {
            Log.shared.add("      ⚠️ 未找到 backboardd 进程")
        }

        // 方法3: 通过 roothelper 二进制尝试（C 语言层 fallback）
        if let path = helperPath {
            Log.shared.add("[3/3] 调用 roothelper respring...")
            if spawnHelper(path: path, command: "respring") {
                Log.shared.add("✅ roothelper respring 成功")
                return true
            }
        }

        Log.shared.add("❌ 注销失败：所有方法均未生效")
        Log.shared.add("   诊断: UID=\(getuid()), 可能需要 no-sandbox 权限")
        return false
    }

    // MARK: - 进程查找（完全对齐 TrollServer ViewController.swift getProcessPID）

    /// 获取指定名称进程的 PID（不依赖 shell，对齐 TrollServer 实现）
    private func getProcessPID(named: String) -> pid_t? {
        let maxPids = 4096
        let bufferSize = MemoryLayout<pid_t>.size * maxPids
        var buffer = [pid_t](repeating: 0, count: maxPids)
        let count = proc_listpids(1, 0, &buffer, Int32(bufferSize))
        let numPids = Int(count) / MemoryLayout<pid_t>.size

        Log.shared.add("      proc_listpids 返回 \(numPids) 个进程")

        for i in 0..<numPids {
            let pid = buffer[i]
            if pid <= 0 { continue }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let nameLen = proc_name(pid, &nameBuffer, 256)
            if nameLen > 0 {
                let name = String(cString: nameBuffer)
                if name == named {
                    Log.shared.add("      找到 \(named) PID=\(pid)")
                    return pid
                }
            }
        }
        Log.shared.add("      ⚠️ 未找到 \(named)")
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
            return true
        }
        return false
    }
}
