//
//  MainTabView.swift
//  无忧辅助
//
//  主界面 Tab 导航：左下角脚本控制，右下角设置
//

import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            ScriptFileView()
                .tabItem {
                    Image(systemName: "play.rectangle.fill")
                    Text("脚本控制")
                }
                .tag(0)

            SettingsView()
                .tabItem {
                    Image(systemName: "gearshape.fill")
                    Text("设置")
                }
                .tag(1)
        }
        .accentColor(.orange)
    }
}

struct MainTabView_Previews: PreviewProvider {
    static var previews: some View {
        MainTabView()
    }
}
