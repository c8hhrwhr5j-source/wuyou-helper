//
//  MainTabView.swift
//  无忧辅助
//
//  主界面 Tab 导航
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // 手机控制区域
            PhoneControlView()
                .tabItem {
                    Image(systemName: "iphone.gen3")
                    Text("手机控制")
                }
                .tag(0)

            // 预留：脚本区域（找色/点击/滑动等）
            ScriptControlView()
                .tabItem {
                    Image(systemName: "play.rectangle")
                    Text("脚本控制")
                }
                .tag(1)

            // 预留：日志区域
            LogView()
                .tabItem {
                    Image(systemName: "doc.text")
                    Text("运行日志")
                }
                .tag(2)
        }
        .accentColor(.orange)
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
