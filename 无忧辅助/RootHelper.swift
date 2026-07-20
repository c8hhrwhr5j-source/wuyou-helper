//
//  RootHelper.swift
//  无忧辅助
//
//  重启: 主进程 kfd 提权 → reboot(RB_AUTOBOOT) + system("/sbin/reboot")
//  注销: proc_listpids + kill(SIGKILL)（直接在主进程执行）
//
//  说明: 之前通过 roothelper 子进程提权，但 TrollStore 无法给嵌入式
//        二进制正确签入 no-sandbox 等权限，导致 IOServiceOpen 被沙盒
//        拒绝 (0xe00002e2)。现在改为由主进程直接调用 kfd 提权。
//

import Foundation
import Darwin

// proc_listpids / proc_name 是未公开的 libSystem C 函数，
// 用 @_silgen_name 直接链接而非 dlsym（编译期解析，更可靠）
@_silgen_name("proc_listpids")
private func _proc_listpids(_ type: UInt32, _ typeinfo: UInt32, _ buffer: UnsafeMutableRawPointer, _ buffersize: Int32) -> Int32

@_silgen_name("proc_name")
private func _proc_name(_ pid: Int32, _ buffer: UnsafeMutableRawPointer, _ buffersize: UInt32) -> Int32

// kfd 内核提权接口 (roothelper/kfd.c 已编译进主 App)
@_silgen_name("kfd_escalate")
private func _kfd_escalate() -> Int32

@_silgen_name("kfd_get_error")
private func _kfd_get_error() -> UnsafePointer<CChar>?

@_silgen_name("kfd_close")
private func _kfd_close()

// SecTask - 运行时查询内核实际看到的 entitlements
@_silgen_name("SecTaskCreateFromSelf")
private func SecTaskCreateFromSelf(_ allocator: CFAllocator?) -> AnyObject

