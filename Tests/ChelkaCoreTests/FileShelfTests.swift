import Foundation
import Testing

@testable import ChelkaCore

private func makeItem(_ path: String, at seconds: TimeInterval) -> FileShelfItem {
    FileShelfItem(url: URL(fileURLWithPath: path), addedAt: Date(timeIntervalSince1970: seconds))
}

@Suite("Полка файлов")
struct FileShelfTests {

    @Test("Новый файл добавляется первым")
    func addsToTop() {
        var shelf = FileShelf()
        shelf.add(makeItem("/tmp/a.png", at: 100))
        shelf.add(makeItem("/tmp/b.pdf", at: 200))

        #expect(shelf.items.count == 2)
        #expect(shelf.items.first?.displayName == "b.pdf")
    }

    @Test("Тот же файл не плодит дубликат, а поднимается наверх")
    func duplicateMovesToTop() {
        var shelf = FileShelf()
        shelf.add(makeItem("/tmp/a.png", at: 100))
        shelf.add(makeItem("/tmp/b.pdf", at: 200))

        let outcome = shelf.add(makeItem("/tmp/a.png", at: 300))

        #expect(shelf.items.count == 2)
        #expect(shelf.items.first?.displayName == "a.png")
        if case .movedToTop = outcome {} else {
            Issue.record("ожидалось movedToTop, получено \(outcome)")
        }
    }

    @Test("Сверх лимита вытесняется старейший")
    func evictsOldestOverLimit() {
        var shelf = FileShelf()
        for index in 0...FileShelf.limit {
            shelf.add(makeItem("/tmp/file\(index).txt", at: TimeInterval(index)))
        }

        #expect(shelf.items.count == FileShelf.limit)
        // Старейший — file0, он и должен был уйти.
        #expect(!shelf.items.contains { $0.displayName == "file0.txt" })
        #expect(shelf.items.contains { $0.displayName == "file\(FileShelf.limit).txt" })
    }

    @Test("Удаление пачкой убирает только выбранные")
    func removesBatch() {
        var shelf = FileShelf()
        shelf.add(makeItem("/tmp/a.png", at: 100))
        shelf.add(makeItem("/tmp/b.pdf", at: 200))
        shelf.add(makeItem("/tmp/c.mov", at: 300))

        let doomed = Set(shelf.items.filter { $0.displayName != "b.pdf" }.map(\.id))
        let removed = shelf.remove(ids: doomed)

        #expect(removed.count == 2)
        #expect(shelf.items.count == 1)
        #expect(shelf.items.first?.displayName == "b.pdf")
    }

    @Test("Расширение файла становится пометкой типа")
    func typeHintFromExtension() {
        #expect(makeItem("/tmp/обложка.png", at: 0).typeHint == "PNG")
        #expect(makeItem("/tmp/README", at: 0).typeHint == "FILE")
    }

    @Test("Очистка забирает всё и возвращает убранное")
    func clearReturnsEverything() {
        var shelf = FileShelf()
        shelf.add(makeItem("/tmp/a.png", at: 100))
        shelf.add(makeItem("/tmp/b.pdf", at: 200))

        let removed = shelf.clear()

        #expect(removed.count == 2)
        #expect(shelf.items.isEmpty)
    }
}
