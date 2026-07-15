//
//  PhoneControlView.swift
//  无忧辅助
//
//  手机控制区域：【重启设备】【注销设备】
//    - 重启: reboot() syscall + trollstorehelper 多策略回退
//    - 注销: proc_listpids + kill(SpringBoard, SIGKILL)（参考 TrollServer）
//    - 弹窗: 通过 UIKit UIAlertController（避免 SwiftUI .alert + TabView 嵌套 Bug）
//

import SwiftUI
import Darwin

struct PhoneControlView: View {
    @State private var isExecuting = false

    var body: some View {
        VStack(spacing: 0) {
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

                        Text("TrollStore 无沙盒环境 · root 权限执行系统级操作")
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
                            title: "重启设备",
                            subtitle: "强制重启设备 (reboot syscall + 多策略回退)",
                            icon: "arrow.triangle.2.circlepath",
                            color: .red,
                            isExecuting: isExecuting
                        ) {
                            showUIKitAlert(
                                title: "确认重启设备？",
                                message: "设备将立即强制重启，未保存的数据可能丢失。",
                                destructiveTitle: "确认重启"
                            ) {
                                executeReboot()
                            }
                        }

                        // 注销设备按钮（Respring）
                        ControlButton(
                            title: "注销设备",
                            subtitle: "重启 SpringBoard (proc_listpids + kill SIGKILL)",
                            icon: "arrow.clockwise",
                            color: .orange,
                            isExecuting: isExecuting
                        ) {
                            showUIKitAlert(
                                title: "确认注销桌面？",
                                message: "SpringBoard 将重新启动，回到锁屏界面。",
                                destructiveTitle: "确认注销"
                            ) {
                                executeRespring()
                            }
                        }
                    }
                    .padding(.horizontal)

                    Divider()
                        .padding(.horizontal)

                    // ========== 状态信息 ==========
                    VStack(alignment: .leading, spacing: 12) {
                        InfoRow(label: "注销方式", value: "proc_listpids + kill(SIGKILL)")
                        InfoRow(label: "重启方式", value: "reboot syscall + trollstorehelper")
                        InfoRow(label: "Helper 路径", value: RootHelper.shared.helperPath ?? "未找到")
                        InfoRow(label: "适配版本", value: "iOS 15 ~ 18")
                    }
                    .padding(.horizontal)
                    .font(.caption)

                    Spacer()
                }
            }
        }
    }

    // MARK: - 执行操作

    private func executeReboot() {
        performAction(name: "重启", successMsg: "设备即将重启...", action: RootHelper.shared.reboot)
    }

    private func executeRespring() {
        performAction(name: "注销", successMsg: "设备正在注销...", action: RootHelper.shared.respring)
    }

    private func performAction(name: String, successMsg: String, action: @escaping () -> Bool) {
        isExecuting = true
        Log.shared.add("📱 UI触发: \(name)")
        DispatchQueue.global(qos: .userInitiated).async {
            let success = action()
            DispatchQueue.main.async {
                isExecuting = false
                let title: String
                let message: String
                if success {
                    title = "正在\(name)"
                    message = successMsg
                } else {
                    title = "\(name)失败"
                    let recentLogs = Log.shared.entries.suffix(5).map { $0.message }.joined(separator: "\n")
                    message = "UID=\(getuid())\nHelper: \(RootHelper.shared.helperPath ?? "未找到")\n\n日志:\n\(recentLogs)"
                }
                showUIKitAlert(title: title, message: message, dismissTitle: "确定")
            }
        }
    }

    // MARK: - UIKit Alert（可靠弹窗，不受 SwiftUI TabView 嵌套影响）

    private func showUIKitAlert(
        title: String,
        message: String,
        destructiveTitle: String? = nil,
        dismissTitle: String = "取消",
        destructiveAction: (() -> Void)? = nil
    ) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            // 回退：直接打印日志
            Log.shared.add("⚠️ 无法获取 rootViewController，弹窗已跳过")
            destructiveAction?()
            return
        }

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)

        if let destructiveTitle, let destructiveAction {
            alert.addAction(UIAlertAction(title: destructiveTitle, style: .destructive) { _ in
                destructiveAction()
            })
            alert.addAction(UIAlertAction(title: dismissTitle, style: .cancel))
        } else {
            alert.addAction(UIAlertAction(title: dismissTitle, style: .default))
        }

        // 找到最顶层的 presented VC 来 present
        var topVC = rootVC
        while let presented = topVC.presentedViewController {
            topVC = presented
        }
        topVC.present(alert, animated: true)
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
