import Foundation

/// Одна запись полки файлов.
///
/// Хранится путь, а не копия файла — как и у `.files` в буфере обмена.
/// Полка это перевалочный пункт («бросил — потом заберу»), а не хранилище:
/// копировать чужие гигабайты ради этого незачем, а файл, лежащий на своём
/// месте, остаётся тем же самым файлом, а не устаревшим дублем.
public struct FileShelfItem: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let url: URL
    public let addedAt: Date

    public init(id: UUID = UUID(), url: URL, addedAt: Date) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
    }

    /// Имя файла для подписи под карточкой.
    public var displayName: String { url.lastPathComponent }

    /// Расширение в верхнем регистре — короткая пометка типа на карточке.
    public var typeHint: String {
        let ext = url.pathExtension
        return ext.isEmpty ? "FILE" : ext.uppercased()
    }
}

/// Правила полки файлов в чистом виде: сколько держим, что вытесняем,
/// как ведёт себя повторное добавление того же файла.
///
/// Ни AppKit, ни диска — поэтому лимит, дедупликация и порядок проверяются
/// тестами, а не двадцатью перетаскиваниями мышью.
public struct FileShelf: Sendable, Equatable {

    /// Сколько файлов держим. Полка, а не склад: больше двадцати —
    /// это уже папка, и ей место в Finder.
    public static let limit = 20

    /// Все записи, новые сверху.
    public private(set) var items: [FileShelfItem]

    public init(items: [FileShelfItem] = []) {
        self.items = FileShelf.sorted(items)
    }

    public enum AddOutcome: Sendable, Equatable {
        /// Добавлен, перечисленные вытеснены лимитом.
        case added(evicted: [FileShelfItem])
        /// Такой файл уже на полке — поднят наверх, дубликат не создан.
        case movedToTop(existing: FileShelfItem)
    }

    /// Кладёт файл на полку. Тот же путь не плодит дубликат, а поднимает
    /// существующую запись: перетащить один и тот же файл дважды — обычное
    /// дело, и полка не должна из-за этого забиваться копиями одного имени.
    @discardableResult
    public mutating func add(_ item: FileShelfItem) -> AddOutcome {
        if let index = items.firstIndex(where: { $0.url == item.url }) {
            var existing = items[index]
            existing = FileShelfItem(id: existing.id, url: existing.url, addedAt: item.addedAt)
            items.remove(at: index)
            items.append(existing)
            items = FileShelf.sorted(items)
            return .movedToTop(existing: existing)
        }

        items.append(item)
        items = FileShelf.sorted(items)
        return .added(evicted: evictOverflow())
    }

    @discardableResult
    public mutating func remove(id: UUID) -> FileShelfItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    @discardableResult
    public mutating func remove(ids: Set<UUID>) -> [FileShelfItem] {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        return removed
    }

    @discardableResult
    public mutating func clear() -> [FileShelfItem] {
        let removed = items
        items = []
        return removed
    }

    public func item(id: UUID) -> FileShelfItem? {
        items.first { $0.id == id }
    }

    // MARK: - Внутреннее

    /// Выбрасывает записи сверх лимита, начиная со старейших.
    private mutating func evictOverflow() -> [FileShelfItem] {
        guard items.count > Self.limit else { return [] }

        let overflow = items.suffix(items.count - Self.limit)
        let evictedIDs = Set(overflow.map(\.id))
        items.removeAll { evictedIDs.contains($0.id) }
        return Array(overflow)
    }

    private static func sorted(_ items: [FileShelfItem]) -> [FileShelfItem] {
        items.sorted { $0.addedAt > $1.addedAt }
    }
}
