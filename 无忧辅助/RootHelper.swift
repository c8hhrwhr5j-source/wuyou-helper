//
//  RootHelper.swift
//  无忧辅助
//
//  通过 posix_spawn 以 root 权限执行外部 helper 二进制
//  Swift 只负责 UI，脏活全是外部二进制干的
//

import Foundation
import Darwin

final class RootHelper {
    static let shared = RootHelper()

    /// helper 二进制名称（编译后放入 .app bundle）
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
        return spawnRoot(command: "reboot")
    }

    /// 注销手机 (Respring)
    func respring() -> Bool {
        return spawnRoot(command: "respring")
    }

    // ============================================================
    // 预留接口（后续实现找色/点击/滑动等功能时扩展）
    // ============================================================

    /// 执行 Shell 命令（预留通用接口）
    func executeShell(_ command: String) -> (output: String, success: Bool) {
        guard let path = helperPath else {
            return ("helper 未找到", false)
        }
        return spawnWithOutput(path: path, args: ["shell", command])
    }

    // MARK: - posix_spawn 核心实现

    /// 以 root 权限执行 helper 命令（无输出收集）
    private func spawnRoot(command: String) -> Bool {
        guard let path = helperPath else {
            Log.shared.add("❌ Helper 二进制未找到")
            return false
        }

        Log.shared.add("🔧 执行命令: \(command)")

        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup(path),
            strdup(command),
            nil
        ]
        defer { argv.forEach { $0.map { free($0) } } }

        let ret = posix_spawn(&pid, path, nil, nil, &argv, nil)

        if ret == 0 {
            Log.shared.add("✅ posix_spawn 成功 (pid: \(pid))")
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            return wifexited(status) && wexitstatus(status) == 0
        } else {
            Log.shared.add("❌ posix_spawn 失败 (errno: \(ret))")
            return false
        }
    }

    /// 带输出收集的 spawn
    private func spawnWithOutput(path: String, args: [String]) -> (output: String, success: Bool) {
        let pipe = Pipe()

        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        defer { argv.forEach { $0.map { free($0) } } }

        let attrPtr = UnsafeMutablePointer<posix_spawnattr_t>.allocate(capacity: 1)
        let fileActionsPtr = UnsafeMutablePointer<posix_spawn_file_actions_t>.allocate(capacity: 1)
        defer {
            posix_spawn_file_actions_destroy(fileActionsPtr)
            posix_spawnattr_destroy(attrPtr)
            attrPtr.deallocate()
            fileActionsPtr.deallocate()
        }

        posix_spawnattr_init(attrPtr)
        posix_spawn_file_actions_init(fileActionsPtr)
        posix_spawn_file_actions_adddup2(fileActionsPtr, pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(fileActionsPtr, pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let ret = posix_spawn(&pid, path, fileActionsPtr, attrPtr, &argv, environ)

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
}

// MARK: - C 宏兼容（Swift 6 下 sys/wait.h 宏不可直接调用）

private func wifexited(_ status: Int32) -> Bool {
    return (status & 0x7f) == 0
}

private func wexitstatus(_ status: Int32) -> Int32 {
    return (status >> 8) & 0xff
}
