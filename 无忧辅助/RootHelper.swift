//
//  RootHelper.swift
//  无忧辅助
//
//  通过 posix_spawn 以 root 权限执行外部 helper 二进制
//  参考 TrollStore TSUtil.m 的 spawnRoot 实现
//

import Foundation
import Darwin

// MARK: - Persona API (私有 API，存在于 libSystem 但不在 iOS SDK 中)

/// POSIX_SPAWN_PERSONA_SYSTEM = 99
private let PERSONA_SYSTEM: uid_t = 99
/// POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE = 1
private let PERSONA_FLAGS_OVERRIDE: UInt32 = 1

/// reboot() 系统调用（Darwin 中可能被标记为不可用，手动声明）
@_silgen_name("reboot")
private func sys_reboot(_ howto: Int32) -> Int32

/// sync() — 同步磁盘缓存
@_silgen_name("sync")
private func sys_sync()

@_silgen_name("posix_spawnattr_set_persona_np")
private func posix_spawnattr_set_persona_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t>?,
    _ persona_id: uid_t,
    _ flags: UInt32
) -> Int32

@_silgen_name("posix_spawnattr_set_persona_uid_np")
private func posix_spawnattr_set_persona_uid_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t>?,
    _ uid: uid_t
) -> Int32

@_silgen_name("posix_spawnattr_set_persona_gid_np")
private func posix_spawnattr_set_persona_gid_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t>?,
    _ gid: gid_t
) -> Int32

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

    /// 重启手机
    func reboot() -> Bool {
        // 方式1: 尝试 roothelper
        if let path = helperPath {
            let result = spawnRoot(path: path, command: "reboot")
            if result {
                return true
            }
        }

        // 方式2: 直接尝试 reboot() 系统调用
        Log.shared.add("⚠️ roothelper 重启失败，尝试直接 reboot()...")
        sys_sync()
        sys_reboot(0) // RB_AUTOBOOT
        return true // reboot() 成功则不会返回
    }

    /// 注销手机 (Respring)
    func respring() -> Bool {
        // 方式1: 尝试 roothelper
        if let path = helperPath {
            let result = spawnRoot(path: path, command: "respring")
            if result {
                return true
            }
        }

        // 方式2: 直接 killall -9 SpringBoard
        Log.shared.add("⚠️ roothelper 注销失败，尝试直接 killall...")
        return directKillSpringBoard()
    }

    /// 执行 Shell 命令（预留通用接口）
    func executeShell(_ command: String) -> (output: String, success: Bool) {
        guard let path = helperPath else {
            return ("helper 未找到", false)
        }
        return spawnWithOutput(path: path, args: ["shell", command])
    }

    // MARK: - posix_spawn 以 root 身份执行

    /// 以 root 权限 spawn roothelper（参考 TrollStore TSUtil.m spawnRoot）
    private func spawnRoot(path: String, command: String) -> Bool {
        Log.shared.add("🔧 spawnRoot(\(command)) uid=\(getuid())")

        var pid: pid_t = 0

        // 构建 argv
        let pathC = strdup(path)
        let cmdC = strdup(command)
        defer { free(pathC); free(cmdC) }

        var argv: [UnsafeMutablePointer<CChar>?] = [pathC, cmdC, nil]

        // 初始化 spawn 属性
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }

        // ================================================================
        // 关键：设置 persona 以 root 身份执行（类似 TrollStore TSUtil）
        // ================================================================
        let personaRet = posix_spawnattr_set_persona_np(&attr, PERSONA_SYSTEM, PERSONA_FLAGS_OVERRIDE)
        Log.shared.add("   persona_np ret=\(personaRet)")

        let uidRet = posix_spawnattr_set_persona_uid_np(&attr, 0) // uid=0 (root)
        Log.shared.add("   persona_uid ret=\(uidRet)")

        let gidRet = posix_spawnattr_set_persona_gid_np(&attr, 0) // gid=0 (root)
        Log.shared.add("   persona_gid ret=\(gidRet)")

        // spawn 子进程（传递环境变量）
        let ret = posix_spawn(&pid, path, nil, &attr, &argv, environ)

        if ret == 0 {
            Log.shared.add("✅ posix_spawn 成功 (pid: \(pid))")
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            let exitCode = wifexited(status) ? wexitstatus(status) : -1
            Log.shared.add("   子进程退出码: \(exitCode)")
            return wifexited(status) && wexitstatus(status) == 0
        } else {
            Log.shared.add("❌ posix_spawn 失败 (ret: \(ret), errno: \(errno))")
            return false
        }
    }

    /// 带输出收集的 spawn
    private func spawnWithOutput(path: String, args: [String]) -> (output: String, success: Bool) {
        let pipe = Pipe()

        var pid: pid_t = 0
        var cArgs: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { cArgs.forEach { $0.map { free($0) } } }

        var attr: posix_spawnattr_t? = nil
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawn_file_actions_init(&fileActions)
        defer {
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&attr)
        }

        // 设置 root persona
        posix_spawnattr_set_persona_np(&attr, PERSONA_SYSTEM, PERSONA_FLAGS_OVERRIDE)
        posix_spawnattr_set_persona_uid_np(&attr, 0)
        posix_spawnattr_set_persona_gid_np(&attr, 0)

        posix_spawn_file_actions_adddup2(&fileActions, pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let ret = posix_spawn(&pid, path, &fileActions, &attr, &cArgs, environ)
        pipe.fileHandleForWriting.closeFile()

        if ret == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            return (output, wifexited(status) && wexitstatus(status) == 0)
        } else {
            return ("posix_spawn 失败: \(ret)", false)
        }
    }

    // MARK: - 备用直接方法

    /// 直接 kill SpringBoard（无需 roothelper）
    private func directKillSpringBoard() -> Bool {
        Log.shared.add("🔧 直接 killall -9 SpringBoard...")

        var pid: pid_t = 0
        let killall = strdup("/usr/bin/killall")
        let flag = strdup("-9")
        let target = strdup("SpringBoard")
        defer { free(killall); free(flag); free(target) }

        var argv: [UnsafeMutablePointer<CChar>?] = [killall, flag, target, nil]

        // 尝试以 root persona 执行
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_set_persona_np(&attr, PERSONA_SYSTEM, PERSONA_FLAGS_OVERRIDE)
        posix_spawnattr_set_persona_uid_np(&attr, 0)
        posix_spawnattr_set_persona_gid_np(&attr, 0)

        let ret = posix_spawn(&pid, "/usr/bin/killall", nil, &attr, &argv, environ)
        if ret == 0 {
            Log.shared.add("✅ killall 执行成功 (pid: \(pid))")
            return true
        }

        // 如果 root persona 不行，尝试不带 persona（mobile 用户）
        Log.shared.add("⚠️ root persona killall 失败，尝试 mobile killall...")
        var attr2: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr2)
        defer { posix_spawnattr_destroy(&attr2) }

        var pid2: pid_t = 0
        var argv2: [UnsafeMutablePointer<CChar>?] = [
            strdup("/usr/bin/killall"),
            strdup("-9"),
            strdup("SpringBoard"),
            nil
        ]
        defer { argv2.forEach { $0.map { free($0) } } }

        let ret2 = posix_spawn(&pid2, "/usr/bin/killall", nil, &attr2, &argv2, environ)
        if ret2 == 0 {
            Log.shared.add("✅ mobile killall 执行成功 (pid: \(pid2))")
            return true
        }

        Log.shared.add("❌ 所有 killall 方式均失败 (ret2: \(ret2))")
        return false
    }
}

// MARK: - C 宏兼容

private func wifexited(_ status: Int32) -> Bool {
    return (status & 0x7f) == 0
}

private func wexitstatus(_ status: Int32) -> Int32 {
    return (status >> 8) & 0xff
}
