import Foundation
import Testing

@testable import ChelkaCore

private func makeItem(
    _ text: String,
    at seconds: TimeInterval,
    pinned: Bool = false
) -> ClipboardItem {
    ClipboardItem(
        kind: .text,
        createdAt: Date(timeIntervalSince1970: seconds),
        isPinned: pinned,
        contentKey: "key-\(text)",
        preview: text,
        byteSize: text.utf8.count
    )
}

@Suite("История буфера")
struct ClipboardHistoryTests {

    @Test("Новая запись встаёт наверх")
    func insertsOnTop() {
        var history = ClipboardHistory()
        history.insert(makeItem("первый", at: 1))
        history.insert(makeItem("второй", at: 2))

        #expect(history.items.count == 2)
        #expect(history.items.first?.preview == "второй")
    }

    @Test("Повторное копирование поднимает запись, а не плодит дубликат")
    func duplicateMovesToTop() {
        var history = ClipboardHistory()
        history.insert(makeItem("а", at: 1))
        history.insert(makeItem("б", at: 2))

        let outcome = history.insert(makeItem("а", at: 3))

        #expect(history.items.count == 2)
        #expect(history.items.first?.preview == "а")
        if case .movedToTop = outcome {} else {
            Issue.record("ожидался подъём существующей записи, получено \(outcome)")
        }
    }

    @Test("Повтор закреплённой записи не снимает закрепление")
    func duplicateKeepsPinnedFlag() {
        var history = ClipboardHistory()
        history.insert(makeItem("важное", at: 1))
        let id = history.items[0].id
        let pinned1 = history.pin(id: id)
        #expect(pinned1)

        history.insert(makeItem("важное", at: 5))

        #expect(history.items.count == 1)
        #expect(history.items[0].isPinned)
    }

    @Test("Сверх десяти обычных записей старейшая вытесняется")
    func evictsOldestBeyondLimit() {
        var history = ClipboardHistory()
        for index in 1...ClipboardHistory.regularLimit {
            history.insert(makeItem("запись\(index)", at: TimeInterval(index)))
        }
        #expect(history.regular.count == 10)

        let outcome = history.insert(makeItem("одиннадцатая", at: 11))

        #expect(history.regular.count == 10)
        #expect(history.items.first?.preview == "одиннадцатая")
        #expect(!history.items.contains { $0.preview == "запись1" })

        if case .inserted(let evicted) = outcome {
            #expect(evicted.count == 1)
            #expect(evicted.first?.preview == "запись1")
        } else {
            Issue.record("ожидалась вставка с вытеснением, получено \(outcome)")
        }
    }

    @Test("Закреплённые не занимают места в ленте из десяти")
    func pinnedDoNotConsumeRegularSlots() {
        var history = ClipboardHistory()
        history.insert(makeItem("закреплю", at: 0))
        let pinned2 = history.pin(id: history.items[0].id)
        #expect(pinned2)

        for index in 1...ClipboardHistory.regularLimit {
            history.insert(makeItem("запись\(index)", at: TimeInterval(index)))
        }

        #expect(history.pinned.count == 1)
        #expect(history.regular.count == 10)
        #expect(history.items.count == 11)
        #expect(history.items.contains { $0.preview == "закреплю" })
    }

    @Test("Больше пяти закрепить нельзя")
    func pinLimitIsEnforced() {
        var history = ClipboardHistory()
        for index in 1...6 {
            history.insert(makeItem("з\(index)", at: TimeInterval(index)))
        }

        let ids = history.items.map(\.id)
        for id in ids.prefix(ClipboardHistory.pinnedLimit) {
            let pinned3 = history.pin(id: id)
            #expect(pinned3)
        }
        #expect(history.pinned.count == 5)

        // Шестое закрепление отклоняется, чужие закрепления не трогаются.
        let sixth = history.pin(id: ids[5])
        #expect(sixth == false)
        #expect(history.pinned.count == 5)
    }

    @Test("Открепление возвращает запись в ленту и может вытеснить старейшую")
    func unpinCanTriggerEviction() {
        var history = ClipboardHistory()
        history.insert(makeItem("старое-закреплённое", at: 0))
        let pinnedID = history.items[0].id
        let pinned4 = history.pin(id: pinnedID)
        #expect(pinned4)

        for index in 1...ClipboardHistory.regularLimit {
            history.insert(makeItem("запись\(index)", at: TimeInterval(index)))
        }
        #expect(history.items.count == 11)

        let evicted = history.unpin(id: pinnedID)

        #expect(history.pinned.isEmpty)
        #expect(history.regular.count == 10)
        // Открепляемая запись самая старая — она же и вытесняется.
        #expect(evicted.first?.preview == "старое-закреплённое")
    }

    @Test("Очистка сохраняет закреплённые")
    func clearKeepsPinned() {
        var history = ClipboardHistory()
        for index in 1...5 {
            history.insert(makeItem("з\(index)", at: TimeInterval(index)))
        }
        let pinned5 = history.pin(id: history.items[0].id)
        #expect(pinned5)

        let removed = history.clear()

        #expect(history.items.count == 1)
        #expect(history.items[0].isPinned)
        #expect(removed.count == 4)
    }

    @Test("Полная очистка убирает и закреплённые")
    func clearAllRemovesEverything() {
        var history = ClipboardHistory()
        history.insert(makeItem("а", at: 1))
        let pinned6 = history.pin(id: history.items[0].id)
        #expect(pinned6)

        history.clear(keepPinned: false)

        #expect(history.items.isEmpty)
    }

    @Test("Порядок: закреплённые сверху, внутри групп новые первыми")
    func ordering() {
        var history = ClipboardHistory()
        history.insert(makeItem("старое", at: 1))
        history.insert(makeItem("новое", at: 9))
        history.insert(makeItem("закреплённое", at: 5))

        let pinID = history.items.first { $0.preview == "закреплённое" }!.id
        let pinned7 = history.pin(id: pinID)
        #expect(pinned7)

        #expect(history.items.map(\.preview) == ["закреплённое", "новое", "старое"])
    }

    @Test("Удаление по идентификатору")
    func removeByID() {
        var history = ClipboardHistory()
        history.insert(makeItem("а", at: 1))
        history.insert(makeItem("б", at: 2))

        let id = history.items[0].id
        let removedItem = history.remove(id: id)
        #expect(removedItem?.preview == "б")
        #expect(history.items.count == 1)
        let missing = history.remove(id: UUID())
        #expect(missing == nil)
    }
}
