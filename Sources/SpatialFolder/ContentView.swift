import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: FolderCanvasModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            Group {
                if model.folderURL == nil {
                    ContentUnavailableView("选择一个文件夹", systemImage: "square.grid.2x2",
                                           description: Text("把它变成一张可长期记忆的空间画布。"))
                } else {
                    FolderCanvasView()
                }
            }
        }
        .alert("空间文件夹", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button(action: model.chooseFolder) { Label("选择文件夹", systemImage: "folder") }
            if let folder = model.folderURL {
                Text(folder.lastPathComponent).font(.headline)
                Spacer()
                Button(action: model.createFolder) { Label("新建文件夹", systemImage: "folder.badge.plus") }
                Button(action: model.chooseWallpaper) { Label("壁纸", systemImage: "photo") }
                Button(action: model.refreshItems) { Image(systemName: "arrow.clockwise") }
                    .help("刷新")
            } else { Spacer() }
        }
        .padding(12)
        .background(.bar)
    }
}

private struct FolderCanvasView: View {
    @EnvironmentObject private var model: FolderCanvasModel

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    CanvasBackground(url: model.wallpaperURL ?? model.defaultDesktopWallpaperURL)
                        .frame(width: model.desktopCanvasSize.width, height: model.desktopCanvasSize.height)
                        .contentShape(Rectangle())
                        .onTapGesture { model.clearSelection() }
                        .gesture(selectionGesture)
                    ForEach(model.items) { item in
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
                .frame(width: model.desktopCanvasSize.width,
                       height: model.desktopCanvasSize.height)
                .contextMenu {
                    Menu("新建") {
                        Button("文件夹", action: model.createFolder)
                        Button("Excel 工作簿", action: model.createExcelWorkbook)
                        Button("Word 文档", action: model.createWordDocument)
                        Button("PowerPoint 演示文稿", action: model.createPowerPointPresentation)
                    }
                }
            }
        }
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
}

private struct CanvasBackground: View {
    let url: URL?
    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(red: 0.08, green: 0.14, blue: 0.23), Color(red: 0.12, green: 0.28, blue: 0.32)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct CanvasIcon: View {
    @EnvironmentObject private var model: FolderCanvasModel
    let item: FolderItem
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var renamePresented = false
    @State private var renameText = ""

    var body: some View {
        let point = model.position(for: item)
        let scale = model.scale(for: item)
        let isSelected = model.selectedIDs.contains(item.id)
        let sharedOffset = model.draggingIDs.contains(item.id) ? model.dragTranslation : .zero
        VStack(spacing: 5) {
            Image(nsImage: item.icon).resizable().interpolation(.high)
                .frame(width: 56 * scale, height: 56 * scale)
            Text(item.name)
                .font(.system(size: max(10, 12 * scale)))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 94 * scale)
                .foregroundStyle(.white)
                .shadow(radius: 2)
        }
        .frame(width: 104 * scale, height: 96 * scale)
        .background(isSelected ? Color.accentColor.opacity(0.32) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isSelected ? Color.white.opacity(0.9) : .clear, lineWidth: 1))
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
        .contextMenu {
            Button("打开") { model.open(item) }
            Button("在访达中显示") { model.reveal(item) }
            Divider()
            Menu("图标与字体大小") {
                scaleButton("小", scale: 0.75, currentScale: scale)
                scaleButton("标准", scale: 1, currentScale: scale)
                scaleButton("大", scale: 1.25, currentScale: scale)
                scaleButton("特大", scale: 1.5, currentScale: scale)
            }
            Divider()
            Button("重命名…") { renameText = item.name; renamePresented = true }
            Button("移至废纸篓", role: .destructive) { model.trash(item) }
        }
        .alert("重命名", isPresented: $renamePresented) {
            TextField("名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("重命名") { model.rename(item, to: renameText) }
        }
    }

    @ViewBuilder
    private func scaleButton(_ title: String, scale: CGFloat, currentScale: CGFloat) -> some View {
        Button {
            model.setScale(scale, for: item)
        } label: {
            if abs(currentScale - scale) < 0.01 {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
