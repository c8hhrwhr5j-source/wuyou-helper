//
//  ScriptControlView.swift
//  无忧辅助
//
//  脚本控制区域 - 预留（后续实现找色、点击、按住滑动等）
//

import SwiftUI

struct ScriptControlView: View {
    @State private var scriptEnabled = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {

                    // 头部
                    VStack(spacing: 8) {
                        Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                            .font(.system(size: 48))
                            .foregroundColor(.blue)

                        Text("脚本控制区域")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("找色 / 点击 / 滑动 — 即将上线")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    Divider()
                        .padding(.horizontal)

                    // 功能占位列表
                    VStack(spacing: 12) {
                        FeaturePlaceholder(
                            icon: "eyedropper",
                            title: "找色",
                            description: "屏幕取色、多点匹配、颜色范围检测",
                            color: .purple
                        )
                        FeaturePlaceholder(
                            icon: "hand.tap",
                            title: "点击",
                            description: "模拟屏幕点击（单点/多点/连点）",
                            color: .green
                        )
                        FeaturePlaceholder(
                            icon: "hand.draw",
                            title: "按住滑动",
                            description: "模拟触摸拖动 / 滑动手势",
                            color: .blue
                        )
                        FeaturePlaceholder(
                            icon: "rectangle.on.rectangle",
                            title: "图像识别",
                            description: "截图比对、模板匹配",
                            color: .pink
                        )
                        FeaturePlaceholder(
                            icon: "text.insert",
                            title: "文字输入",
                            description: "模拟键盘输入",
                            color: .teal
                        )
                        FeaturePlaceholder(
                            icon: "clock.arrow.2.circlepath",
                            title: "延时循环",
                            description: "脚本编排 / 循环执行",
                            color: .indigo
                        )
                    }
                    .padding(.horizontal)

                    Spacer()
                }
            }
            .navigationTitle("脚本控制")
            .navigationBarTitleDisplayMode(.inline)
            .overlay(alignment: .bottom) {
                VStack {
                    Text("🔧 更多功能开发中...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }
            }
        }
    }
}

// MARK: - 功能占位卡片

struct FeaturePlaceholder: View {
    let icon: String
    let title: String
    let description: String
    let color: Color

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(color)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text("即将上线")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color(.systemGray5))
                )
        }
        .padding(12)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

#Preview {
    ScriptControlView()
}
