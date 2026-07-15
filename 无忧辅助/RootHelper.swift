//
//  RootHelper.swift
//  无忧辅助
//
//  通过 posix_spawn 以 root 权限执行外部 helper 二进制
//  helper 内部执行系统命令：
//    - 强制重启: reboot(RB_AUTOBOOT) syscall
//    - 重启桌面: killall -9 SpringBoard
//

import Foundation
import Darwin

// MARK: - Persona API (私有 API，存在于 libSystem 但不在 iOS SDK 中)

/// POSIX_SPAWN_PERSONA_SYSTEM = 99
private let PERSONA_SYSTEM: uid_t = 99
/// POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE = 1
private let PERSONA_FLAGS_OVERRIDE: UInt32 = 1

@_silgen_name("posix_spawnattr_set_persona_np")
private func posix_spawnattr_set_persona_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ persona_id: uid_t,
    _ flags: UInt32
) -> Int32

@_silgen_name("posix_spawnattr_set_persona_uid_np")
private func posix_spawnattr_set_persona_uid_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>,
    _ uid: uid_t
) -> Int32

@_silgen_name("posix_spawnattr_set_persona_gid_np")
private func posix_spawnattr_set_persona_gid_np(
    _ attr: UnsafeMutablePointer<posix_spawnattr_t?>,
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

    /// 强制重启手机 — roothelper 执行 reboot(RB_AUTOBOOT)
    func reboot() -> Bool {
        guard let path = helperPath else { return false }
        Log.shared.add("🔧 请求强制重启 (reboot syscall)...")
        return spawnRoot(path: path, command: "reboot")
    }

    /// 重启桌面（注销） — roothelper 执行 killall -9 SpringBoard
    func respring() -> Bool {
        guard let path = helperPath else { return false }
        Log.shared.add("🔧 请求重启桌面 (killall -9 SpringBoard)...")
        return spawnRoot(path: path, command: "respring")
    }

    // MARK: - posix_spawn 以 root 身份执行

    /// 以 root 权限 spawn roothelper
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

        // 关键：设置 persona 以 root 身份执行
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
}

// MARK: - C 宏兼容

private func wifexited(_ status: Int32) -> Bool {
    return (status & 0x7f) == 0
}

private func wexitstatus(_ status: Int32) -> Int32 {
    return (status >> 8) & 0xff
}
