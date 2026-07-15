//
//  LogView.swift
//  无忧辅助
//
//  运行日志查看
//

import SwiftUI

struct LogView: View {
    @StateObject private var log = Log.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if log.entries.isEmpty {
                    // 空状态
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("暂无日志")
                            .foregroundColor(.secondary)
                        Text("执行操作后将在此显示日志")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    // 日志列表
                    List {
                        ForEach(log.entries.reversed()) { entry in
                            LogRow(entry: entry)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("清空") {
                        log.clear()
                    }
                    .disabled(log.entries.isEmpty)
                }
            }
        }
    }
}

// MARK: - 日志行

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 时间戳
            Text(entry.timestamp)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)

            // 级别标签
            Text(levelEmoji)
                .font(.caption)

            // 消息内容
            Text(entry.message)
                .font(.caption)
                .foregroundColor(.primary)
        }
        .padding(.vertical, 2)
    }

    private var levelEmoji: String {
        switch entry.level {
        case .info:    return "ℹ️"
        case .warning: return "⚠️"
        case .error:   return "❌"
        case .debug:   return "🔍"
        }
    }
}

#Preview {
    LogView()
}
