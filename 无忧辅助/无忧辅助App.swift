//
//  无忧辅助App.swift
//  无忧辅助 - TrollStore IPA
//
//  主入口：Swift 只负责 UI，脏活全是外部二进制干的
//

import SwiftUI

@main
struct 无忧辅助App: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}
