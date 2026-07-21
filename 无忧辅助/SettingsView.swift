//
//  SettingsView.swift
//  无忧辅助
//
//  设置界面：设备信息 + 注销
//

import SwiftUI

struct SettingsView: View {
    @State private var isRespring = false

    // ── 设备信息（计算属性） ──
    private var deviceName: String    { UIDevice.current.name }
    private var systemVersion: String { UIDevice.current.systemVersion }
    private var appVersion: String    { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    private var buildNumber: String   { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    private var bundleID: String      { Bundle.main.bundleIdentifier ?? "?" }

    var body: some View {
        NavigationView {
            List {
                // ── 注销 ──
                Section {
                    Button(action: confirmRespring) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("注销设备")
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("重启 SpringBoard，回到锁屏")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if isRespring {
                                ProgressView()
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .disabled(isRespring)
                } header: {
                    Text("系统操作")
                }

                // ── 设备信息 ──
                Section {
                    InfoRow(title: "设备名称", value: deviceName)
                    InfoRow(title: "设备型号", value: DeviceInfo.hwModel())
                    InfoRow(title: "CPU 架构", value: "ARM64 (Apple Silicon)")
                    InfoRow(title: "系统版本", value: "iOS \(systemVersion)")
                    InfoRow(title: "屏幕分辨率", value: DeviceInfo.resolutionDescription())
                    InfoRow(title: "设备标识", value: DeviceInfo.deviceUUID())
                } header: {
                    Text("设备信息")
                }

                // ── 应用信息 ──
                Section {
                    InfoRow(title: "应用版本", value: "\(appVersion) (Build \(buildNumber))")
                    InfoRow(title: "Bundle ID", value: bundleID)
                    InfoRow(title: "运行用户", value: "uid=\(getuid()) euid=\(geteuid())")
                } header: {
                    Text("应用信息")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Resring

    private func confirmRespring() {
        showUIKitAlert(
            title: "确认注销桌面？",
            message: "SpringBoard 将重新启动，回到锁屏界面。",
            destructiveTitle: "确认注销"
        ) {
            isRespring = true
            Log.shared.add("🔄 执行注销...")
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = TrollRootManager.shared.deviceRespring()
                DispatchQueue.main.async {
                    isRespring = false
                    if !ok {
                        Log.shared.add("❌ 注销失败")
                    }
                }
            }
        }
    }

    // MARK: - Alert

    private func showUIKitAlert(
        title: String,
        message: String,
        destructiveTitle: String,
        action: @escaping () -> Void
    ) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            action()
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: destructiveTitle, style: .destructive) { _ in action() })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        var topVC = rootVC
        while let p = topVC.presentedViewController { topVC = p }
        topVC.present(alert, animated: true)
    }
}

// MARK: - 信息行组件

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 1)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}
