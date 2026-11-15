import Foundation
import SwiftUI

// MARK: - 磁盘分析页

/// 只读页面：可以下钻、返回上级、在 Finder 中显示，没有任何删除入口。
struct AnalyzeView: View {
    @ObservedObject var model: AnalyzeViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .navigationTitle("磁盘分析")
        .onAppear {
            // 首次进入自动分析主目录；已有结果时不重复扫描。
            // 用独立 Task 而不是 .task，切换侧边栏不会把正在跑的分析取消掉。
            guard !model.hasResult, model.phase == .idle, model.errorMessage == nil else { return }
            Task { await model.analyzeCurrent() }
        }
    }

    // MARK: 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("磁盘占用")
                        .font(.headline)
                    Text(model.displayPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(model.currentPath)
                }
                Spacer()
                if model.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Button("取消") { model.cancel() }
                } else {
                    Button {
                        model.chooseDirectory()
                    } label: {
                        Label("选择目录", systemImage: "folder")
                    }
                    Button {
                        Task { await model.analyzeCurrent() }
                    } label: {
                        Label("重新分析", systemImage: "arrow.clockwise")
                    }
                }
            }

            HStack(spacing: 16) {
                stat("总计", ByteFormat.string(model.totalSize))
                if let files = model.totalFiles {
                    stat("文件数", String(files))
                }
                if let status = model.scanStatusText {
                    stat("状态", status)
                }
                if model.overview {
                    Text("概览")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.canGoUp {
                    Button {
                        Task { await model.goUp() }
                    } label: {
                        Label("返回上级", systemImage: "arrow.up.left")
                    }
                    .help("回到上一个分析过的目录")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
    }

    // MARK: 主体

    @ViewBuilder
    private var content: some View {
        if model.isAnalyzing && !model.hasResult {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在统计目录大小，文件多时会慢一些…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasResult {
            emptyState
        } else {
            resultList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有分析结果", systemImage: "chart.pie")
        } description: {
            if let message = model.errorMessage {
                Text(message)
            } else {
                Text("选择目录后会调用引擎统计大小；这一页只读，不会改动任何文件。")
            }
        } actions: {
            Button("分析当前目录") {
                Task { await model.analyzeCurrent() }
            }
            .disabled(model.isAnalyzing)
            Button("选择其他目录") {
                model.chooseDirectory()
            }
            .disabled(model.isAnalyzing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        List {
            if let message = model.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section("目录与文件（按大小排序）") {
                if model.sortedEntries.isEmpty {
                    Text("这个目录下没有可展示的条目。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.sortedEntries) { entry in
                    AnalyzeEntryRow(entry: entry, maxSize: model.maxEntrySize) {
                        model.revealInFinder(entry.path)
                    } onOpen: {
                        Task { await model.drillDown(into: entry) }
                    }
                }
            }

            if !model.sortedLargeFiles.isEmpty {
                Section("大文件") {
                    ForEach(model.sortedLargeFiles) { file in
                        AnalyzeLargeFileRow(file: file, maxSize: model.maxLargeFileSize) {
                            model.revealInFinder(file.path)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            Text("只读分析，本页不提供删除；需要清理请到“清理”页。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let scannedAt = model.lastScannedAt {
                Text("分析于 \(scannedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button {
                model.revealInFinder()
            } label: {
                Label("在 Finder 中显示", systemImage: "folder")
            }
            .disabled(model.isAnalyzing)
            .help("在 Finder 中显示当前目录")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
