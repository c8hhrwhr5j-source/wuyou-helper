//
//  ScriptControlView.swift
//  无忧辅助 - Lua 脚本编辑与控制界面（含文件管理）
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 脚本模板

struct ScriptTemplate: Identifiable {
    let id = UUID()
    let title: String
    let code: String

    static let templates: [ScriptTemplate] = [
        ScriptTemplate(title: "基础日志", code: """
            function main()
                log("=== Hello 无忧辅助 ===")
                local w, h = get_resolution()
                log(string.format("分辨率: %d x %d", w, h))
                sleep(500)
                log("=== 脚本结束 ===")
            end
            main()
            """),
        ScriptTemplate(title: "取色", code: """
            function main()
                local w, h = get_resolution()
                local cx, cy = w // 2, h // 2
                local r, g, b = get_screen_color(cx, cy)
                log(string.format("中心颜色: RGB(%d,%d,%d)", r, g, b))
                for _, c in ipairs({{0,0},{w-1,0},{0,h-1},{w-1,h-1}}) do
                    local cr,cg,cb = get_screen_color(c[1],c[2])
                    log(string.format("(%d,%d): RGB(%d,%d,%d)",c[1],c[2],cr,cg,cb))
                end
            end
            main()
            """),
        ScriptTemplate(title: "找色点击", code: """
            function main()
                log("开始找色...")
                local x, y = find_color(255, 0, 0, 20, 0, 0, 0, 0)
                if x and y then
                    log(string.format("找到红色在 (%d,%d)", x, y))
                    click(x, y)
                    log("已点击")
                else
                    log("未找到红色")
                end
            end
            main()
            """),
        ScriptTemplate(title: "滑动", code: """
            function main()
                local w, h = get_resolution()
                log("向上滑动...")
                swipe(w // 2, h * 3 // 4, w // 2, h // 4, 500)
                sleep(1000)
                log("向下滑动...")
                swipe(w // 2, h // 4, w // 2, h * 3 // 4, 500)
                log("完成")
            end
            main()
            """),
        ScriptTemplate(title: "循环监控", code: """
            function main()
                log("开始循环监控...")
                local count = 0
                while count < 10 do
                    local r,g,b = get_screen_color(100, 100)
                    log(string.format("[%d] RGB(%d,%d,%d)", count, r, g, b))
                    sleep(1000)
                    count = count + 1
                end
                log("监控结束")
            end
            main()
            """),
    ]
}

// MARK: - 主视图

struct ScriptControlView: View {
    @StateObject private var engine = LuaScriptManager.shared
    @State private var scriptCode = ""
    @State private var templateSelected: UUID?
    @State private var showingFilePicker = false
    @State private var showingSaveAlert = false
    @State private var saveFileName = ""
    @State private var showFileList = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // MARK: - 工具栏（文件操作）
                fileToolbar
                    .padding(.horizontal, 10)
                    .padding(.top, 8)

                Divider()
                    .padding(.top, 6)

                // MARK: - 代码编辑区
                editorSection

                Divider()

                // MARK: - 当前文件提示 + 模板
                currentFileBar
                templateSection

                Divider()

