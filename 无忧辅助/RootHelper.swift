//
//  RootHelper.swift
//  无忧辅助
//
//  重启: kfd 提权 → 直接内核写 ucred → reboot(0)
//  注销: proc_listpids + kill(SIGKILL)（直接在主进程执行）
//
//  说明: iOS 15.8.4 封堵了旧 Landa/IOSurfaceRoot 路径，改用
//        dmaFail + IOAccel 路径获取内核 r/w，然后直接修改
//        ucred.cr_uid = 0 实现提权（完全绕过 setuid(0) 限制）。
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
@_silgen_name("kfd_init")
private func _kfd_init() -> Int32

@_silgen_name("kfd_open")
private func _kfd_open() -> Int32

@_silgen_name("kfd_get_root")
private func _kfd_get_root() -> Int32

@_silgen_name("kfd_escalate")
private func _kfd_escalate() -> Int32

@_silgen_name("kfd_is_root")
private func _kfd_is_root() -> Int32

@_silgen_name("kfd_get_error")
private func _kfd_get_error() -> UnsafePointer<CChar>?

@_silgen_name("kfd_close")
private func _kfd_close()

// SecTask - 运行时查询内核实际看到的 entitlements
@_silgen_name("SecTaskCreateFromSelf")
private func SecTaskCreateFromSelf(_ allocator: CFAllocator?) -> AnyObject

@_silgen_name("SecTaskCopyValueForEntitlement")
private func SecTaskCopyValueForEntitlement(_ task: AnyObject, _ entitlement: CFString, _ error: UnsafeMutablePointer<Unmanaged<CFError>?>?) -> AnyObject?

// FrontBoard 重启 — C 辅助函数 (arm64e PAC 安全, 在 kfd.c 中实现)
@_silgen_name("fb_shutdown_reboot")
private func fb_shutdown_reboot() -> Int32

@_silgen_name("sbs_restart")
private func sbs_restart() -> Int32

