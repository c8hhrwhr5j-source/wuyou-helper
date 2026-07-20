//
//  LogView.swift
//  无忧辅助
//
//  运行日志查看 - 文本模式，支持选择和复制
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
                    // 可选中、可滚动的纯文本日志
                    LogTextView(text: log.fullText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("全选") {
                        UIPasteboard.general.string = log.fullText
                    }
                    .disabled(log.entries.isEmpty)
                }
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

// MARK: - 纯文本视图（UIKit 桥接，支持选择和复制）

struct LogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = .systemBackground
        tv.textColor = .label
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.text = text
        // 自动滚动到底部
        tv.scrollRangeToVisible(NSRange(location: text.utf16.count, length: 0))
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let shouldScroll = uiView.contentOffset.y + uiView.bounds.height >= uiView.contentSize.height - 60
        uiView.text = text
        if shouldScroll {
            uiView.scrollRangeToVisible(NSRange(location: text.utf16.count, length: 0))
        }
    }
}

struct LogView_Previews: PreviewProvider {
    static var previews: some View {
        LogView()
    }
}
