import AppKit
import SwiftUI
import ChelkaCore

/// Одна запись истории.
///
/// Клик кладёт в буфер, перетаскивание вытаскивает содержимое в любое
/// приложение, кнопки появляются только при наведении — иначе шесть иконок
/// на карточке размером со спичечный коробок.
struct ClipboardCardView: View {
    let item: ClipboardItem
    let index: Int
    let thumbnail: NSImage?
    let isCopied: Bool
    let isSelected: Bool
    /// Эта карточка — часть выбора из двух и более записей. Переключает
    /// перетаскивание на настоящую AppKit-сессию (см. `BatchDragOverlay`) —
    /// SwiftUI `.onDrag` умеет отдать наружу только один `NSItemProvider`,
    /// а перетащить пачку выбранных карточек разом им нельзя в принципе.
    let isMultiSelected: Bool

    let onCopy: () -> Void
    let onToggleSelect: () -> Void
    let onTogglePin: () -> Void
    let onRemove: () -> Void
    let itemProvider: () -> NSItemProvider
    /// Обещания всех выбранных записей разом — только для `isMultiSelected`,
    /// вызывается лениво, лишь когда перетаскивание реально началось.
    let allSelectedEntries: () -> [BatchDragEntry]

    @State private var isHovered = false

    private static let width: CGFloat = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Клик и перетаскивание — только на области содержимого, не
                // на всей карточке: раньше `.onTapGesture`/`.onDrag` сидели
                // на VStack целиком, то есть родителем над кнопками "закрепить"/
                // "удалить" в подвале — и, судя по всему, забирали клик себе
                // раньше, чем он доходил до самих кнопок (сама кнопка ничего
                // не получала). Здесь эта неоднозначность в принципе не
                // возникает: у подвала нет ни одного жеста-конкурента рядом
                // с его собственными Button.
                .contentShape(Rectangle())
                .onTapGesture {
                    // SwiftUI не передаёт модификаторы в TapGesture напрямую —
                    // читаем их из текущего состояния клавиатуры в момент
                    // клика, тот же приём, которым это решается на macOS
                    // повсеместно.
                    if NSEvent.modifierFlags.contains(.command) {
                        onToggleSelect()
                    } else {
                        onCopy()
                    }
                }
                .onDrag(itemProvider)
                .overlay {
                    // Только над содержимым, не над подвалом — та же причина,
                    // что и выше: покрывая всю карточку целиком, этот оверлей
                    // молча глушил бы кнопки подвала, стоило записи попасть
                    // в выбор из двух и более. Активен он только пока эта
                    // карточка — часть такого выбора: для одиночных карточек
                    // (обычный случай) в дереве видов его вообще нет.
                    if isMultiSelected {
                        BatchDragOverlay(
                            onClick: onCopy,
                            onToggleSelect: onToggleSelect,
                            entries: allSelectedEntries
                        )
                    }
                }