@_silgen_name("SecTaskCopyValueForEntitlement")
private func SecTaskCopyValueForEntitlement(_ task: AnyObject, _ entitlement: CFString, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> AnyObject?

private let RB_AUTOBOOT: Int32 = 0

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

    /// 主进程直接执行 kfd 提权 → 整机重启。
    func reboot() -> Bool {
        Log.shared.add("========== 重启 ==========")
        Log.shared.add("   当前 UID=\(getuid()) EUID=\(geteuid())")

        // 已经在 root 状态，直接重启
        if isRoot {
            Log.shared.add("✅ 当前进程已是 root，直接调用 reboot()")
            sync()
            Darwin.reboot(RB_AUTOBOOT)
            return true
        }

        // 主进程直接 kfd 提权（避免 roothelper 被 TrollStore 沙盒化）
        Log.shared.add("[reboot] 尝试主进程直接 kfd 提权...")
        if kfdEscalateAndReboot() {
            return true
        }

        // 回退：roothelper（如果主进程 kfd 因某种原因失败）
        Log.shared.add("[reboot] 主进程直接提权失败，回退到 roothelper")

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

    /// 主进程直接调用 kfd 提权并立即 reboot。
    /// 若 reboot() 成功，当前进程不会返回；否则返回 false。
    private func kfdEscalateAndReboot() -> Bool {
        let ret = _kfd_escalate()
        if ret != 0 {
            let err = _kfd_get_error()
            let msg = err != nil ? String(cString: err!) : "unknown"
            Log.shared.add("❌ 主进程 kfd 提权失败: \(msg)")
            return false
        }

        Log.shared.add("✅ 主进程 kfd 提权成功，UID=\(getuid()) EUID=\(geteuid())")
        setuid(0)
        setgid(0)
        sync()
        Log.shared.add("[reboot] 调用 reboot(RB_AUTOBOOT)...")
        Darwin.reboot(RB_AUTOBOOT)
        // reboot 成功不会返回
        Log.shared.add("❌ reboot() 返回，errno=\(errno)")
        return false
    }

    // MARK: - 提权

    func escalateToRoot() -> Bool {
        let uid = getuid(), euid = geteuid()
        Log.shared.add("🔑 请求提权 (UID=\(uid) EUID=\(euid))")

        if isRoot {
            Log.shared.add("✅ 当前进程已是 root")
            return true
        }

        // 主进程直接 kfd
        Log.shared.add("   尝试主进程直接 kfd...")
        let ret = _kfd_escalate()
        if ret == 0 {
            let newUid = getuid(), newEuid = geteuid()
            Log.shared.add("   主进程 kfd 成功，UID=\(newUid) EUID=\(newEuid)")
            return newUid == 0 || newEuid == 0
        } else {
            let err = _kfd_get_error()
            let msg = err != nil ? String(cString: err!) : "unknown"
            Log.shared.add("❌ 主进程 kfd 失败: \(msg)")
        }

        // 回退：roothelper
        guard let path = helperPath else {
            Log.shared.add("❌ roothelper 未找到")
            return false
        }

        Log.shared.add("   回退：调用 roothelper escalate ...")
        let code = spawnHelperRaw(path: path, command: "escalate")
        Log.shared.add("   roothelper escalate exitCode=\(code)")

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

        // 检查主进程是否能看到系统文件（判断沙盒是否生效）
        let paths = ["/sbin/reboot", "/usr/sbin/shutdown", "/sbin/shutdown", "/var/mobile"]
        for p in paths {
            let exists = FileManager.default.fileExists(atPath: p)
            Log.shared.add("   \(p): \(exists ? "存在" : "不存在/不可见")")
        }

        // ==== 运行时 entitlements 检查（内核实际看到的） ====
        Log.shared.add("")
        Log.shared.add("--- 内核运行时权限 ---")
        checkRuntimeEntitlements()

        // ==== 二进制中嵌入的权限字符串（构建时注入的） ====
        Log.shared.add("")
        Log.shared.add("--- 二进制嵌入权限 ---")
        scanBinaryForEntitlements()

        // ==== 实战测试：setuid(0) ====
        Log.shared.add("")
        Log.shared.add("--- 实战测试：setuid(0) ---")
        testSetuid()
    }

    // MARK: - setuid(0) 实战测试

    private func testSetuid() {
        // 测试 access()（C 层，比 FileManager 更准确）
        let testPaths = ["/sbin/reboot", "/var/mobile"]
        for p in testPaths {
            let acc = access(p, Int32(F_OK))
            Log.shared.add("   access(\(p), F_OK)=\(acc) errno=\(acc == -1 ? String(cString: strerror(errno)) : "ok")")
        }

        // 尝试 setuid(0)
        let beforeUid = getuid()
        let beforeEuid = geteuid()
        let ret = setuid(0)
        let ret2 = seteuid(0)
        let afterUid = getuid()
        let afterEuid = geteuid()

        Log.shared.add("   setuid(0) 返回=\(ret), seteuid(0) 返回=\(ret2)")
        Log.shared.add("   提权前: UID=\(beforeUid) EUID=\(beforeEuid)")
        Log.shared.add("   提权后: UID=\(afterUid) EUID=\(afterEuid)")

        if afterUid == 0 || afterEuid == 0 {
            Log.shared.add("   ✅ setuid(0) 成功！persona-mgmt 有效")
            for p in testPaths {
                let acc = access(p, Int32(F_OK))
                Log.shared.add("   (root) access(\(p), F_OK)=\(acc) errno=\(acc == -1 ? String(cString: strerror(errno)) : "ok")")
            }
            seteuid(beforeEuid)
            setuid(beforeUid)
        } else {
            let msg = ret == -1 ? String(cString: strerror(errno)) : "返回非零"
            Log.shared.add("   ❌ setuid(0) 失败: \(msg) (errno=\(errno))")
            Log.shared.add("   → persona-mgmt 虽然被内核识别，但 setuid 被拒绝")
            Log.shared.add("   → 这是 iOS 15.8.4 运行时限制，与 entitlements 无关")
        }
    }

    // MARK: - 运行时权限检查

    /// 通过 SecTask API 查询内核在运行时实际看到的 entitlements
    private func checkRuntimeEntitlements() {
        let keys: [(String, String)] = [
            ("com.apple.private.security.no-sandbox",      "关闭沙盒"),
            ("com.apple.private.persona-mgmt",             "root身份"),
            ("platform-application",                       "平台应用"),
            ("get-task-allow",                             "调试启动"),
            ("dynamic-codesigning",                        "动态签名"),
            ("com.apple.private.skip-library-validation",  "跳过库验证"),
            ("com.apple.private.task_for_pid-allow",      "task_for_pid"),
            ("com.apple.system-task-ports",               "系统任务端口"),
            ("com.apple.private.cs.debugger",             "调试器"),
            ("com.apple.private.system.restart",          "系统重启"),
            ("com.apple.private.system.shutdown",         "系统关机"),
        ]

        let task = SecTaskCreateFromSelf(nil)
        for (key, desc) in keys {
            if let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) {
                let str = String(describing: value)
                Log.shared.add("   [✅] \(desc) (\(key)): \(str)")
            } else {
                Log.shared.add("   [❌] \(desc) (\(key)): 未注册")
            }
        }
    }

    // MARK: - 二进制权限扫描

    /// 扫描自身二进制文件的代码签名段，查找嵌入的 entitlements XML 中的 <key> 标记。
    /// 只匹配 "<key>xxx</key>" 形式，避免把代码里的字符串误判为嵌入权限。
    private func scanBinaryForEntitlements() {
        guard let binaryPath = Bundle.main.executablePath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: binaryPath)) else {
            Log.shared.add("   ❌ 无法读取自身二进制")
            return
        }

        Log.shared.add("   二进制路径: \(binaryPath)")
        Log.shared.add("   二进制大小: \(data.count) bytes")

        // 转成 UTF-8 字符串（跳过无效字节），只保留 XML 标签内可能出现的字符
        var utf8buf = ""
        data.forEach { byte in
            if byte >= 0x20 && byte < 0x7f {
                utf8buf.append(Character(UnicodeScalar(byte)))
            }
        }

        let targets: [(String, String)] = [
            ("com.apple.private.security.no-sandbox",       "关闭沙盒"),
            ("com.apple.private.persona-mgmt",              "root身份"),
            ("platform-application",                        "平台应用"),
            ("get-task-allow",                              "调试启动"),
            ("dynamic-codesigning",                         "动态签名"),
            ("com.apple.private.skip-library-validation",   "跳过库验证"),
            ("com.apple.private.task_for_pid-allow",       "task_for_pid"),
            ("com.apple.system-task-ports",                "系统任务端口"),
            ("com.apple.private.cs.debugger",              "调试器"),
            ("com.apple.private.system.restart",            "系统重启"),
            ("com.apple.private.system.shutdown",           "系统关机"),
        ]

        for (key, desc) in targets {
            if utf8buf.contains("<key>\(key)</key>") {
                Log.shared.add("   [✅] \(desc) 在二进制签名中")
            } else {
                Log.shared.add("   [❌] \(desc) 未在二进制签名中找到 → 构建时未注入")
            }
        }

        // 额外：统计 XML plist 片段数，辅助判断签名中是否包含 entitlements
        let xmlCount = utf8buf.components(separatedBy: "<?xml").count - 1
        Log.shared.add("   二进制签名中 XML plist 片段数: \(xmlCount)")
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
