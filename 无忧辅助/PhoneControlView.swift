//
//  PhoneControlView.swift
//  无忧辅助
//
//  手机控制区域：【重启手机】【注销手机】
//  Swift 只负责 UI，真正干活由 roothelper 二进制执行
//

import SwiftUI

struct PhoneControlView: View {
    @State private var showRebootAlert = false
    @State private var showRespringAlert = false
    @State private var showResultAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var isExecuting = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {

                    // ========== 头部说明 ==========
                    VStack(spacing: 8) {
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)

                        Text("手机控制区域")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("root 权限执行系统级操作")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    Divider()
                        .padding(.horizontal)

                    // ========== 控制按钮 ==========
                    VStack(spacing: 18) {

                        // 重启手机按钮
                        ControlButton(
                            title: "重启手机",
                            subtitle: "完全重启设备（等同于关机再开机）",
                            icon: "arrow.triangle.2.circlepath",
                            color: .red,
                            isExecuting: isExecuting
                        ) {
                            showRebootAlert = true
                        }

                        // 注销手机按钮（Respring）
                        ControlButton(
                            title: "注销手机",
                            subtitle: "重启 SpringBoard（用户态注销）",
                            icon: "arrow.clockwise",
                            color: .orange,
                            isExecuting: isExecuting
                        ) {
                            showRespringAlert = true
                        }
                    }
                    .padding(.horizontal)

                    Divider()
                        .padding(.horizontal)

                    // ========== 状态信息 ==========
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow(label: "权限状态", value: "平台级应用 (no-sandbox)")
                        InfoRow(label: "进程权限", value: "root (posix_spawn)")
                        InfoRow(label: "Helper 路径", value: RootHelper.shared.helperPath ?? "未找到")
                    }
                    .padding(.horizontal)
                    .font(.caption)

                    Spacer()
                }
            }
            .navigationTitle("无忧辅助")
            .navigationBarTitleDisplayMode(.inline)
        }
        // ========== 重启确认弹窗 ==========
        .alert("确认重启手机？", isPresented: $showRebootAlert) {
            Button("取消", role: .cancel) {}
            Button("确认重启", role: .destructive) {
                executeReboot()
            }
        } message: {
            Text("手机将立即重启，未保存的数据可能丢失。")
        }
        // ========== 注销确认弹窗 ==========
        .alert("确认注销手机？", isPresented: $showRespringAlert) {
            Button("取消", role: .cancel) {}
            Button("确认注销", role: .destructive) {
                executeRespring()
            }
        } message: {
            Text("SpringBoard 将重新启动，回到锁屏界面。")
        }
        // ========== 结果弹窗 ==========
        .alert(alertTitle, isPresented: $showResultAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    // MARK: - 执行操作

    private func executeReboot() {
        isExecuting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let success = RootHelper.shared.reboot()
            DispatchQueue.main.async {
                isExecuting = false
                if success {
                    alertTitle = "正在重启"
                    alertMessage = "手机即将重启..."
                } else {
                    alertTitle = "重启失败"
                    alertMessage = "请确认 helper 二进制是否已正确部署。\n路径: \(RootHelper.shared.helperPath ?? "未知")"
                }
                showResultAlert = true
            }
        }
    }

    private func executeRespring() {
        isExecuting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let success = RootHelper.shared.respring()
            DispatchQueue.main.async {
                isExecuting = false
                if success {
                    alertTitle = "正在注销"
                    alertMessage = "手机正在注销..."
                } else {
                    alertTitle = "注销失败"
                    alertMessage = "请确认 helper 二进制是否已正确部署。\n路径: \(RootHelper.shared.helperPath ?? "未知")"
                }
                showResultAlert = true
            }
        }
    }
}

// MARK: - 控制按钮组件

struct ControlButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let isExecuting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // 图标
                Image(systemName: icon)
                    .font(.system(size: 32))
                    .foregroundColor(color)
                    .frame(width: 44, height: 44)

                // 文字
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                // 箭头
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(Color(.systemBackground))
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        }
        .disabled(isExecuting)
        .opacity(isExecuting ? 0.5 : 1.0)
    }
}

// MARK: - 信息行

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .foregroundColor(.primary)
                .fontWeight(.medium)
        }
    }
}

struct PhoneControlView_Previews: PreviewProvider {
    static var previews: some View {
        PhoneControlView()
    }
}
