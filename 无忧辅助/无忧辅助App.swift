//
//  无忧辅助App.swift
//  无忧辅助
//

import SwiftUI

@main
struct ____App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        ScriptDirectoryHelper.ensureScriptDirectory()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}

// MARK: - 脚本目录初始化

enum ScriptDirectoryHelper {
    static let scriptPath = "/var/mobile/Media/script/lua"

    static func ensureScriptDirectory() {
        let fm = FileManager.default
        if fm.fileExists(atPath: scriptPath) { return }

        do {
            try fm.createDirectory(atPath: scriptPath, withIntermediateDirectories: true, attributes: nil)
            NSLog("[无忧辅助] 已创建脚本目录: \(scriptPath)")
        } catch {
            NSLog("[无忧辅助] 创建脚本目录失败: \(error.localizedDescription)")
        }
    }
}
