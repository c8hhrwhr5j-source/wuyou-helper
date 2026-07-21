//
//  LuaScriptManager.swift
//  无忧辅助 - Swift 层封装 OC ScriptEngine + 文件管理
//

import SwiftUI

/// UI 日志行
struct ScriptLogLine: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
}

/// Lua 脚本状态（映射 OC ScriptState）
enum LuaState: Int, Equatable {
    case idle = 0
    case running = 1
    case paused = 2
    case stopping = 3
    case error = 4
}

/// 脚本文件信息
struct ScriptFile: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let modifiedAt: Date
}

/// Lua 脚本管理器 — 桥接 OC ScriptEngine，提供 SwiftUI 数据绑定 + 文件管理
final class LuaScriptManager: ObservableObject {
    static let shared = LuaScriptManager()

    @Published var logLines: [ScriptLogLine] = []
    @Published var state: LuaState = .idle
    @Published var savedFiles: [ScriptFile] = []
    @Published var currentFilePath: String?

    private let engine: ScriptEngine

    /// 脚本存储目录（无沙盒可访问）
    static var scriptsDirectory: String {
        // /var/mobile/Documents/无忧辅助/scripts/
        let base = "/var/mobile/Documents/无忧辅助/scripts"
        let fm = FileManager.default
        if !fm.fileExists(atPath: base) {
            try? fm.createDirectory(atPath: base,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o755])
        }
        return base
    }

    private init() {
        engine = ScriptEngine.shared()

        engine.logHandler = { [weak self] msg in
            DispatchQueue.main.async {
                self?.appendLog(msg, color: .primary)
            }
        }

        engine.stateChangeHandler = { [weak self] newState in
            DispatchQueue.main.async {
                let mapped = LuaState(rawValue: newState.rawValue) ?? .error
                self?.state = mapped
                switch mapped {
                case .running:
                    self?.appendLog("▶ 脚本开始运行", color: .green)
                case .paused:
                    self?.appendLog("⏸ 脚本已暂停", color: .orange)
                case .idle:
                    self?.appendLog("⏹ 脚本已停止", color: .gray)
                case .error:
                    self?.appendLog("❌ 脚本异常", color: .red)
                case .stopping:
                    self?.appendLog("⏳ 正在停止...", color: .orange)
                }
            }
        }

        // 初始化时刷新文件列表
        refreshFileList()
    }

    // MARK: - 脚本执行

    var isRunning: Bool { state == .running || state == .paused }
    var isPaused: Bool { state == .paused }

    var statusText: String {
        switch state {
        case .idle:     return "就绪"
        case .running:  return "运行中"
        case .paused:   return "已暂停"
        case .stopping: return "停止中"
        case .error:    return "错误"
        }
    }

    var statusColor: Color {
        switch state {
        case .idle:     return .gray
        case .running:  return .green
        case .paused:   return .orange
        case .stopping: return .orange
        case .error:    return .red
        }
    }

    func runScript(_ code: String) {
        clearLog()
        _ = engine.runScript(code)
    }

    func runScriptFile(_ path: String) {
        clearLog()
        _ = engine.runScriptFile(path)
    }

    func pause() { engine.pause() }
    func resume() { engine.resume() }
    func stop() { engine.stop() }

    func clearLog() { logLines.removeAll() }

    func defaultScript() -> String {
        return ScriptEngine.defaultScript()
    }

    // MARK: - 文件管理

    /// 刷新脚本文件列表
    func refreshFileList() {
        let dir = Self.scriptsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            savedFiles = []
            return
        }

        savedFiles = files
            .filter { $0.hasSuffix(".lua") }
            .compactMap { name -> ScriptFile? in
                let path = (dir as NSString).appendingPathComponent(name)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                    return nil
                }
                return ScriptFile(
                    name: name,
                    path: path,
                    size: (attrs[.size] as? Int64) ?? 0,
                    modifiedAt: (attrs[.modificationDate] as? Date) ?? Date()
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// 加载文件内容
    func loadFile(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 保存代码到文件
    @discardableResult
    func saveScript(_ code: String, toPath path: String) -> Bool {
        guard let data = code.data(using: .utf8) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                  withIntermediateDirectories: true)
        let success = FileManager.default.createFile(atPath: path, contents: data,
                                                      attributes: [.posixPermissions: 0o644])
        if success {
            appendLog("已保存: \(path)", color: .green)
            refreshFileList()
        }
        return success
    }

    /// 删除脚本文件
    func deleteFile(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        refreshFileList()
    }

    // MARK: - 日志（公开供 View 调用）

    func appendLog(_ text: String, color: Color) {
        logLines.append(ScriptLogLine(text: text, color: color))
        if logLines.count > 1000 {
            logLines.removeFirst(200)
        }
    }
}
