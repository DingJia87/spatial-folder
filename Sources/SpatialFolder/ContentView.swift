import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: FolderCanvasModel
    @EnvironmentObject private var visibilityController: AppVisibilityController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var resetConfirmationPresented = false
    @State private var referenceCanvasConfirmationPresented = false
    @State private var historyPresented = false
    @State private var layoutHistoryPresented = false
    @State private var inboxPresented = false
    @State private var toolbarHeight: CGFloat = 52
    @State private var draggedSpacePath: String?
    @State private var spaceDragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if model.folderURL == nil {
                    ContentUnavailableView("选择一个文件夹", systemImage: "square.grid.2x2",
                                           description: Text("把它变成一张可长期记忆的空间画布。"))
                } else if model.layoutIsBlocked {
                    ContentUnavailableView {
                        Label("布局需要恢复", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("原布局文件已保留。请恢复备份、导入布局，或确认重置当前空间。")
                    } actions: {
                        HStack {
                            Button("恢复最近备份", action: model.restoreLatestBackup)
                                .disabled(model.backupCount == 0)
                            Button("导入布局…", action: model.importLayout)
                            Button("重置布局", role: .destructive) { resetConfirmationPresented = true }
                        }
                    }
                } else if model.folderUnavailable {
                    ContentUnavailableView {
                        Label("原文件夹暂不可用", systemImage: "folder.badge.questionmark")
                    } description: {
                        Text("它可能被移动、改名，或者所在磁盘暂时断开。布局数据仍然保留。")
                    } actions: {
                        Button("重新关联文件夹…", action: model.chooseReplacementFolder)
                    }
                } else {
                    FolderCanvasView()
                }
            }
        }
        .alert("指针空间", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert(
            model.pendingConflict?.title ?? "发现同名项目",
            isPresented: Binding(
                get: { model.pendingConflict != nil },
                set: { if !$0, model.pendingConflict != nil { model.resolvePendingConflict(.cancel) } }
            )
        ) {
            Button("保留两者") { model.resolvePendingConflict(.keepBoth) }
            Button("替换", role: .destructive) { model.resolvePendingConflict(.replace) }
            Button("取消", role: .cancel) { model.resolvePendingConflict(.cancel) }
        } message: {
            Text(model.pendingConflict?.message ?? "")
        }
        .sheet(item: $model.infoItem) { item in
            FileInfoView(item: item)
        }
        .sheet(isPresented: $historyPresented) {
            OperationHistoryView()
                .environmentObject(model)
        }
        .sheet(isPresented: $layoutHistoryPresented) {
            LayoutHistoryView()
                .environmentObject(model)
        }
        .sheet(isPresented: $inboxPresented) {
            InboxPanelView()
                .environmentObject(model)
        }
        .confirmationDialog(
            "顶部空间已满",
            isPresented: Binding(
                get: { model.pendingSpaceReplacementURL != nil },
                set: { if !$0 { model.cancelSpaceReplacement() } }
            ),
            titleVisibility: .visible
        ) {
            if let replacement = model.pendingSpaceReplacementURL {
                ForEach(Array(model.pinnedFolders.enumerated()), id: \.element.path) { index, folder in
                    Button("替换位置 \(index + 1)：\(folder.lastPathComponent)") {
                        model.replaceSpaceAndOpen(with: replacement, replacing: folder)
                    }
                }
            }
            Button("取消", role: .cancel) { model.cancelSpaceReplacement() }
        } message: {
            if let replacement = model.pendingSpaceReplacementURL {
                Text("顶部最多保留 \(model.maximumPinnedFolders) 个空间。请选择“\(replacement.lastPathComponent)”要替换的位置；其他空间的位置不会改变。")
            }
        }
        .sheet(isPresented: $model.isRecoveryWizardPresented) {
            RecoveryWizardView()
                .environmentObject(model)
        }
        .alert("重置当前布局？", isPresented: $resetConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive, action: model.resetLayout)
        } message: {
            Text("文件不会被移动或删除，但当前图标位置、大小和待放置状态会重新生成。重置前会保留一份布局备份。")
        }
        .alert("将当前显示器设为基准画布？", isPresented: $referenceCanvasConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("设为基准") { model.setCurrentDisplayAsReferenceCanvas() }
        } message: {
            Text("仅当旧版布局已经被小屏幕压缩时使用。文件不会移动，图标坐标会按当前显示器重新映射；操作可撤销并会自动备份。")
        }
        .background {
            ZStack {
                WindowAspectRatioController(
                    canvasSize: model.desktopCanvasSize,
                    fixedChromeHeight: toolbarHeight + 1
                )
                MainWindowRegistrationView(controller: visibilityController)
            }
        }
        .onAppear {
            model.setTagReconciliationActive(true)
            visibilityController.configureOpenWindow {
                openWindow(id: "main")
            }
        }
        .onDisappear {
            model.setTagReconciliationActive(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            model.setTagReconciliationActive(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            model.setTagReconciliationActive(visibilityController.shouldRunVisibleWindowWork)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { notification in
            if visibilityController.managesWindow(notification.object) {
                model.setTagReconciliationActive(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { notification in
            if visibilityController.managesWindow(notification.object) {
                model.setTagReconciliationActive(true)
            }
        }
        .onPreferenceChange(ToolbarHeightPreferenceKey.self) { height in
            if height > 0 { toolbarHeight = height }
        }
        .overlay(alignment: .bottom) {
            if let progress = model.fileOperationProgress {
                fileOperationProgressView(progress)
                    .padding(.bottom, 14)
            } else if let message = model.statusMessage {
                Text(message)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.bottom, 14)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            spaceTabs
            if model.folderURL != nil {
                Spacer(minLength: 12)
                TextField("筛选当前空间", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 210)
                    .help("按文件名或 Finder 标签搜索当前空间")
                tagFilterMenu
                if model.operationHistoryIsBlocked {
                    Button { historyPresented = true } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .help("操作记录需要修复")
                }
                if !model.recoveryCases.isEmpty {
                    Button { model.isRecoveryWizardPresented = true } label: {
                        Label("\(model.recoveryCases.count)", systemImage: "cross.case.fill")
                    }
                    .help("核对上次未确认完成的文件操作")
                }
                if !model.inboxItems.isEmpty {
                    Button { inboxPresented = true } label: {
                        Label("\(model.inboxItems.count)", systemImage: "tray.full")
                    }
                    .help("搜索、多选并放回主画布")
                }
                Button(action: model.collectDesktopItems) {
                    Label("收纳桌面", systemImage: "tray.and.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .disabled(!model.canCollectDesktopItems)
                .help("先显示桌面项目数量和目标空间；确认后才移动桌面第一级文件和文件夹（⇧⌘D）")
                .popover(
                    isPresented: Binding(
                        get: { model.desktopCollectionConfirmation != nil },
                        set: { if !$0 { model.cancelDesktopCollection() } }
                    ),
                    arrowEdge: .top
                ) {
                    if let confirmation = model.desktopCollectionConfirmation {
                        DesktopCollectionConfirmationView(
                            confirmation: confirmation,
                            cancel: model.cancelDesktopCollection,
                            confirm: model.confirmDesktopCollection
                        )
                    }
                }
                Button(action: model.undoLastAction) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                .help(model.undoHelpText)
                .accessibilityLabel("撤销上一步操作")
                Button(action: model.redoLastAction) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)
                .help(model.redoHelpText)
                .accessibilityLabel("重做上一步操作")
                Button(action: model.refreshItems) {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("重新扫描当前空间。仅在 Finder 中新增、删除、改名或修改标签后，画布没有及时更新时使用")
                .accessibilityLabel("刷新当前空间")
                canvasMenu
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ToolbarHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        }
    }

    private var spaceTabs: some View {
        ViewThatFits(in: .horizontal) {
            spaceTabStrip(limit: 5)
            spaceTabStrip(limit: 4)
            spaceTabStrip(limit: 3)
            spaceTabStrip(limit: 2)
            spaceTabStrip(limit: 1)
        }
    }

    private func spaceTabStrip(limit: Int) -> some View {
        let visibleFolders = Array(model.toolbarSpaceFolders.prefix(limit))
        return HStack(spacing: 5) {
            ForEach(visibleFolders, id: \.path) { folder in
                spaceTab(for: folder)
            }
            spaceOverflowMenu(excluding: visibleFolders)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func spaceTab(for folder: URL) -> some View {
        let active = folder.standardizedFileURL == model.folderURL?.standardizedFileURL
        return HStack(spacing: 2) {
            Button {
                if !active { model.open(folder: folder) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: active ? "folder.fill" : "folder")
                    Text(folder.lastPathComponent)
                        .font(.callout.weight(active ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: 82)
                .padding(.leading, 8)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(model.isFileOperationInProgress)
            .help(active ? "当前空间：\(folder.path)" : "切换到“\(folder.lastPathComponent)”：\(folder.path)")

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 3)
                .padding(.trailing, 7)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .help("拖动调整“\(folder.lastPathComponent)”的位置")
                .gesture(
                    DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            draggedSpacePath = folder.path
                            spaceDragOffset = value.translation.width
                        }
                        .onEnded { value in
                            model.movePinnedFolder(folder, byHorizontalDistance: value.translation.width)
                            draggedSpacePath = nil
                            spaceDragOffset = 0
                        }
                )
                .accessibilityLabel("拖动调整“\(folder.lastPathComponent)”的位置")
                .accessibilityAction {
                    model.movePinnedFolder(folder, byHorizontalDistance: 90)
                }
                .allowsHitTesting(!model.isFileOperationInProgress)
        }
        .offset(x: draggedSpacePath == folder.path ? spaceDragOffset : 0)
        .zIndex(draggedSpacePath == folder.path ? 1 : 0)
        .background(
            active ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(
                    draggedSpacePath == folder.path
                        ? Color.accentColor
                        : (active ? Color.accentColor.opacity(0.7) : Color.clear),
                    lineWidth: draggedSpacePath == folder.path ? 2 : 1
                )
            }
        .contextMenu {
            if model.isPinnedFolder(folder), !active {
                Button("从顶部移除") { model.unpinFolder(folder) }
            }
            Button("在 Finder 中打开") { NSWorkspace.shared.open(folder) }
        }
    }

    private func spaceOverflowMenu(excluding visibleFolders: [URL]) -> some View {
        let overflowFolders = model.overflowSpaceFolders(excluding: visibleFolders)
        return Menu {
            Button("选择文件夹…", action: model.chooseFolder)
                .disabled(model.isFileOperationInProgress)
            if !overflowFolders.isEmpty {
                Divider()
                Section("更多空间") {
                    ForEach(overflowFolders, id: \.path) { recent in
                        Button {
                            model.open(folder: recent)
                        } label: {
                            if recent.standardizedFileURL == model.folderURL?.standardizedFileURL {
                                Label(recent.lastPathComponent, systemImage: "checkmark")
                            } else {
                                Text(recent.lastPathComponent)
                            }
                        }
                        .disabled(model.isFileOperationInProgress)
                        .help(recent.path)
                    }
                }
            }
        } label: {
            Image(systemName: overflowFolders.isEmpty ? "plus" : "ellipsis")
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择或打开更多空间；顶部满 \(model.maximumPinnedFolders) 个后会先选择替换位置")
    }

    private var canvasMenu: some View {
        Menu {
            Button(action: model.toggleLocked) {
                Label(
                    model.isLocked ? "解锁画布" : "锁定画布",
                    systemImage: model.isLocked ? "lock.open" : "lock"
                )
            }
            Divider()
            Button {
                openSettings()
            } label: {
                Label("全局快捷键设置…", systemImage: "keyboard")
            }
            Divider()
            Menu {
                Button("选择图片…", action: model.chooseWallpaper)
                Button("使用系统桌面壁纸") { model.setWallpaper(nil) }
            } label: {
                Label("壁纸", systemImage: "photo")
            }
            .disabled(!model.canChangeWallpaper)
            Menu {
                appearanceButton(title: "跟随系统", mode: "system")
                appearanceButton(title: "浅色", mode: "light")
                appearanceButton(title: "深色", mode: "dark")
            } label: {
                Label("外观", systemImage: "circle.lefthalf.filled")
            }
            Divider()
            Button {
                historyPresented = true
            } label: {
                Label(
                    model.operationHistoryIsBlocked ? "操作记录需要修复" : "最近操作…",
                    systemImage: model.operationHistoryIsBlocked
                        ? "exclamationmark.triangle.fill"
                        : "clock.arrow.circlepath"
                )
            }
            .disabled(model.isLoadingOperationHistory)
            Menu {
                Button("撤销上一步操作", action: model.undoLastAction)
                    .disabled(!model.canUndo)
                Button("重做上一步操作", action: model.redoLastAction)
                    .disabled(!model.canRedo)
                Divider()
                Button("找回越界项目", action: model.recoverOutOfBoundsItems)
                    .disabled(model.isLocked)
                Button("将当前显示器设为基准画布…") {
                    referenceCanvasConfirmationPresented = true
                }
                .disabled(model.isLocked)
                Divider()
                Button {
                    layoutHistoryPresented = true
                } label: {
                    Label("布局历史（\(model.backupCount)）…", systemImage: "clock.arrow.2.circlepath")
                }
                Divider()
                Button("重置当前布局", role: .destructive) {
                    resetConfirmationPresented = true
                }
            } label: {
                Label("布局维护", systemImage: "square.grid.3x3")
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("打开壁纸、外观、全局快捷键、最近操作和布局维护等低频设置")
    }

    @ViewBuilder
    private func appearanceButton(title: String, mode: String) -> some View {
        Button {
            model.setAppearanceMode(mode)
        } label: {
            if model.appearanceMode == mode {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var tagFilterMenu: some View {
        Menu {
            ForEach(FinderTagColor.displayOrder) { color in
                Button {
                    model.toggleTagFilter(color)
                } label: {
                    Label {
                        Text(color.title)
                    } icon: {
                        Image(nsImage: color.menuIcon(
                            selected: model.selectedTagColors.contains(color)
                        ))
                        .renderingMode(.original)
                    }
                }
            }
            Divider()
            Button {
                model.toggleUntaggedFilter()
            } label: {
                if model.includesUntaggedInFilter {
                    Label("无标签", systemImage: "checkmark")
                } else {
                    Text("无标签")
                }
            }
            Divider()
            Button("清除筛选", action: model.clearFilters)
                .disabled(!model.hasActiveFilters)
        } label: {
            if model.activeTagFilterCount == 0 {
                Label("标签筛选", systemImage: "tag")
                    .labelStyle(.iconOnly)
            } else {
                Label(
                    "\(model.activeTagFilterCount)",
                    systemImage: "tag.fill"
                )
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .help("按 Finder 标签颜色筛选；多种颜色之间为任一匹配")
    }

    /// 长文件操作的非阻塞进度条；取消会等待当前系统调用结束后回滚。
    private func fileOperationProgressView(_ progress: FileOperationProgressState) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(progress.title).font(.callout.weight(.semibold))
                Text(progress.detail).font(.caption).foregroundStyle(.secondary)
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction)
                        .frame(width: 280)
                } else {
                    ProgressView().frame(width: 280)
                }
            }
            if progress.allowsCancellation {
                Button(progress.isCancelling ? "正在取消…" : "取消") {
                    model.cancelCurrentFileOperation()
                }
                .disabled(progress.isCancelling)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
    }
}

private struct ToolbarHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 52
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct OperationHistoryView: View {
    @EnvironmentObject private var model: FolderCanvasModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近操作").font(.title2.weight(.semibold))
                    Text("文件操作记录会跨重启保留；布局撤销快照仅在本次运行期间有效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            if model.operationHistoryIsBlocked {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("操作记录无法读取。原记录已保留，为避免无法恢复的文件变更，真实文件修改已暂停。")
                        .font(.callout)
                    Spacer()
                    VStack(alignment: .trailing) {
                        Button("显示记录位置", action: model.revealOperationHistory)
                        Button("存档损坏记录并继续…", action: model.archiveDamagedOperationHistoryAndContinue)
                    }
                }
                .padding()
                .background(Color.yellow.opacity(0.12))
            }

            List(Array(model.operationRecords.reversed())) { record in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: record.category == .layout ? "square.grid.3x3" : "doc.badge.gearshape")
                        .frame(width: 20)
                        .foregroundStyle(record.state == .failed || record.state == .unavailable ? .orange : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(record.summary).fontWeight(.medium)
                            Text(record.state.title)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                        Text("\(record.kind.title) · \(record.transitionDate.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let detail = record.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if model.operationRecords.isEmpty {
                    ContentUnavailableView("还没有操作记录", systemImage: "clock")
                }
            }

            Divider()
            HStack {
                Button("撤销", action: model.undoLastAction).disabled(!model.canUndo)
                Button("重做", action: model.redoLastAction).disabled(!model.canRedo)
                if !model.recoveryCases.isEmpty {
                    Button("处理异常操作（\(model.recoveryCases.count)）") {
                        dismiss()
                        model.isRecoveryWizardPresented = true
                    }
                }
                Spacer()
                Button("导出诊断信息…", action: model.exportDiagnostics)
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

private struct LayoutHistoryView: View {
    @EnvironmentObject private var model: FolderCanvasModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var restoreAppearance = false
    @State private var restoreConfirmationPresented = false
    @State private var deleteConfirmationPresented = false
    @State private var snapshotPromptPresented = false
    @State private var snapshotNote = ""

    private var selectedSnapshot: LayoutBackupSnapshot? {
        model.layoutBackups.first { $0.id == selectedID } ?? model.layoutBackups.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("布局历史").font(.title2.weight(.semibold))
                    Text("预览和恢复图标位置；真实文件始终保持不变。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("保存当前快照…") {
                    snapshotNote = suggestedSnapshotName
                    snapshotPromptPresented = true
                }
                .disabled(model.sessionIsReadOnly || model.layoutIsBlocked)
                Menu("更多") {
                    Button("导出当前布局文件…", action: model.exportLayout)
                    Button("从布局文件导入…", action: model.importLayout)
                        .disabled(model.sessionIsReadOnly)
                    Divider()
                    Button("在访达中显示备份", action: model.revealBackups)
                }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            HStack(spacing: 0) {
                backupList
                    .frame(width: 270)
                Divider()
                backupDetail
            }
        }
        .frame(minWidth: 940, minHeight: 620)
        .onAppear {
            model.loadLayoutBackups()
            selectedID = model.layoutBackups.first?.id
        }
        .onChange(of: model.layoutBackups) { _, backups in
            if !backups.contains(where: { $0.id == selectedID }) {
                selectedID = backups.first?.id
            }
        }
        .alert("保存当前布局快照", isPresented: $snapshotPromptPresented) {
            TextField("快照名称", text: $snapshotNote)
            Button("取消", role: .cancel) { snapshotNote = "" }
            Button("保存") {
                model.saveLayoutSnapshot(note: snapshotNote)
                snapshotNote = ""
            }
        } message: {
            Text("已生成推荐名称，你也可以改成“整理完成”或“汇报前”等说明。")
        }
        .alert("恢复这个布局？", isPresented: $restoreConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                if let selectedSnapshot {
                    model.restoreLayoutBackup(selectedSnapshot, restoreAppearance: restoreAppearance)
                }
            }
        } message: {
            if let selectedSnapshot {
                let difference = model.layoutDifference(for: selectedSnapshot)
                Text("将调整 \(difference.changedCount) 个现有项目；\(difference.newItemCount) 个新增项目保持原位；\(difference.missingItemCount) 个已不存在的项目会被忽略。真实文件不会被移动、创建或删除。")
            }
        }
        .alert("删除这份布局备份？", isPresented: $deleteConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("删除备份", role: .destructive) {
                if let selectedSnapshot {
                    model.deleteLayoutBackup(selectedSnapshot)
                }
            }
        } message: {
            if let selectedSnapshot {
                Text("将删除“\(selectedSnapshot.reason)”这份布局备份，且不能在 App 内撤销。当前布局和真实文件不会受到影响。")
            }
        }
    }

    private var backupList: some View {
        List(selection: $selectedID) {
            ForEach(model.layoutBackups) { snapshot in
                VStack(alignment: .leading, spacing: 5) {
                    Text(snapshot.reason)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("\(snapshot.itemCount) 个项目")
                        if let version = snapshot.appVersion {
                            Text("v\(version)")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 4)
                .tag(snapshot.id)
            }
        }
        .overlay {
            if model.layoutBackups.isEmpty {
                ContentUnavailableView(
                    "还没有布局备份",
                    systemImage: "clock.arrow.2.circlepath",
                    description: Text("调整布局或手动保存快照后会显示在这里。")
                )
            }
        }
    }

    @ViewBuilder
    private var backupDetail: some View {
        if let snapshot = selectedSnapshot {
            let difference = model.layoutDifference(for: snapshot)
            let missingNames = model.missingItemNames(for: snapshot)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(snapshot.reason).font(.title3.weight(.semibold))
                        Text(snapshot.createdAt.formatted(date: .long, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        differenceBadge("\(difference.changedCount) 将调整", color: .blue)
                        differenceBadge("\(difference.unchangedCount) 不变", color: .secondary)
                        differenceBadge("\(difference.newItemCount) 新增保留", color: .green)
                        differenceBadge("\(difference.missingItemCount) 已不存在", color: .orange)
                    }

                    HStack(alignment: .top, spacing: 16) {
                        previewCard(title: "当前布局", canvas: model.currentCanvasForPreview)
                        previewCard(title: "备份布局", canvas: model.canvasForBackupPreview(snapshot))
                    }

                    if !missingNames.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(missingNames, id: \.self) { name in
                                    Label(name, systemImage: "questionmark.square.dashed")
                                        .font(.caption)
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Label(
                                "\(missingNames.count) 个备份项目当前已不存在，恢复时将忽略",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                    }

                    Toggle("同时恢复当时的壁纸和锁定状态", isOn: $restoreAppearance)
                    Text("默认只恢复位置、大小、待放置状态和基准画布；新增文件保持现在的位置。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("删除所选备份…", role: .destructive) {
                            deleteConfirmationPresented = true
                        }
                        .disabled(model.sessionIsReadOnly)
                        Spacer()
                        Button("恢复这个布局…") { restoreConfirmationPresented = true }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.sessionIsReadOnly)
                    }
                }
                .padding(20)
            }
        } else {
            ContentUnavailableView("选择一份布局备份", systemImage: "square.grid.3x3")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func differenceBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private var suggestedSnapshotName: String {
        "当前布局 · \(Date().formatted(date: .abbreviated, time: .shortened))"
    }

    private func previewCard(title: String, canvas: SavedCanvas) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                if !canvas.inboxIDs.isEmpty {
                    Text("待放置 \(canvas.inboxIDs.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            LayoutCanvasPreview(canvas: canvas, currentItemIDs: Set(model.items.map(\.id)))
                .frame(minHeight: 240)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity)
    }
}

private struct LayoutCanvasPreview: View {
    let canvas: SavedCanvas
    let currentItemIDs: Set<String>

    var body: some View {
        GeometryReader { geometry in
            let logicalSize = canvas.canvasSize?.size ?? CGSize(width: 1440, height: 900)
            let visibleIDs = canvas.positions.keys.filter { !canvas.inboxIDs.contains($0) }
            let showsLabels = visibleIDs.count <= 28
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(.separator, lineWidth: 1)
                    }
                ForEach(canvas.positions.keys.sorted(), id: \.self) { id in
                    if let point = canvas.positions[id], !canvas.inboxIDs.contains(id) {
                        previewItem(
                            id: id,
                            point: point,
                            logicalSize: logicalSize,
                            geometrySize: geometry.size,
                            showsLabel: showsLabels
                        )
                    }
                }
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
    }

    private func previewItem(
        id: String,
        point: CanvasPoint,
        logicalSize: CGSize,
        geometrySize: CGSize,
        showsLabel: Bool
    ) -> some View {
        let missing = !currentItemIDs.contains(id)
        let name = URL(fileURLWithPath: id).lastPathComponent
        let x = min(max(28, point.x / max(1, logicalSize.width) * geometrySize.width), geometrySize.width - 28)
        let y = min(max(18, point.y / max(1, logicalSize.height) * geometrySize.height), geometrySize.height - 18)
        return VStack(spacing: 2) {
            Image(systemName: missing ? "questionmark.square.dashed" : "doc.fill")
                .font(.system(size: showsLabel ? 11 : 9))
            if showsLabel {
                Text(name)
                    .font(.system(size: 7))
                    .lineLimit(1)
                    .frame(width: 52)
            }
        }
        .foregroundStyle(missing ? Color.orange : Color.accentColor)
        .help(name)
        .position(x: x, y: y)
    }
}

private struct RecoveryWizardView: View {
    @EnvironmentObject private var model: FolderCanvasModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("异常恢复向导").font(.title2.weight(.semibold))
                    Text("向导只读取磁盘证据并修正操作记录，不会移动、覆盖或删除任何文件。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("在访达中核对", action: model.revealRecoveryFolder)
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()

            List {
                ForEach(model.recoveryCases, id: \.recordID) { recoveryCase in
                    VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(recoveryCase.summary).font(.headline)
                        Text(recoveryCase.currentState.title)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Spacer()
                        Label(
                            recoveryCase.suggestedOutcome.title,
                            systemImage: recoveryCase.suggestedOutcome == .manualReview
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.shield.fill"
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(recoveryCase.suggestedOutcome == .manualReview ? .orange : .green)
                    }
                    Text(recoveryCase.explanation).font(.callout)
                    ForEach(recoveryCase.evidence, id: \.id) { evidence in
                        let isSupported = evidence.supportsApplied || evidence.supportsUndone
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: isSupported ? "checkmark.circle" : "questionmark.circle")
                                .foregroundStyle(isSupported ? Color.secondary : Color.orange)
                            Text(evidence.itemName).lineLimit(1)
                            Spacer()
                            Text(evidence.observation).foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    HStack {
                        if recoveryCase.suggestedOutcome == .applied {
                            Button("确认已完成") { model.resolveRecovery(recoveryCase, as: .applied) }
                                .buttonStyle(.borderedProminent)
                        }
                        if recoveryCase.suggestedOutcome == .undone {
                            Button("确认已回滚") { model.resolveRecovery(recoveryCase, as: .undone) }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("仅存档记录") { model.resolveRecovery(recoveryCase, as: .archived) }
                    }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct FolderCanvasView: View {
    @EnvironmentObject private var model: FolderCanvasModel

    var body: some View {
        GeometryReader { geometry in
            let displayScale = CanvasViewport.displayScale(
                logicalSize: model.desktopCanvasSize,
                viewportWidth: geometry.size.width,
                displaySize: model.currentDisplaySize
            )
            let presentationSize = CanvasViewport.presentationSize(
                logicalSize: model.desktopCanvasSize,
                viewportSize: geometry.size,
                displayScale: displayScale
            )
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    CanvasBackground(
                        url: model.wallpaperURL ?? model.defaultDesktopWallpaperURL,
                        requestedPixelSize: max(
                            presentationSize.width * displayScale,
                            presentationSize.height * displayScale
                        ) * 2
                    )
                        .frame(width: presentationSize.width, height: presentationSize.height)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clearSelection() }
                        .gesture(selectionGesture)
                    ForEach(model.displayedItems, id: \.renderID) { item in
                        CanvasIcon(item: item)
                    }
                    if let selection = model.selectionRect {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.16))
                            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                            .frame(width: selection.width, height: selection.height)
                            .position(x: selection.midX, y: selection.midY)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: presentationSize.width,
                       height: presentationSize.height)
                .scaleEffect(displayScale, anchor: .topLeading)
                .frame(width: presentationSize.width * displayScale,
                       height: presentationSize.height * displayScale,
                       alignment: .topLeading)
                .onDrop(
                    of: [UTType.fileURL],
                    delegate: CanvasFileDropDelegate(displayScale: displayScale) { providers, logicalPoint in
                        receiveDroppedFiles(providers, at: logicalPoint)
                    }
                )
                .contextMenu {
                    Menu("新建") {
                        Button("文件夹", action: model.createFolder)
                        Button("Excel 工作簿", action: model.createExcelWorkbook)
                        Button("Word 文档", action: model.createWordDocument)
                        Button("PowerPoint 演示文稿", action: model.createPowerPointPresentation)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .topTrailing) {
            if model.sessionIsReadOnly || model.isLocked {
                Label(
                    model.sessionIsReadOnly ? "另一进程占用 · 只读" : "布局已锁定",
                    systemImage: model.sessionIsReadOnly ? "exclamationmark.lock.fill" : "lock.fill"
                )
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
            }
        }
        .overlay {
            if model.displayedItems.isEmpty && model.hasActiveFilters {
                ContentUnavailableView {
                    Label("没有匹配项目", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("主画布中没有同时满足搜索和标签条件的项目。")
                } actions: {
                    Button("清除筛选", action: model.clearFilters)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .onAppear(perform: updateCurrentScreenSize)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { notification in
            guard let window = notification.object as? NSWindow, window == NSApp.keyWindow else { return }
            updateCurrentScreenSize()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            updateCurrentScreenSize()
        }
    }

    private func receiveDroppedFiles(_ providers: [NSItemProvider], at logicalPoint: CGPoint) -> Bool {
        guard !providers.isEmpty else { return false }
        // NSItemProvider 会在任意线程、以任意顺序回调。先按原始序号收齐 URL，
        // 再一次性交给模型，保证一次拖入只有一条批量记录和一个冲突决策。
        let collector = DroppedURLCollector(count: providers.count) { urls in
            model.importFiles(urls, dropPoint: logicalPoint)
        }
        for (index, provider) in providers.enumerated() {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                collector.resolve(index: index, url: url)
            }
        }
        return true
    }

    private var selectionGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if model.selectionRect == nil { model.beginSelection(at: value.startLocation) }
                model.updateSelection(to: value.location)
            }
            .onEnded { _ in
                model.finishSelection(addingToSelection: NSEvent.modifierFlags.contains(.command))
            }
    }

    private func updateCurrentScreenSize() {
        guard let size = NSApp.keyWindow?.screen?.frame.size else { return }
        model.updateCanvasSize(size)
    }
}

/// SwiftUI 的简化 onDrop 回调不提供鼠标坐标；DropDelegate 会保留投放位置，并把视图坐标
/// 还原为逻辑画布坐标，保证不同显示器缩放下落点一致。
private struct CanvasFileDropDelegate: DropDelegate {
    let displayScale: CGFloat
    let completion: ([NSItemProvider], CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL])
    }

    func performDrop(info: DropInfo) -> Bool {
        let scale = max(0.01, displayScale)
        let logicalPoint = CGPoint(x: info.location.x / scale, y: info.location.y / scale)
        return completion(info.itemProviders(for: [UTType.fileURL]), logicalPoint)
    }
}

/// 把一次外部拖放产生的异步回调合并成一个有序批次。
/// 这里使用锁只保护很短的内存写入，不做文件 I/O，因此不会阻塞画布主线程。
private final class DroppedURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL?]
    private var resolvedIndexes: Set<Int> = []
    private var remaining: Int
    private let completion: @MainActor ([URL]) -> Void

    init(count: Int, completion: @escaping @MainActor ([URL]) -> Void) {
        urls = Array(repeating: nil, count: count)
        remaining = count
        self.completion = completion
    }

    func resolve(index: Int, url: URL?) {
        lock.lock()
        guard urls.indices.contains(index), !resolvedIndexes.contains(index) else {
            lock.unlock()
            return
        }
        resolvedIndexes.insert(index)
        urls[index] = url
        remaining -= 1
        let completedURLs = remaining == 0 ? urls.compactMap { $0 } : nil
        lock.unlock()

        guard let completedURLs else { return }
        Task { @MainActor [completion] in completion(completedURLs) }
    }
}

private struct DesktopCollectionConfirmationView: View {
    let confirmation: DesktopCollectionConfirmation
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("收纳桌面", systemImage: "tray.and.arrow.down.fill")
                .font(.headline)
            Text("将 \(confirmation.totalCount) 个项目移动到“\(confirmation.destinationName)”")
                .font(.callout)
            Text(confirmation.countDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("文件夹会连同内部内容整体移动；完成后可在“最近操作”中撤销。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("取消", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("收纳", action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

private struct CanvasBackground: View {
    let url: URL?
    let requestedPixelSize: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.08, green: 0.14, blue: 0.23), Color(red: 0.12, green: 0.28, blue: 0.32)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: request) {
            guard let request else {
                image = nil
                return
            }
            let decoded = await WallpaperImageLoader.shared.image(for: request)
            guard !Task.isCancelled else { return }
            image = decoded.map { NSImage(cgImage: $0, size: .zero) }
        }
    }

    private var request: WallpaperImageRequest? {
        url.map { WallpaperImageRequest(url: $0, requestedPixelSize: requestedPixelSize) }
    }
}

private struct CanvasIcon: View {
    @EnvironmentObject private var model: FolderCanvasModel
    let item: FolderItem
    @State private var isDragging = false
    @State private var renamePresented = false
    @State private var renameText = ""

    var body: some View {
        let point = model.position(for: item)
        let scale = model.scale(for: item)
        let isSelected = model.selectedIDs.contains(item.id)
        let contextItems = model.contextItems(for: item)
        let sharedOffset = model.draggingIDs.contains(item.id) ? model.dragTranslation : .zero
        let currentItem = model.currentItem(for: item)
        let folderTagColor = model.folderTagColor(for: currentItem)
        VStack(spacing: 5) {
            ZStack {
                Image(nsImage: model.icon(for: currentItem))
                    .resizable()
                    .interpolation(.high)
                if let folderTagColor {
                    Image(systemName: "folder.fill")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(folderTagColor.color)
                        .padding(3 * scale)
                }
            }
            .frame(width: 56 * scale, height: 56 * scale)
            Text(item.name)
                .font(.system(size: max(10, 12 * scale)))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 94 * scale)
                .foregroundStyle(.white)
                .shadow(radius: 2)
            if !currentItem.tags.isEmpty {
                HStack(spacing: 3) {
                    ForEach(currentItem.tags, id: \.self) { tag in
                        Circle()
                            .fill(tagColor(tag))
                            .frame(width: 7 * scale, height: 7 * scale)
                            .help(model.normalizedTagName(tag))
                    }
                }
            }
        }
        .frame(width: 104 * scale, height: 96 * scale)
        .background(isSelected ? Color.accentColor.opacity(0.32) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.white.opacity(0.9) : .clear, lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            let count = model.pileCount(for: item)
            if count > 1, model.isTopOfPile(item) {
                Text("\(count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                    .accessibilityLabel("叠放 \(count) 个项目")
            }
        }
        .position(x: point.x + sharedOffset.width, y: point.y + sharedOffset.height)
        .onTapGesture(count: 2) { model.open(item) }
        .onTapGesture {
            model.select(item, extendingSelection: NSEvent.modifierFlags.contains(.command))
        }
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { value in
                if !isDragging {
                    model.beginDragging(item)
                    isDragging = true
                }
                model.updateDrag(translation: value.translation)
            }
            .onEnded { _ in
                model.finishDrag()
                isDragging = false
            })
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button(contextItems.count == 1 ? "打开" : "打开 \(contextItems.count) 个项目") {
                model.open(contextItems)
            }
            Button("在访达中显示") { model.reveal(contextItems) }
            Divider()
            Button("复制") { model.copy(contextItems) }
            Button("剪切") { model.cut(contextItems) }
            Button("制作副本") { model.duplicate(contextItems) }
            Button("压缩") { model.compress(contextItems) }
            Button("分享…") { model.share(contextItems) }
            Divider()
            Menu("标签") {
                ForEach(FinderTagColor.displayOrder) { tag in
                    Button {
                        model.toggleTag(tag.encodedValue, for: contextItems)
                    } label: {
                        Label {
                            Text(tag.title)
                        } icon: {
                            Image(nsImage: tag.menuIcon(selected: contextItems.allSatisfy({
                                model.hasTag(tag.encodedValue, in: model.currentItem(for: $0))
                            })))
                            .renderingMode(.original)
                        }
                    }
                }
                Divider()
                Button("清除所有标签") { model.clearTags(for: contextItems) }
                    .disabled(contextItems.allSatisfy { $0.tags.isEmpty })
            }
            Divider()
            Menu("图标与字体大小") {
                scaleButton("小", scale: 0.75, currentScale: scale, items: contextItems)
                scaleButton("标准", scale: 1, currentScale: scale, items: contextItems)
                scaleButton("大", scale: 1.25, currentScale: scale, items: contextItems)
                scaleButton("特大", scale: 1.5, currentScale: scale, items: contextItems)
            }
            .disabled(model.isLocked)
            Button("移到待放置区") { model.moveToInbox(contextItems) }
                .disabled(model.isLocked)
            Divider()
            if contextItems.count == 1 {
                Button("显示简介") { model.showInfo(item) }
                Button("重命名…") { renameText = item.name; renamePresented = true }
            }
            Button("移至废纸篓", role: .destructive) { model.trash(contextItems) }
        }
        .alert("重命名", isPresented: $renamePresented) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("重命名") { model.rename(item, to: renameText) }
        }
    }

    @ViewBuilder
    private func scaleButton(
        _ title: String,
        scale: CGFloat,
        currentScale: CGFloat,
        items: [FolderItem]
    ) -> some View {
        Button {
            model.setScale(scale, for: items)
        } label: {
            if abs(currentScale - scale) < 0.01 {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func tagColor(_ tag: String) -> Color {
        FinderTagColor(finderTag: tag)?.color ?? .gray
    }
}

/// 待放置区不再塞进工具栏菜单：文件多时可搜索、全选和批量放回。
private struct InboxPanelView: View {
    @EnvironmentObject private var model: FolderCanvasModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedIDs: Set<String> = []

    private var filteredItems: [FolderItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return model.inboxItems }
        return model.inboxItems.filter {
            $0.name.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var selectedItems: [FolderItem] {
        model.inboxItems.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("待放置区").font(.title2.bold())
                    Text("主画布还可放置 \(model.availableCanvasSlots) 个项目")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            if model.inboxItems.isEmpty {
                ContentUnavailableView("待放置区为空", systemImage: "tray")
            } else {
                List(selection: $selectedIDs) {
                    ForEach(filteredItems) { item in
                        HStack(spacing: 10) {
                            Image(nsImage: model.icon(for: item))
                                .resizable()
                                .frame(width: 28, height: 28)
                            Text(item.name).lineLimit(1)
                            Spacer()
                        }
                        .tag(item.id)
                    }
                }
                .searchable(text: $query, prompt: "搜索待放置项目")
            }

            Divider()

            HStack {
                Button("全选当前结果") {
                    selectedIDs.formUnion(filteredItems.map(\.id))
                }
                .disabled(filteredItems.isEmpty)
                Button("清除选择") { selectedIDs.removeAll() }
                    .disabled(selectedIDs.isEmpty)
                Spacer()
                Text("已选 \(selectedItems.count) 项")
                    .foregroundStyle(.secondary)
                Button("放回主画布") {
                    model.placeFromInbox(selectedItems)
                    selectedIDs.subtract(selectedItems.map(\.id))
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    selectedItems.isEmpty
                        || model.availableCanvasSlots == 0
                        || !model.canEditLayout
                )
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 430)
        .onChange(of: model.inboxIDs) { _, currentIDs in
            selectedIDs.formIntersection(currentIDs)
        }
    }
}

private extension FinderTagColor {
    var color: Color {
        switch self {
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .gray: .gray
        }
    }

}

private struct FileInfoView: View {
    let item: FolderItem
    @EnvironmentObject private var model: FolderCanvasModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: model.icon(for: item)).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading) {
                    Text(item.name).font(.headline)
                    Text(item.url.pathExtension.isEmpty ? "文件夹" : item.url.pathExtension.uppercased())
                        .foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow { Text("位置").foregroundStyle(.secondary); Text(item.url.deletingLastPathComponent().path).textSelection(.enabled) }
                GridRow {
                    Text("大小").foregroundStyle(.secondary)
                    if let snapshot = model.infoSnapshot {
                        Text(ByteCountFormatter.string(fromByteCount: snapshot.size, countStyle: .file))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                if let modified = model.infoSnapshot?.modificationDate {
                    GridRow { Text("修改日期").foregroundStyle(.secondary); Text(modified.formatted(date: .long, time: .shortened)) }
                }
                GridRow { Text("标签").foregroundStyle(.secondary); Text(item.tags.isEmpty ? "无" : item.tags.map { $0.components(separatedBy: "\n").first ?? $0 }.joined(separator: "、")) }
            }
            HStack {
                Spacer()
                Button("好") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
