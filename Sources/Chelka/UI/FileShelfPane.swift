import AppKit
import SwiftUI
import ChelkaCore

/// Полка файлов: перетащил сюда — забрал в другом окне.
struct FileShelfPane: View {
    @ObservedObject var service: FileShelfService

    /// Курсор с файлами прямо сейчас над полкой — подсвечиваем, что отпустить
    /// можно именно здесь.
    @State private var isTargeted = false

    var body: some View {
        Group {
            if service.shelf.items.isEmpty {
                emptyState
            } else {
                strip
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            load(providers)
            return true
        }
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
            .strokeBorder(
                isTargeted ? Color.accentColor : Color.notchStroke,
                style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [] : [4, 3])
            )
            .background(
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: isTargeted ? "arrow.down.doc" : "tray.and.arrow.down")
                        .font(.system(size: 14))
                    Text(isTargeted
                         ? T("files.drop.release", "Отпустите — файл ляжет на полку")
                         : T("files.empty", "Перетащите файлы сюда — заберёте в другом окне"))
                        .font(.system(size: 10))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(isTargeted ? Color.accentColor : Color.notchTertiary)
                .padding(.horizontal, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(NotchAnimation.content, value: isTargeted)
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(service.shelf.items) { item in
                    FileShelfCardView(
                        item: item,
                        thumbnail: service.thumbnail(for: item.id),
                        icon: service.icon(for: item),
                        isSelected: service.selectedIDs.contains(item.id),
                        isMultiSelected: service.selectedIDs.contains(item.id) && service.selectedIDs.count > 1,
                        onOpen: { service.reveal(item) },
                        onToggleSelect: { service.toggleSelection(id: item.id) },
                        onRemove: { service.remove(id: item.id) },
                        selectedURLs: { service.selectedURLs }
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay {
            // Пока над полкой висят файлы, подсветка нужна и на непустой
            // полке — иначе непонятно, примут ли здесь ещё один.
            if isTargeted {
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                            .fill(Color.accentColor.opacity(0.10))
                    )
                    .allowsHitTesting(false)
            }
        }
        .animation(NotchAnimation.content, value: isTargeted)
    }

    /// `NSItemProvider` отдаёт адрес асинхронно — собираем все и кладём
    /// на полку одним разом, чтобы порядок не зависел от того, кто из них
    /// ответил первым.
    private func load(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            service.add(urls: urls)
        }
    }
}

/// Одна карточка файла на полке.
private struct FileShelfCardView: View {
    let item: FileShelfItem
    let thumbnail: NSImage?
    let icon: NSImage
    let isSelected: Bool
    let isMultiSelected: Bool

    let onOpen: () -> Void
    let onToggleSelect: () -> Void
    let onRemove: () -> Void
    let selectedURLs: () -> [URL]

    @State private var isHovered = false

    private static let width: CGFloat = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    if NSEvent.modifierFlags.contains(.command) {
                        onToggleSelect()
                    } else {
                        onOpen()
                    }
                }
                .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                .overlay {
                    // Тот же приём, что у карточек буфера: пока запись входит
                    // в выбор из двух и более, перетаскивание перехватывает
                    // AppKit-сессия и выносит всю пачку разом.
                    if isMultiSelected {
                        FileBatchDragOverlay(onClick: onOpen, onToggleSelect: onToggleSelect, urls: selectedURLs)
                    }
                }

            footer
        }
        .padding(7)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(background)
        .contentShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
        .onHover { hovering in
            withAnimation(NotchAnimation.content) { isHovered = hovering }
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    // Значок типа файла, пока QuickLook готовит настоящее
                    // превью — и навсегда для того, у чего превью не бывает.
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if isHovered {
                Button(action: onRemove) {
                    Image(systemName: "trash.fill")
                }
                .help(T("files.remove", "Убрать с полки"))

                Spacer(minLength: 0)

                Text(item.typeHint)
                    .lineLimit(1)
            } else {
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 9))
        .foregroundStyle(Color.notchTertiary)
        .frame(height: 12)
        .padding(.top, 5)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
            .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.notchCard)
            .overlay {
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : (isHovered ? Color.accentColor.opacity(0.6) : Color.notchStroke),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
    }
}

// MARK: - Вынос пачкой

/// Для файлов промежуточные обещания (`NSFilePromiseProvider`) не нужны,
/// в отличие от записей буфера: файл уже лежит на диске, и `NSURL` сам по
/// себе умеет писаться в pasteboard — Finder получает настоящий адрес и
/// копирует по нему, без посредника.
private struct FileBatchDragOverlay: NSViewRepresentable {
    let onClick: () -> Void
    let onToggleSelect: () -> Void
    let urls: () -> [URL]

    func makeNSView(context: Context) -> FileBatchDragView {
        let view = FileBatchDragView()
        view.onClick = onClick
        view.onToggleSelect = onToggleSelect
        view.urls = urls
        return view
    }

    func updateNSView(_ nsView: FileBatchDragView, context: Context) {
        nsView.onClick = onClick
        nsView.onToggleSelect = onToggleSelect
        nsView.urls = urls
    }
}

final class FileBatchDragView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var onToggleSelect: (() -> Void)?
    var urls: (() -> [URL])?

    private var mouseDownEvent: NSEvent?
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let start = mouseDownEvent else { return }
        let dx = event.locationInWindow.x - start.locationInWindow.x
        let dy = event.locationInWindow.y - start.locationInWindow.y
        guard hypot(dx, dy) > 3 else { return }
        didDrag = true

        guard let urls = urls?(), !urls.isEmpty else { return }
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard !didDrag else { return }
        if event.modifierFlags.contains(.command) {
            onToggleSelect?()
        } else {
            onClick?()
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
