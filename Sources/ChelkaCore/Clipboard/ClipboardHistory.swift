import Foundation

/// Правила истории буфера в чистом виде: сколько храним, что вытесняем,
/// как ведёт себя повторное копирование.
///
/// Ни файлов, ни базы, ни AppKit — поэтому все граничные случаи
/// (переполнение, повтор закреплённого, лимит закреплений)
/// проверяются тестами, а не руками через сто копирований.
public struct ClipboardHistory: Sendable, Equatable {

    /// Сколько обычных записей держим. Закреплённые считаются отдельно.
    public static let regularLimit = 10
    /// Сколько записей можно закрепить сверх лимита.
    public static let pinnedLimit = 5

    /// Все записи: закреплённые впереди, внутри групп — новые сверху.
    public private(set) var items: [ClipboardItem]

    public init(items: [ClipboardItem] = []) {
        self.items = ClipboardHistory.sorted(items)
    }

    public var pinned: [ClipboardItem] { items.filter(\.isPinned) }
    public var regular: [ClipboardItem] { items.filter { !$0.isPinned } }

    /// Результат вставки — интерфейсу нужно знать, что именно поменялось.
    public enum InsertOutcome: Sendable, Equatable {
        /// Новая запись добавлена, перечисленные вытеснены.
        case inserted(evicted: [ClipboardItem])
        /// Такое уже было: запись поднята наверх, дубликат не создан.
        case movedToTop(existing: ClipboardItem)
    }

    /// Добавляет запись. Повтор не плодит дубликат, а поднимает существующую:
    /// копировать один и тот же фрагмент трижды — обычное дело, и история
    /// не должна из-за этого забиваться.
    @discardableResult
    public mutating func insert(_ item: ClipboardItem) -> InsertOutcome {
        if let index = items.firstIndex(where: { $0.contentKey == item.contentKey }) {
            var existing = items[index]
            existing.createdAt = item.createdAt
            items.remove(at: index)
            items.append(existing)
            items = ClipboardHistory.sorted(items)
            return .movedToTop(existing: existing)
        }

        items.append(item)
        items = ClipboardHistory.sorted(items)
        return .inserted(evicted: evictOverflow())
    }

    /// Закрепляет запись. Возвращает `false`, если лимит закреплений исчерпан —
    /// молча выкидывать чужое закрепление хуже, чем сказать «некуда».
    @discardableResult
    public mutating func pin(id: UUID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        guard !items[index].isPinned else { return true }
        guard pinned.count < Self.pinnedLimit else { return false }

        items[index].isPinned = true
        items = ClipboardHistory.sorted(items)
        // Открепление места в обычной ленте могло освободить слот,
        // но вытеснять после закрепления нечего — запись ушла из ленты.
        _ = evictOverflow()
        return true
    }

    /// Снимает закрепление. Запись возвращается в обычную ленту
    /// и может тут же вытеснить самую старую.
    @discardableResult
    public mutating func unpin(id: UUID) -> [ClipboardItem] {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return [] }
        guard items[index].isPinned else { return [] }

        items[index].isPinned = false
        items = ClipboardHistory.sorted(items)
        return evictOverflow()
    }

    @discardableResult
    public mutating func remove(id: UUID) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Очищает историю. Закреплённые по умолчанию остаются:
    /// их закрепили именно чтобы не потерять.
    @discardableResult
    public mutating func clear(keepPinned: Bool = true) -> [ClipboardItem] {
        let removed = keepPinned ? regular : items
        items = keepPinned ? pinned : []
        return removed
    }

    public func item(id: UUID) -> ClipboardItem? {
        items.first { $0.id == id }
    }

    // MARK: - Внутреннее

    /// Выбрасывает обычные записи сверх лимита, начиная со старейших.
    private mutating func evictOverflow() -> [ClipboardItem] {
        let regularItems = regular
        guard regularItems.count > Self.regularLimit else { return [] }

        let overflow = regularItems.suffix(regularItems.count - Self.regularLimit)
        let evictedIDs = Set(overflow.map(\.id))
        items.removeAll { evictedIDs.contains($0.id) }
        return Array(overflow)
    }

    /// Закреплённые сверху, внутри каждой группы — новые первыми.
    private static func sorted(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.createdAt > rhs.createdAt
        }
    }
}