@_silgen_name("notify_reboot")
private func notify_reboot() -> Int32

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

    /// 主进程执行整机重启。
    /// 尝试顺序: 已是 root → FrontBoard 系统服务 → kill SpringBoard → kfd 提权 → roothelper
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

        // 路径1: FrontBoard 系统服务重启（iOS 内部机制，不需要 root）
        Log.shared.add("[reboot] 尝试 FrontBoard 系统服务重启...")
        if frontboardReboot() {
            return true
        }

        // 路径2: 杀 SpringBoard + backboardd 触发硬重启
        Log.shared.add("[reboot] 尝试 kill SpringBoard 触发重启...")
        if killSpringBoardForReboot() {
            return true
        }

        // 路径3: kfd 内核提权（需要内核漏洞）
        Log.shared.add("[reboot] 尝试主进程 kfd 提权...")
        if kfdEscalateAndReboot() {
            return true
        }

        // 路径4: 回退 roothelper 子进程
        Log.shared.add("[reboot] 以上均失败，回退到 roothelper")
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

    // MARK: - FrontBoard 重启

    /// 通过 C 辅助函数触发系统重启（arm64e PAC 安全）。
    /// ObjC 消息发送在 kfd.c 中用 <objc/message.h> 实现，避免 Swift 的 objc_msgSend 保留符号问题。
    private func frontboardReboot() -> Bool {
        // 路径 A: FBSSystemService.shutdownWithOptions:1
        Log.shared.add("   [A] fb_shutdown_reboot() → FBSSystemService.shutdownWithOptions:")
        let retA = fb_shutdown_reboot()
        if retA == 0 {
            Log.shared.add("   [A] ✅ 已发送重启请求，等待 XPC 传播...")
            // 给 RunLoop 时间把 XPC 消息发出去
            let deadline = Date().addingTimeInterval(5.0)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }
            Log.shared.add("   [A] 等待超时（shutdown 可能未生效）")
            return true
        }
        Log.shared.add("   [A] ❌ fb_shutdown_reboot 失败")

        // 路径 B: SpringBoardServices
        Log.shared.add("   [B] sbs_restart() → SBSSystemService")
        let retB = sbs_restart()
        if retB == 0 {
            Log.shared.add("   [B] ✅ SBS 重启已发送")
            return true
        }
        Log.shared.add("   [B] ❌ sbs_restart 失败")

        // 路径 C: Darwin notify_post
        Log.shared.add("   [C] notify_reboot() → Darwin 通知")
        let retC = notify_reboot()
        if retC == 0 {
            Log.shared.add("   [C] ✅ 系统通知已发送")
            return true
        }
        Log.shared.add("   [C] ❌ notify_reboot 失败")

        return false
    }

    /// 杀掉 SpringBoard + backboardd 触发系统级重启。
    /// 这与 respring 不同：同时杀两者会触发 launchd 重新初始化显示子系统，
    /// 效果类似"软重启"（类似 sbreload）。
    private func killSpringBoardForReboot() -> Bool {
        var killed = false

        if let pid = getProcessPID(named: "SpringBoard") {
            Log.shared.add("   杀 SpringBoard (PID=\(pid))...")
            if kill(pid, SIGKILL) == 0 {
                Log.shared.add("   ✅ SpringBoard 已终止")
                killed = true
            } else {
                Log.shared.add("   ❌ kill SpringBoard 失败: \(String(cString: strerror(errno)))")
            }
        }

        if let pid = getProcessPID(named: "backboardd") {
            Log.shared.add("   杀 backboardd (PID=\(pid))...")
            if kill(pid, SIGKILL) == 0 {
                Log.shared.add("   ✅ backboardd 已终止")
                killed = true
            } else {
                Log.shared.add("   ❌ kill backboardd 失败: \(String(cString: strerror(errno)))")
            }
        }

        if killed {
            Log.shared.add("   SpringBoard/backboardd 已终止，系统正在重启 UI 子系统")
        }
        return killed
    }

    /// 主进程直接调用 kfd 提权并立即 reboot。
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

        // ==== KFD 内核漏洞测试 ====
        Log.shared.add("")
        Log.shared.add("--- KFD 内核漏洞测试 ---")
        testKfd()

        // ==== reboot() 直接调用测试 ====
        Log.shared.add("")
        Log.shared.add("--- reboot() 直接调用测试 ---")
        Log.shared.add("   说明: 我们已有 com.apple.private.system.restart 权限")
        Log.shared.add("         内核可能允许带此权限的进程直接调用 reboot(2)")
        Log.shared.add("         即使 UID != 0")
        testReboot()

        // ==== FrontBoard 重启可用性检查 ====
        Log.shared.add("")
        Log.shared.add("--- FrontBoard 重启路径检查 ---")
        testFrontBoardAvailability()
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

    // MARK: - KFD 内核漏洞测试

    /// 分步测试 kfd 内核漏洞利用链
    /// 捕获 kfd.c 的 printf 输出到诊断日志，精确定位失败步骤
    /// 注意：kfd 可能触发内核 panic/重启
    private func testKfd() {
        // ---- Step 1: kfd_init ----
        Log.shared.add("[1/4] kfd_init() 初始化漏洞链...")
        let initOut = captureStdout { _kfd_init() }
        if let o = initOut.text, !o.isEmpty {
            Log.shared.add("--- kfd_init stdout ---")
            logLines(o)
        }
        if initOut.ret != 0 {
            let err = _kfd_get_error()
            let msg = err != nil ? String(cString: err!) : "unknown"
            Log.shared.add("   ❌ kfd_init 失败: \(msg) (ret=\(initOut.ret))")
            return
        }
        Log.shared.add("   ✅ kfd_init 成功")

        // ---- Step 2: kfd_open ----
        Log.shared.add("[2/4] kfd_open() 打开内核读/写...")
        let openOut = captureStdout { _kfd_open() }
        if let o = openOut.text, !o.isEmpty {
            Log.shared.add("--- kfd_open stdout ---")
            logLines(o)
        }
        if openOut.ret != 0 {
            let err = _kfd_get_error()
            let msg = err != nil ? String(cString: err!) : "unknown"
            Log.shared.add("   ❌ kfd_open 失败: \(msg) (ret=\(openOut.ret))")
            _kfd_close()
            return
        }
        Log.shared.add("   ✅ kfd_open 成功！内核 r/w 已获得")

        // ---- Step 3: kfd_is_root ----
        Log.shared.add("[3/4] kfd_is_root() 检测当前进程状态...")
        let rootBefore = _kfd_is_root()
        Log.shared.add("   当前进程 root 状态: \(rootBefore) (0=否, 1=是)")

        // ---- Step 4: kfd_get_root ----
        Log.shared.add("[4/4] kfd_get_root() 利用内核写提升进程为 root...")
        let rootOut = captureStdout { _kfd_get_root() }
        if let o = rootOut.text, !o.isEmpty {
            Log.shared.add("--- kfd_get_root stdout ---")
            logLines(o)
        }
        if rootOut.ret != 0 {
            let err = _kfd_get_error()
            let msg = err != nil ? String(cString: err!) : "unknown"
            Log.shared.add("   ❌ kfd_get_root 失败: \(msg) (ret=\(rootOut.ret))")
            _kfd_close()
            return
        }

        // 检查提权后状态
        let rootAfter = _kfd_is_root()
        let afterUid = getuid()
        let afterEuid = geteuid()
        Log.shared.add("   提权后 root 状态: \(rootAfter)")
        Log.shared.add("   提权后 UID=\(afterUid) EUID=\(afterEuid)")

        if afterUid == 0 || afterEuid == 0 || rootAfter == 1 {
            Log.shared.add("   ✅ KFD 提权成功！进程已 root")
            let testPaths = ["/sbin/reboot", "/etc/master.passwd"]
            for p in testPaths {
                let acc = access(p, Int32(F_OK))
                Log.shared.add("   (root) access(\(p), F_OK)=\(acc)")
                if acc == 0 {
                    var st = stat()
                    if stat(p, &st) == 0 {
                        Log.shared.add("         size=\(st.st_size) mode=\(String(st.st_mode, radix: 8))")
                    }
                }
            }
        } else {
            Log.shared.add("   ❌ KFD 提权失败：内核写成功但 UID 未变化")
        }

        Log.shared.add("   提示：kfd 句柄保持打开，如需关闭请重启 App")
    }

    // MARK: - reboot() 直接调用测试

    /// 测试直接调用 Darwin.reboot() —— 利用已注册的 system.restart 权限
    /// XNU 内核的 reboot() 路径会检查 com.apple.private.system.restart 权限
    /// 如果权限有效，允许非 root 进程执行重启
    private func testReboot() {
        // 先确认权限状态
        let task = SecTaskCreateFromSelf(nil)
        let hasRestart = SecTaskCopyValueForEntitlement(task, "com.apple.private.system.restart" as CFString, nil)
        let hasShutdown = SecTaskCopyValueForEntitlement(task, "com.apple.private.system.shutdown" as CFString, nil)

        Log.shared.add("   确认 system.restart: \(hasRestart != nil ? "已注册" : "未注册")")
        Log.shared.add("   确认 system.shutdown: \(hasShutdown != nil ? "已注册" : "未注册")")

        // 尝试 reboot(0) = RB_AUTOBOOT
        // ⚠️ 如果内核允许，设备会立即重启，以下代码不会执行
        Log.shared.add("   尝试 reboot(RB_AUTOBOOT=0)...")

        let ret = Darwin.reboot(0) // RB_AUTOBOOT
        let err = errno
        Log.shared.add("   Darwin.reboot(0) 返回=\(ret) errno=\(err) (\(String(cString: strerror(err))))")

        if ret == 0 {
            Log.shared.add("   ✅ reboot() 成功！设备应正在重启...")
        } else {
            Log.shared.add("   ❌ reboot() 失败: 内核拒绝")
            Log.shared.add("   → system.restart 权限不足以执行 reboot")

            // 再试 sync + reboot (RB_AUTOBOOT)
            sync()
            let ret2 = Darwin.reboot(0)
            let err2 = errno
            Log.shared.add("   sync后 reboot(0) 返回=\(ret2) errno=\(err2) (\(String(cString: strerror(err2))))")
        }
    }

    // MARK: - FrontBoard 重启可用性检查

    /// 检查 FrontBoard 重启路径是否可用（不实际执行重启）
    private func testFrontBoardAvailability() {
        let task = SecTaskCreateFromSelf(nil)
        let hasFrontboard = SecTaskCopyValueForEntitlement(task, "com.apple.frontboard.shutdown" as CFString, nil)
        let hasSystemApp = SecTaskCopyValueForEntitlement(task, "com.apple.frontboard.systemapp" as CFString, nil)
        Log.shared.add("   com.apple.frontboard.shutdown: \(hasFrontboard != nil ? "已注册" : "未注册")")
        Log.shared.add("   com.apple.frontboard.systemapp: \(hasSystemApp != nil ? "已注册" : "未注册")")

        let fbPath = "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices"
        guard let handle = dlopen(fbPath, RTLD_NOW) else {
            Log.shared.add("   ❌ FrontBoardServices 框架无法加载: \(String(cString: dlerror()))")
            return
        }
        defer { dlclose(handle) }

        guard let cls = NSClassFromString("FBSSystemService") as? NSObject.Type else {
            Log.shared.add("   ❌ FBSSystemService 类未找到")
            return
        }
        Log.shared.add("   ✅ FBSSystemService 类存在")

        let sharedSel = NSSelectorFromString("sharedService")
        if cls.responds(to: sharedSel) {
            Log.shared.add("   ✅ +sharedService 方法存在")
            if let svc = cls.perform(sharedSel)?.takeUnretainedValue() {
                Log.shared.add("   ✅ sharedService 实例已获取")
                for selName in ["shutdownWithOptions:", "reboot", "shutdown"] {
                    let sel = NSSelectorFromString(selName)
                    let has = svc.responds(to: sel)
                    Log.shared.add("   \(has ? "✅" : "❌") -\(selName)")
                }
            } else {
                Log.shared.add("   ❌ sharedService 返回 nil")
            }
        } else {
            Log.shared.add("   ❌ +sharedService 方法不存在")
        }
    }

    /// 捕获 stdout：重定向 stdout → pipe，执行闭包，恢复 stdout，返回 (返回值, stdout文本)
    private func captureStdout(_ block: () -> Int32) -> (ret: Int32, text: String?) {
        // flush 当前 stdout
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        guard saved >= 0 else { return (block(), nil) }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else {
            close(saved)
            return (block(), nil)
        }

        dup2(fds[1], STDOUT_FILENO)
        close(fds[1])

        let ret = block()

        fflush(stdout)
        fsync(STDOUT_FILENO)

        // 读 pipe
        var buf = [UInt8](repeating: 0, count: 65536)
        let n = read(fds[0], &buf, buf.count - 1)
        close(fds[0])

        // 恢复 stdout
        dup2(saved, STDOUT_FILENO)
        close(saved)

        let text: String?
        if n > 0 {
            buf[Int(n)] = 0
            text = String(cString: buf)
        } else {
            text = nil
        }
        return (ret, text)
    }

    /// 将多行文本分行添加到日志
    private func logLines(_ text: String) {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { Log.shared.add("   \(t)") }
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
            ("com.apple.frontboard.shutdown",             "FrontBoard重启"),
            ("com.apple.frontboard.systemapp",            "FrontBoard系统应用"),
            ("com.apple.private.security.iokit-user-client-class", "IOKit UC类"),
            ("com.apple.private.iokit.user-client-access", "IOKit UC访问"),
            ("com.apple.developer.kernel.increased-memory-limit", "内核扩内存"),
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
            ("com.apple.frontboard.shutdown",               "FrontBoard重启"),
            ("com.apple.frontboard.systemapp",              "FrontBoard系统应用"),
            ("com.apple.private.security.iokit-user-client-class", "IOKit UC类"),
            ("com.apple.private.iokit.user-client-access",  "IOKit UC访问"),
            ("com.apple.developer.kernel.increased-memory-limit", "内核扩内存"),
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
