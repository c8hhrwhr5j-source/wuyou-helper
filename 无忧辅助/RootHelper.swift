//
//  RootHelper.swift
//  无忧辅助
//
//  重启: spawn roothelper 子进程 → kfd_escalate 提权 → reboot(RB_AUTOBOOT) + system("/sbin/reboot")
//  注销: proc_listpids + kill(SIGKILL)（直接在主进程执行）
//
//  注意: Swift 主进程在 UID=501 下 setuid(0) 总是失败，
//        必须通过 roothelper 子进程独立完成提权 + 重启。
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

    // MARK: - 重启

    /// 调用 roothelper 子进程执行 kfd 提权 + 整机重启。
    /// 先 kfd_escalate 提权到 root，再 system("/sbin/reboot") + reboot(RB_AUTOBOOT)。
    func reboot() -> Bool {
        Log.shared.add("🔧 调用 roothelper reboot 命令发起重启")

        guard let path = helperPath else {
            Log.shared.add("❌ roothelper 未找到，无法重启")
            return false
        }

        let success = spawnHelper(path: path, command: "reboot")
        if success {
            Log.shared.add("✅ roothelper reboot 已执行，设备即将重启")
        } else {
            Log.shared.add("❌ roothelper reboot 返回非零")
        }
        return success
    }

    // MARK: - 提权（通过 roothelper 子进程）

    func escalateToRoot() -> Bool {
        let uid = getuid(), euid = geteuid()
        Log.shared.add("🔑 请求提权 (UID=\(uid) EUID=\(euid))")

        guard let path = helperPath else {
            Log.shared.add("❌ roothelper 未找到")
            return false
        }

        // 步骤1: roothelper 子进程提权自身 + 尝试提权父进程 (Swift)
        Log.shared.add("   调用 roothelper escalate ...")
        let code = spawnHelperRaw(path: path, command: "escalate")
        Log.shared.add("   roothelper escalate exitCode=\(code)")

        // 步骤2: 重新检查当前进程的 UID
        let newUid = getuid(), newEuid = geteuid()
        Log.shared.add("   提权后: UID=\(newUid) EUID=\(newEuid)")

        if newUid == 0 || newEuid == 0 {
            Log.shared.add("✅ 主进程已获得 root 权限")
            return true
        }

        if code == 0 {
            Log.shared.add("⚠️ roothelper 子进程提权成功但父进程 UID 未变")
            Log.shared.add("   这通常意味着 kfd_escalate_pid 未生效或 iOS 版本不支持")
        }

        return false
    }

    /// 判断当前是否已是 root
    var isRoot: Bool {
        getuid() == 0 || geteuid() == 0
    }

    // MARK: - 诊断

    func diagnoseRoot() {
        Log.shared.add("========== 权限诊断 ==========")
        Log.shared.add("   UID=\(getuid())  EUID=\(geteuid())  GID=\(getgid())  EGID=\(getegid())")
        Log.shared.add("   isRoot=\(isRoot)")
        Log.shared.add("   helperPath=\(helperPath ?? "未找到")")

        // 检查关键文件是否存在
        let paths = ["/sbin/reboot", "/usr/sbin/shutdown", "/sbin/shutdown"]
        for p in paths {
            let exists = FileManager.default.fileExists(atPath: p)
            Log.shared.add("   \(p): \(exists ? "存在" : "不存在")")
        }
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
        return spawnHelperRaw(path: path, command: command) == 0
    }

    /// spawn roothelper 子进程，捕获 stdout/stderr 到日志。
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

        let ret = posix_spawn(&pid, path, &fileActions, nil, &argv, environ)

        close(writeFd)
        posix_spawn_file_actions_destroy(&fileActions)

        if ret != 0 {
            close(readFd)
            Log.shared.add("   posix_spawn 失败: \(ret) errno=\(errno)")
            return -1
        }

        // 后台读取子进程输出
        var outputData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(readFd, &buffer, 4096)
                if n <= 0 { break }
                outputData.append(buffer, count: n)
            }
            close(readFd)
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        group.wait()

        // 打印子进程输出到日志
        if let output = String(data: outputData, encoding: .utf8), !output.isEmpty {
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                Log.shared.add("   [roothelper]\n\(trimmed)")
            }
        }

        if (status & 0o177) == 0 {
            let code = (status >> 8) & 0xff
            Log.shared.add("   exitCode=\(code)")
            return code
        }
        Log.shared.add("   信号终止: signal=\(status & 0o177)")
        return -1
    }
}
