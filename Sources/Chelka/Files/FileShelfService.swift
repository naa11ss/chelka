import AppKit
import Combine
import QuickLookThumbnailing
import ChelkaCore

/// Полка файлов: перевалочный пункт между окнами.
///
/// Хранит пути, а не копии — см. `FileShelfItem`. Отсюда два следствия,
/// которые видны пользователю: полка переживает перезапуск приложения,
/// но запись исчезает, если сам файл удалили или перенесли. Второе
/// проверяется при загрузке, чтобы полка не показывала призраков.
@MainActor
final class FileShelfService: ObservableObject {

    @Published private(set) var shelf = FileShelf()
    /// Записи, выбранные Cmd+кликом — для пакетного удаления и выноса.
    @Published private(set) var selectedIDs: Set<UUID> = []

    /// Файл занесён над виджетом. Ставится из AppKit-слоя
    /// (`PassThroughContentView`), читается интерфейсом: по нему карточка
    /// переключается на вкладку «Файлы» и подсвечивает зону приёма.
    @Published private(set) var isDragTargeted = false

    func setDragTargeted(_ value: Bool) {
        guard isDragTargeted != value else { return }
        isDragTargeted = value
    }

    private static let defaultsKey = "chelka.fileShelf"

    private let defaults: UserDefaults
    private var thumbnails: [UUID: NSImage] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: - Добавление и удаление

    /// Кладёт файлы на полку. Несуществующие пути игнорируются молча:
    /// перетащить можно что угодно, включая ссылку на уже удалённое.
    func add(urls: [URL]) {
        let now = Date()
        var added = false

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            shelf.add(FileShelfItem(url: url, addedAt: now))
            added = true
        }

        guard added else { return }
        persist()
        warmThumbnails()
    }

    func remove(id: UUID) {
        guard shelf.remove(id: id) != nil else { return }
        thumbnails[id] = nil
        selectedIDs.remove(id)
        persist()
    }

    func removeSelected() {
        guard !selectedIDs.isEmpty else { return }
        let removed = shelf.remove(ids: selectedIDs)
        for item in removed { thumbnails[item.id] = nil }
        selectedIDs.removeAll()
        persist()
    }

    func clear() {
        let removed = shelf.clear()
        for item in removed { thumbnails[item.id] = nil }
        selectedIDs.removeAll()
        persist()
    }

    // MARK: - Выбор

    func toggleSelection(id: UUID) {
        guard shelf.item(id: id) != nil else { return }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    func clearSelection() {
        selectedIDs.removeAll()
    }

    /// Пути выбранных записей — для выноса пачкой одним жестом.
    var selectedURLs: [URL] {
        selectedIDs.compactMap { shelf.item(id: $0)?.url }
    }

    // MARK: - Показ

    func thumbnail(for id: UUID) -> NSImage? {
        thumbnails[id]
    }

    /// Значок типа файла — всегда доступен сразу, в отличие от превью,
    /// которое QuickLook готовит асинхронно. Полка не должна выглядеть
    /// пустой в первые кадры после раскрытия виджета.
    func icon(for item: FileShelfItem) -> NSImage {
        NSWorkspace.shared.icon(forFile: item.url.path)
    }

    /// Открывает файл в приложении по умолчанию — двойной клик по карточке.
    func reveal(_ item: FileShelfItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: - Внутреннее

    private func load() {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode([FileShelfItem].self, from: data)
        else { return }

        // Файл мог уехать или быть удалён, пока приложение не работало —
        // показывать запись, за которой ничего нет, хуже, чем не показывать
        // ничего: клик по ней всё равно ни к чему не приведёт.
        let alive = stored.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        shelf = FileShelf(items: alive)

        if alive.count != stored.count { persist() }
        warmThumbnails()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(shelf.items) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Готовит превью для тех записей, у которых его ещё нет.
    ///
    /// QuickLook умеет отдать настоящую картинку для изображений, PDF и
    /// видео — значок типа файла для них выглядел бы одинаково серо, а на
    /// полке важно узнать файл в лицо, не читая имя.
    private func warmThumbnails() {
        let missing = shelf.items.filter { thumbnails[$0.id] == nil }
        guard !missing.isEmpty else { return }

        let scale = NSScreen.main?.backingScaleFactor ?? 2

        for item in missing {
            let request = QLThumbnailGenerator.Request(
                fileAt: item.url,
                size: CGSize(width: 160, height: 160),
                scale: scale,
                representationTypes: .thumbnail
            )

            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
                guard let representation else { return }
                let image = NSImage(cgImage: representation.cgImage, size: representation.contentRect.size)
                Task { @MainActor in
                    self?.thumbnails[item.id] = image
                    // Полка уже опубликована, а превью приходит позже —
                    // без явного сигнала SwiftUI не узнает, что картинка
                    // появилась: сам словарь превью не `@Published`.
                    self?.objectWillChange.send()
                }
            }
        }
    }
}
