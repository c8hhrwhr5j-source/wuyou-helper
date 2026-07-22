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

        // 创建目录
        if !fm.fileExists(atPath: scriptPath) {
            do {
                try fm.createDirectory(atPath: scriptPath, withIntermediateDirectories: true, attributes: nil)
                NSLog("[无忧辅助] 已创建脚本目录: \(scriptPath)")
            } catch {
                NSLog("[无忧辅助] 创建脚本目录失败: \(error.localizedDescription)")
                return
            }
        }

        // 从 bundle 复制 main.lua 到脚本目录（仅首次）
        let targetPath = "\(scriptPath)/main.lua"
        if !fm.fileExists(atPath: targetPath) {
            if let bundlePath = Bundle.main.path(forResource: "main", ofType: "lua") {
                do {
                    try fm.copyItem(atPath: bundlePath, toPath: targetPath)
                    NSLog("[无忧辅助] 已复制 main.lua 到: \(targetPath)")
                } catch {
                    NSLog("[无忧辅助] 复制 main.lua 失败: \(error.localizedDescription)")
                }
            } else {
                NSLog("[无忧辅助] bundle 中未找到 main.lua")
            }
        }
    }
}