                // MARK: - 输出日志区
                outputSection
            }
            .navigationTitle("Lua 脚本")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing:
                Button {
                    showFileList.toggle()
                } label: {
                    Image(systemName: "folder.fill")
                }
            )
            .sheet(isPresented: $showingFilePicker) {
                DocumentPicker(
                    contentTypes: [.plainText, UTType(filenameExtension: "lua") ?? .plainText],
                    onPick: { url in
                        if url.startAccessingSecurityScopedResource() {
                            defer { url.stopAccessingSecurityScopedResource() }
                            if let content = try? String(contentsOf: url, encoding: .utf8) {
                                scriptCode = content
                                engine.appendLog("已加载: \(url.lastPathComponent)", color: .blue)
                            }
                        }
                    }
                )
            }
            .sheet(isPresented: $showFileList) {
                fileListSheet
            }
            .onAppear {
                if scriptCode.isEmpty {
                    scriptCode = engine.defaultScript()
                }
            }
        }
        .navigationViewStyle(.stack)
        .alert("保存脚本", isPresented: $showingSaveAlert) {
            TextField("文件名（不含 .lua）", text: $saveFileName)
                .autocapitalization(.none)
            Button("保存") {
                var name = saveFileName.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty { name = "untitled" }
                if !name.hasSuffix(".lua") { name += ".lua" }
                let path = (LuaScriptManager.scriptsDirectory as NSString).appendingPathComponent(name)
                engine.saveScript(scriptCode, toPath: path)
                engine.currentFilePath = path
                saveFileName = ""
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 文件工具栏

    private var fileToolbar: some View {
        HStack(spacing: 8) {
            // 打开文件
            toolbarButton("打开", icon: "doc.badge.plus", disabled: engine.isRunning) {
                showingFilePicker = true
            }

            // 保存
            toolbarButton("保存", icon: "square.and.arrow.down",
                          disabled: engine.isRunning || scriptCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                if let path = engine.currentFilePath {
                    engine.saveScript(scriptCode, toPath: path)
                } else {
                    saveFileName = ""
                    showingSaveAlert = true
                }
            }

            // 另存为
            toolbarButton(icon: "square.and.arrow.down.on.square",
                          disabled: engine.isRunning || scriptCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                saveFileName = ""
                showingSaveAlert = true
            }

            Spacer()

            // 运行
            toolbarButton("运行", icon: "play.fill", prominent: true,
                          disabled: engine.isRunning || scriptCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                if !scriptCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    engine.runScript(scriptCode)
                }
            }

            // 暂停
            toolbarButton(icon: "pause.fill",
                          disabled: !engine.isRunning || engine.isPaused) {
                engine.pause()
            }

            // 继续
            toolbarButton(icon: "play.fill",
                          disabled: !engine.isPaused) {
                engine.resume()
            }

            // 停止
            toolbarButton(icon: "stop.fill", destructive: true,
                          disabled: !engine.isRunning) {
                engine.stop()
            }
        }
    }

    // MARK: - iOS 14 兼容按钮样式
    private func toolbarButton(_ text: String? = nil, icon: String,
                                prominent: Bool = false, destructive: Bool = false,
                                disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if let text = text {
                Label(text, systemImage: icon)
                    .font(prominent ? .caption.weight(.bold) : .caption)
            } else {
                Image(systemName: icon)
                    .font(.caption)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            prominent ? Color.green :
            destructive ? Color.red.opacity(0.15) :
            Color(.systemGray4)
        )
        .foregroundColor(
            prominent ? .white :
            destructive ? .red :
            .primary
        )
        .cornerRadius(6)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1.0)
    }

    // MARK: - 当前文件提示

    private var currentFileBar: some View {
        HStack {
            if let path = engine.currentFilePath {
                Image(systemName: "doc.text")
                    .font(.caption2)
                    .foregroundColor(.blue)
                Text((path as NSString).lastPathComponent)
                    .font(.caption2)
                    .foregroundColor(.blue)
                    .lineLimit(1)
            }
            Spacer()
            // 状态指示
            HStack(spacing: 4) {
                Circle()
                    .fill(engine.statusColor)
                    .frame(width: 6, height: 6)
                Text(engine.statusText)
                    .font(.caption2)
                    .foregroundColor(engine.statusColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - 代码编辑区

    private var editorSection: some View {
        TextEditor(text: $scriptCode)
            .font(.system(size: 13, design: .monospaced))
            .disableAutocorrection(true)
            .autocapitalization(.none)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGray6))
            .cornerRadius(10)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .frame(maxHeight: 220)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(.systemGray4), lineWidth: 0.5)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            )
            .disabled(engine.isRunning)
    }

    // MARK: - 模板区

    private var templateSection: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(ScriptTemplate.templates) { tmpl in
                    Button {
                        scriptCode = tmpl.code
                        templateSelected = tmpl.id
                        engine.currentFilePath = nil
                    } label: {
                        Text(tmpl.title)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(templateSelected == tmpl.id ? Color.accentColor : Color(.systemGray5))
                            .foregroundColor(templateSelected == tmpl.id ? .white : .primary)
                            .cornerRadius(14)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(height: 36)
    }

    // MARK: - 文件列表 Sheet

    private var fileListSheet: some View {
        NavigationView {
            List {
                if engine.savedFiles.isEmpty {
                    Section {
                        HStack {
                            Spacer()
                            VStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.largeTitle)
                                    .foregroundColor(.secondary)
                                Text("暂无脚本文件")
                                    .foregroundColor(.secondary)
                                Text("将 .lua 文件放入：\n脚本目录")
                                    .font(.caption2)
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .multilineTextAlignment(.center)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 30)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section(header: Text("已保存的脚本 (\(engine.savedFiles.count))")) {
                        ForEach(engine.savedFiles) { file in
                            Button {
                                if let content = engine.loadFile(file.path) {
                                    scriptCode = content
                                    engine.currentFilePath = file.path
                                    templateSelected = nil
                                    engine.appendLog("已加载: \(file.name)", color: .blue)
                                }
                                showFileList = false
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundColor(.blue)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(file.name)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        Text(sizeString(file.size) + " · " + timeString(file.modifiedAt))
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                engine.deleteFile(engine.savedFiles[idx].path)
                            }
                        }
                    }
                }
            }
            .navigationTitle("脚本文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        engine.refreshFileList()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { showFileList = false }
                }
            }
        }
    }

    // MARK: - 输出日志区

    private var outputSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("输出")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .bold()
                Spacer()
                Button("清除") {
                    engine.clearLog()
                }
                .font(.caption2)
                .disabled(engine.logLines.isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if engine.logLines.isEmpty {
                            HStack {
                                Text("运行脚本后将在此显示输出...")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .padding(.vertical, 20)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            ForEach(engine.logLines) { line in
                                Text(line.text)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(line.color)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                            }
                        }
                    }
                    .padding(6)
                }
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .onChange(of: engine.logLines.count) { _ in
                    if let last = engine.logLines.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 辅助格式化

    private func sizeString(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
        return String(format: "%.1f MB", Double(bytes) / 1048576.0)
    }

    private func timeString(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - 文档选择器 UIKit 桥接

struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void
    var onCancel: (() -> Void)?

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiVC: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: (() -> Void)?

        init(onPick: @escaping (URL) -> Void, onCancel: (() -> Void)?) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel?()
        }
    }
}

// MARK: - Preview

struct ScriptControlView_Previews: PreviewProvider {
    static var previews: some View {
        ScriptControlView()
    }
}
