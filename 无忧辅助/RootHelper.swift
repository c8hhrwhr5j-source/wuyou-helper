//
//  RootHelper.swift
//  无忧辅助
//
//  重启: spawn roothelper 子进程 → setuid(0) → kfd 提权 → reboot(RB_AUTOBOOT) → shutdown -r now
//  注销: proc_listpids + kill(SIGKILL)（直接在主进程执行，已验证可用）
//

import Foundation
import Darwin

// proc_listpids / proc_name 是未公开的 libSystem C 函数，
// 用 @_silgen_name 直接链接而非 dlsym（编译期解析，更可靠）
@_silgen_name("proc_listpids")
private func _proc_listpids(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer, _ buffersize: Int32) -> Int32

@_silgen_name("proc_name")
private func _proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

final class RootHelper {
    static let shared = RootHelper()

    private let helperName = "roothelper"

    var helperPath: String? {
        guard let path = Bundle.main.path(forResource: helperName, ofType: nil) else {
            Log.shared.add("❌ 未找到 \(helperName) 二进制文件")
            return nil
        }
        return path
    }

    private init() {}

    // notify_post 系统通知发送函数（未公开）
    @_silgen_name("notify_post")
    private func _notify_post(_ name: UnsafePointer<CChar>) -> Int32

    // reboot() 系统调用（RB_AUTOBOOT = 0）
    @_silgen_name("reboot")
    private func sys_reboot(_ howto: Int32) -> Int32

    // MARK: - 重启（先 setuid(0) 提权 → reboot(0) 系统调用 → notify_post 回退）

    func reboot() -> Bool {
        let uid = getuid(), euid = geteuid()
        Log.shared.add("🔔 请求重启 (UID=\(uid) EUID=\(euid))")

        // 步骤1: 尝试 setuid(0) 提权
        if uid != 0 {
            Log.shared.add("   尝试 setuid(0) 提权...")
            let s1 = seteuid(0)
            let s2 = setuid(0)
            let uidAfter = getuid()
            Log.shared.add("   seteuid(0)=\(s1), setuid(0)=\(s2), uidAfter=\(uidAfter)")

            if uidAfter == 0 {
                Log.shared.add("✅ 提权成功，UID=0")
            } else {
                Log.shared.add("⚠️ 提权失败，仍 UID=\(uidAfter)")
            }
        }

        // 步骤2: 如果已是 root，直接调用 reboot(0) 系统调用
        if getuid() == 0 || geteuid() == 0 {
            Log.shared.add("   直接调用 reboot(0) 系统调用...")
            sync()
            let ret = sys_reboot(0)  // RB_AUTOBOOT = 0
            Log.shared.add("   reboot(0) => ret=\(ret) errno=\(errno)")
            if ret == 0 {
                Log.shared.add("✅ 重启指令已执行")
                return true
            }
            Log.shared.add("   reboot(0) 失败，尝试 roothelper...")
        }

        // 步骤3: 通过 roothelper 子进程（独立提权 + reboot）
        guard let path = helperPath else {
            Log.shared.add("❌ roothelper 未找到，重启失败")
            return false
        }

        Log.shared.add("   调用 roothelper reboot...")
        let code = spawnHelperRaw(path: path, command: "reboot")
        Log.shared.add("   roothelper exitCode=\(code)")
        if code == 0 {
            Log.shared.add("✅ roothelper 已执行重启")
            return true
        }

        // 步骤4: notify_post 最后回退（mobile 用户下通常无效，但保留）
        Log.shared.add("   尝试 notify_post 双通知...")
        _ = "com.apple.springboard.restartDevice".withCString { _notify_post($0) }
        _ = "com.apple.system.reboot".withCString { _notify_post($0) }
        Log.shared.add("   notify_post 已发送 (注意: UID=501 下通常无效)")

        Log.shared.add("❌ 所有重启方式均已尝试")
        return false
    }

    // MARK: - 提权到 root（先 setuid(0)，再 roothelper 子进程 fallback）

