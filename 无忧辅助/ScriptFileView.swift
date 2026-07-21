//
//  ScriptFileView.swift
//  无忧辅助
//
//  脚本文件浏览器：显示 lua 文件列表，选中后运行
//

import SwiftUI

// MARK: - 脚本文件视图

struct ScriptFileView: View {
    @StateObject private var log = Log.shared
    @State private var luaFiles: [String] = []
    @State private var selectedFile: String? = nil
    @State private var isRunning = false
    @State private var scriptPath: String = ScriptDirectoryHelper.scriptPath

    private let engine = ScriptEngine.shared()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // ── 路径栏 ──
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 14))
                    Text(scriptPath)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(action: refreshFileList) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemGray6))

                // ── 文件列表 ──
                if luaFiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary.opacity(0.4))
                        Text("没有找到 .lua 文件")
                            .foregroundColor(.secondary)
                        Text("请将脚本放入上方路径")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(luaFiles, id: \.self) { file in
                            Button(action: {
                                selectedFile = file
                            }) {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedFile == file
                                          ? "chevron.right.circle.fill"
                                          : "doc.fill")
                                        .foregroundColor(selectedFile == file ? .orange : .gray)
                                        .font(.system(size: 16))

                                    Text(file)
                                        .font(.system(size: 15, design: .monospaced))
                                        .foregroundColor(selectedFile == file ? .orange : .primary)

                                    Spacer()

                                    if selectedFile == file {
                                        Text("已选中")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(Color.orange.opacity(0.12))
                                            .cornerRadius(4)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                Divider()

                // ── 运行 / 停止按钮 ──
                HStack(spacing: 12) {
                    Button(action: runSelectedScript) {
                        HStack(spacing: 6) {
                            if isRunning {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .accentColor(.white)
                            } else {
                                Image(systemName: "play.fill")
                            }
                            Text(isRunning ? "运行中..." : "运行脚本")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(canRun ? Color.orange : Color.gray)
                        .cornerRadius(10)
                    }
                    .disabled(!canRun)

                    Button(action: stopScript) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                            Text("停止")
                        }
                        .font(.subheadline)
                        .foregroundColor(.red)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(10)
                    }
                    .disabled(!isRunning)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                // ── 日志区域 ──
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("运行日志")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("清空") {
                            log.clear()
                        }
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .opacity(log.entries.isEmpty ? 0.3 : 1)
                    }
                    .disabled(log.entries.isEmpty)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)

                    if log.entries.isEmpty {
                        Text("暂无日志")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.5))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 20)
                    } else {
                        LogTextView(text: log.fullText)
                            .frame(maxHeight: 180)
                            .background(Color(.systemGray6))
                            .cornerRadius(6)
                            .padding(.horizontal, 10)
                    }
                }
                .padding(.bottom, 6)
            }
            .navigationTitle("脚本控制")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                setupEngineCallbacks()
                refreshFileList()
            }
        }
    }

    // MARK: - 引擎回调

    private var canRun: Bool { selectedFile != nil && !isRunning }

    private func setupEngineCallbacks() {
        engine.logHandler = { msg in
            Log.shared.add(msg)
        }
        engine.stateChangeHandler = { newState in
            let running = newState == ScriptState.running || newState == ScriptState.paused
            DispatchQueue.main.async { [self] in  // 显式捕获 self
                isRunning = running
                switch newState {
                case .running:
                    break
                case .idle:
                    Log.shared.add("✅ 脚本执行完毕")
                case .paused:
                    Log.shared.add("⏸ 脚本已暂停")
                case .stopping:
                    Log.shared.add("⏹ 脚本正在停止...")
                case .error:
                    Log.shared.add("❌ 脚本执行出错")
                @unknown default:
                    Log.shared.add("⚠️ 未知状态")
                }
            }
        }
    }

    // MARK: - Actions

    private func refreshFileList() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: scriptPath) {
            luaFiles = []
            Log.shared.add("⚠️ 路径不存在: \(scriptPath)")
            return
        }
        do {
            let allFiles = try fm.contentsOfDirectory(atPath: scriptPath)
            luaFiles = allFiles.filter { $0.hasSuffix(".lua") }.sorted()
            Log.shared.add("📁 找到 \(luaFiles.count) 个 .lua 文件")
        } catch {
            luaFiles = []
            Log.shared.add("❌ 读取目录失败: \(error.localizedDescription)")
        }
    }

    private func runSelectedScript() {
        guard let file = selectedFile, !isRunning else { return }
        let fullPath = "\(scriptPath)/\(file)"

        guard let code = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
            Log.shared.add("❌ 无法读取文件: \(fullPath)")
            return
        }

        isRunning = true
        Log.shared.add("▶️ 开始运行: \(file)")
        engine.runScript(code)
    }

    private func stopScript() {
        engine.stop()
        Log.shared.add("⏹ 手动停止脚本")
    }
}

struct ScriptFileView_Previews: PreviewProvider {
    static var previews: some View {
        ScriptFileView()
    }
}