            footer
        }
        .padding(7)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(background)
        .overlay(alignment: .topTrailing) { badges }
        .overlay { copiedOverlay }
        // Отдельно от того `.contentShape` над содержимым: этот — только
        // для наведения, чтобы кнопки подвала показывались/прятались по
        // всей карточке целиком, а не только над её верхней частью.
        .contentShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
        .onHover { hovering in
            withAnimation(NotchAnimation.content) { isHovered = hovering }
        }
    }

    // MARK: - Содержимое

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            imageContent
        case .file:
            fileContent
        case .text:
            textContent
        }
    }

    private var imageContent: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.notchCard)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.notchTertiary)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var fileContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.notchSecondary)
            Text(item.preview)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.notchPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }

    private var textContent: some View {
        Text(item.preview)
            .font(.system(size: 10))
            .foregroundStyle(Color.notchPrimary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Подвал и значки

    private var footer: some View {
        HStack(spacing: 4) {
            if isHovered {
                Button(action: onTogglePin) {
                    Image(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
                }
                .help(item.isPinned ? T("clipboard.unpin", "Открепить") : T("clipboard.pin", "Закрепить"))

                Button(action: onRemove) {
                    Image(systemName: "trash.fill")
                }
                .help(T("clipboard.delete", "Удалить"))

                Spacer(minLength: 0)
            } else {
                Text(subtitleText)
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

    private var subtitleText: String {
        item.subtitle ?? item.kind.rawValue
    }

    /// Номер записи (для клавиатуры) и метка закрепления.
    private var badges: some View {
        HStack(spacing: 3) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7))
            }
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(Color.notchTertiary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.notchCard, in: Capsule())
        .padding(4)
        .opacity(item.isPinned || index < 9 ? 1 : 0)
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

    @ViewBuilder
    private var copiedOverlay: some View {
        if isCopied {
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .fill(.black.opacity(0.55))
                .overlay {
                    Label(T("clipboard.copied", "Скопировано"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .transition(.opacity)
        }
    }
}

// MARK: - Перетаскивание пачки выбранных карточек

/// Данные для одной обещанной записи в пакетном перетаскивании: имя файла,
/// UTI и сама нагрузка — загружается лениво, только когда система реально
/// подтверждает, что запись перетащена и просит её записать.
struct BatchDragEntry {
    let filename: String
    let uti: String
    let loadData: () async -> Data?
}

/// Мост к настоящей `NSDraggingSession`. Пока карточка не часть множественного
/// выбора, она не существует в дереве видов — сюда попадают только записи,
/// у которых уже есть активный многозаписевый выбор (Cmd+клик).
///
/// `NSItemProvider` (уже применяется для одиночного `.onDrag` выше) не
/// подходит: `NSDraggingItem(pasteboardWriter:)` требует `NSPasteboardWriting`,
/// которому `NSItemProvider` не соответствует. `NSFilePromiseProvider` —
/// ровно то, что рассчитано на несколько лениво загружаемых файлов в одной
/// сессии перетаскивания.
private struct BatchDragOverlay: NSViewRepresentable {
    let onClick: () -> Void
    let onToggleSelect: () -> Void
    let entries: () -> [BatchDragEntry]

    func makeNSView(context: Context) -> BatchDragCatcherView {
        let view = BatchDragCatcherView()
        view.onClick = onClick
        view.onToggleSelect = onToggleSelect
        view.entries = entries
        return view
    }

    func updateNSView(_ nsView: BatchDragCatcherView, context: Context) {
        nsView.onClick = onClick
        nsView.onToggleSelect = onToggleSelect
        nsView.entries = entries
    }
}

/// Прозрачная область поверх карточки: пока не начался настоящий
/// перетаскивающий жест (порог в 3pt, как и у остальных жестов в этом
/// файле), `mouseUp` без движения ведёт себя как обычный клик — ровно то
/// же самое ветвление по Cmd, что и `.onTapGesture` на одиночной карточке,
/// просто на уровне AppKit, потому что перехватить событие для перетаскивания
/// пачки в любом случае надо здесь.
final class BatchDragCatcherView: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    var onToggleSelect: (() -> Void)?
    var entries: (() -> [BatchDragEntry])?

    private var mouseDownEvent: NSEvent?
    private var didDrag = false
    /// Делегаты обещаний должны пережить сам жест — `NSFilePromiseProvider`
    /// не держит их сильной ссылкой сам.
    private var activeDelegates: [FilePromiseDelegate] = []

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

        guard let entries = entries?(), !entries.isEmpty else { return }

        var delegates: [FilePromiseDelegate] = []
        let draggingItems = entries.map { entry -> NSDraggingItem in
            let delegate = FilePromiseDelegate(filename: entry.filename, loadData: entry.loadData)
            delegates.append(delegate)

            let promise = NSFilePromiseProvider(fileType: entry.uti, delegate: delegate)
            let dragItem = NSDraggingItem(pasteboardWriter: promise)
            dragItem.setDraggingFrame(bounds, contents: nil)
            return dragItem
        }
        activeDelegates = delegates

        beginDraggingSession(with: draggingItems, event: event, source: self)
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

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        activeDelegates.removeAll()
    }
}

/// Один делегат на одну обещанную запись — `NSFilePromiseProvider` спрашивает
/// имя и байты только когда цель перетаскивания реально приняла файл,
/// а не заранее на каждую карточку в выборе.
private final class FilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let filename: String
    private let loadData: () async -> Data?

    init(filename: String, loadData: @escaping () async -> Data?) {
        self.filename = filename
        self.loadData = loadData
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        filename
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            guard let data = await loadData() else {
                completionHandler(ChelkaError.storage("нет данных для перетаскивания"))
                return
            }
            do {
                try data.write(to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}
