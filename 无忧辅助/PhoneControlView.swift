//
//  PhoneControlView.swift
//  无忧辅助
//
//  手机控制区域：【重启手机】【注销手机】【关机】
//  Swift 只负责 UI，真正干活由 roothelper 二进制通过 system() 执行
//

import SwiftUI

struct PhoneControlView: View {
    @State private var showRebootAlert = false
    @State private var showRespringAlert = false
    @State private var showShutdownAlert = false
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
                            subtitle: "强制重启设备 (shutdown -r now)",
                            icon: "arrow.triangle.2.circlepath",
                            color: .red,
                            isExecuting: isExecuting
                        ) {
                            showRebootAlert = true
                        }

                        // 注销手机按钮（Respring）
                        ControlButton(
                            title: "注销手机",
                            subtitle: "重启 SpringBoard 桌面 (killall SpringBoard)",
                            icon: "arrow.clockwise",
                            color: .orange,
                            isExecuting: isExecuting
                        ) {
                            showRespringAlert = true
                        }

                        // 关机按钮
                        ControlButton(
                            title: "关机",
                            subtitle: "完全关闭设备 (shutdown -h now)",
                            icon: "power",
                            color: .gray,
                            isExecuting: isExecuting
                        ) {
                            showShutdownAlert = true
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
                        InfoRow(label: "执行方式", value: "system() 系统调用")
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
        .alert(isPresented: $showRebootAlert) {
            Alert(
                title: Text("确认重启手机？"),
                message: Text("手机将立即强制重启，未保存的数据可能丢失。"),
                primaryButton: .destructive(Text("确认重启"), action: executeReboot),
                secondaryButton: .cancel(Text("取消"))
            )
        }
        // ========== 注销确认弹窗 ==========
        .alert(isPresented: $showRespringAlert) {
            Alert(
                title: Text("确认注销手机？"),
                message: Text("SpringBoard 将重新启动，回到锁屏界面。"),
                primaryButton: .destructive(Text("确认注销"), action: executeRespring),
                secondaryButton: .cancel(Text("取消"))
            )
        }
        // ========== 关机确认弹窗 ==========
        .alert(isPresented: $showShutdownAlert) {
            Alert(
                title: Text("确认关机？"),
                message: Text("设备将完全关闭，需要手动按电源键开机。"),
                primaryButton: .destructive(Text("确认关机"), action: executeShutdown),
                secondaryButton: .cancel(Text("取消"))
            )
        }
        // ========== 结果弹窗 ==========
        .alert(isPresented: $showResultAlert) {
            Alert(
                title: Text(alertTitle),
                message: Text(alertMessage),
                dismissButton: .default(Text("确定"))
            )
        }
    }

    // MARK: - 执行操作

    private func executeReboot() {
        performAction(name: "重启", successMsg: "手机即将重启...", action: RootHelper.shared.reboot)
    }

    private func executeRespring() {
        performAction(name: "注销", successMsg: "手机正在注销...", action: RootHelper.shared.respring)
    }

    private func executeShutdown() {
        performAction(name: "关机", successMsg: "手机正在关机...", action: RootHelper.shared.shutdown)
    }

    private func performAction(name: String, successMsg: String, action: @escaping () -> Bool) {
        isExecuting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let success = action()
            DispatchQueue.main.async {
                isExecuting = false
                if success {
                    alertTitle = "正在\(name)"
                    alertMessage = successMsg
                } else {
                    alertTitle = "\(name)失败"
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