    func escalateToRoot() -> Bool {
        Log.shared.add("🔑 请求提权到 root (UID=\(getuid()))")

        // 策略1: 直接 setuid(0)（TrollStore 通常直接成功）
        Log.shared.add("   尝试直接 setuid(0)...")
        let s1 = seteuid(0)
        let s2 = setuid(0)
        let uid = getuid()
        let euid = geteuid()
        Log.shared.add("   setuid(0) result: uid=\(uid) euid=\(euid) s1=\(s1) s2=\(s2)")

        if uid == 0 || euid == 0 {
            Log.shared.add("✅ 直接 setuid(0) 成功，无需 roothelper")
            return true
        }
        Log.shared.add("   ⚠️ setuid(0) 失败，尝试 roothelper 子进程...")

        // 策略2: 通过 roothelper 子进程（含 kfd 内核修改）
        guard let path = helperPath else {
            Log.shared.add("❌ roothelper 未找到，无法提权")
            return false
        }

        Log.shared.add("   调用 roothelper escalate (kfd 内核提权)...")
        let code = spawnHelperRaw(path: path, command: "escalate")
        Log.shared.add("   roothelper return code=\(code)")

        // 检查主进程是否已 root（roothelper 可能通过 kfd 修改了父进程 ucred）
        if getuid() == 0 || geteuid() == 0 {
            Log.shared.add("✅ 主进程已提权为 root")
            return true
        }

        if code == 0 {
            Log.shared.add("⚠️ roothelper 返回成功但主进程 UID 未变，尝试再次 setuid...")
            _ = setuid(0)
            return getuid() == 0
        }

        Log.shared.add("❌ roothelper 返回失败 (exitCode=\(code))")
        return false
    }

    /// 判断当前是否已是 root
    var isRoot: Bool {
        getuid() == 0 || geteuid() == 0
    }

    // MARK: - 注销

    func respring() -> Bool {
        Log.shared.add("========== 注销 (Respring) UID=\(getuid()) ==========")

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

        // 回退：通过 roothelper
        if let path = helperPath {
            Log.shared.add("[3/3] 调用 roothelper respring...")
            if spawnHelper(path: path, command: "respring") {
                Log.shared.add("✅ roothelper respring 成功")
                return true
            }
        }

        Log.shared.add("❌ 注销失败")
        return false
    }

    // MARK: - 进程查找

    private func getProcessPID(named: String) -> pid_t? {
        let maxPids = 4096
        let bufferSize = MemoryLayout<pid_t>.size * maxPids
        var buffer = [pid_t](repeating: 0, count: maxPids)
        let count = _proc_listpids(1, 0, &buffer, Int32(bufferSize))
        let numPids = Int(count) / MemoryLayout<pid_t>.size

        Log.shared.add("      proc_listpids 返回 \(numPids) 个进程")

        for i in 0..<numPids {
            let pid = buffer[i]
            if pid <= 0 { continue }
            var nameBuffer = [CChar](repeating: 0, count: 256)
            let nameLen = _proc_name(pid, &nameBuffer, 256)
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

    // MARK: - spawn roothelper

    private func spawnHelper(path: String, command: String) -> Bool {
        Log.shared.add("   spawnHelper cmd=\(command)")
        return spawnHelperRaw(path: path, command: command) == 0
    }

    /// spawn roothelper 并返回 exit code，同时捕获 stdout/stderr 到日志
    private func spawnHelperRaw(path: String, command: String) -> Int32 {
        Log.shared.add("   spawnHelperRaw cmd=\(command)")

        // 创建管道，用于捕获子进程 stdout + stderr
        var pipeFds: [Int32] = [0, 0]
        guard pipe(&pipeFds) == 0 else {
            Log.shared.add("   pipe 创建失败 errno=\(errno)")
            return -1
        }
        let readFd = pipeFds[0]
        let writeFd = pipeFds[1]

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, writeFd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, writeFd, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, readFd)

        var pid: pid_t = 0
        let pathC = strdup(path)
        let cmdC  = strdup(command)
        defer { free(pathC); free(cmdC) }
        var argv: [UnsafeMutablePointer<CChar>?] = [pathC, cmdC, nil]

        let ret = posix_spawn(&pid, path, fileActions, nil, &argv, environ)

        close(writeFd) // 父进程关闭写端
        posix_spawn_file_actions_destroy(&fileActions)

        if ret != 0 {
            close(readFd)
            Log.shared.add("   posix_spawn 失败: \(ret) errno=\(errno)")
            return -1
        }

        // 在后台读取输出，避免阻塞
        var outputData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = read(readFd, &buffer, 1024)
                if n <= 0 { break }
                outputData.append(buffer, count: n)
            }
            close(readFd)
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        group.wait()

        if let output = String(data: outputData, encoding: .utf8), !output.isEmpty {
            Log.shared.add("   [roothelper output]\n\(output)")
        }

        if (status & 0o177) == 0 {
            let code = (status >> 8) & 0xff
            Log.shared.add("   exitCode=\(code)")
            return code
        }
        Log.shared.add("   信号终止: \(status & 0o177)")
        return -1
    }
}
