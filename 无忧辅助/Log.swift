//
//  Log.swift
//  无忧辅助
//
//  全局日志管理器
//

import Foundation
import os

final class Log: ObservableObject {
    static let shared = Log()

    @Published var entries: [LogEntry] = []

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private let logger = Logger(subsystem: "com.wuyou.helper", category: "general")

    private init() {}

    func add(_ message: String, level: LogLevel = .info) {
        let entry = LogEntry(
            timestamp: dateFormatter.string(from: Date()),
            message: message,
            level: level
        )
        DispatchQueue.main.async {
            self.entries.append(entry)
            // 限制日志数量
            if self.entries.count > 500 {
                self.entries.removeFirst(100)
            }
        }
        logger.log("\(message, privacy: .public)")
    }

    func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }

    /// 将所有日志合并为纯文本，方便复制
    var fullText: String {
        entries.map { "[\($0.timestamp)] \($0.message)" }.joined(separator: "\n")
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp: String
    let message: String
    let level: LogLevel
}

enum LogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    case debug = "DEBUG"
}
