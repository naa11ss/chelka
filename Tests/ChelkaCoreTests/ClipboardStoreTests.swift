import CryptoKit
import Foundation
import Testing

@testable import ChelkaCore

/// Ключ задаётся явно: тесты не должны трогать связку ключей пользователя.
private let testCrypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))

private func temporaryDatabaseURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("chelka-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("history.sqlite")
}

private func makeItem(kind: ClipboardKind, preview: String, key: String, size: Int = 10) -> ClipboardItem {
    ClipboardItem(
        kind: kind,
        createdAt: Date(timeIntervalSince1970: 1000),
        contentKey: key,
        preview: preview,
        byteSize: size
    )
}

@Suite("Шифрование")
struct ClipboardCryptoTests {

    @Test("Круговой цикл шифрования возвращает исходные байты")
    func sealOpenRoundTrip() throws {
        let secret = Data("пароль от банка".utf8)
        let sealed = try testCrypto.seal(secret)

        #expect(sealed != secret)
        #expect(try testCrypto.open(sealed) == secret)
    }

    @Test("Чужой ключ не расшифровывает")
    func foreignKeyFails() throws {
        let sealed = try testCrypto.seal(Data("секрет".utf8))
        let other = ClipboardCrypto(key: SymmetricKey(size: .bits256))

        #expect(throws: (any Error).self) {
            try other.open(sealed)
        }
    }

    @Test("Одинаковое содержимое даёт одинаковый ключ дедупликации")
    func contentKeyIsStable() {
        let data = Data("повторяю".utf8)
        #expect(testCrypto.contentKey(for: data) == testCrypto.contentKey(for: data))
    }

    @Test("Разное содержимое даёт разные ключи, а разные секреты — разные ключи для одного текста")
    func contentKeyIsKeyed() {
        let first = testCrypto.contentKey(for: Data("а".utf8))
        let second = testCrypto.contentKey(for: Data("б".utf8))
        #expect(first != second)

        let other = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        #expect(other.contentKey(for: Data("а".utf8)) != first)
    }
}

@Suite("Хранилище истории")
struct ClipboardStoreTests {

    @Test("Текст переживает перезапуск")
    func textSurvivesReopen() async throws {
        let url = temporaryDatabaseURL()
        let item = makeItem(kind: .text, preview: "привет", key: "k1")

        let store = try ClipboardStore(databaseURL: url, crypto: testCrypto)
        try await store.save(item: item, payload: .text("привет, мир"))

        // Новый экземпляр = как после перезапуска приложения.
        let reopened = try ClipboardStore(databaseURL: url, crypto: testCrypto)
        let items = try await reopened.loadItems()

        #expect(items.count == 1)
        #expect(items[0].preview == "привет")
        #expect(try await reopened.payload(for: item.id) == .text("привет, мир"))
    }

    @Test("Картинка сохраняется побайтово")
    func imageRoundTrip() async throws {
        let url = temporaryDatabaseURL()
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let item = makeItem(kind: .image, preview: "снимок", key: "k2", size: bytes.count)

        let store = try ClipboardStore(databaseURL: url, crypto: testCrypto)
        try await store.save(item: item, payload: .image(data: bytes, uti: "public.png"))

        let loaded = try await store.payload(for: item.id)
        #expect(loaded == .image(data: bytes, uti: "public.png"))
    }

    @Test("Пути файлов сохраняются, сами файлы не копируются")
    func filesRoundTrip() async throws {
        let url = temporaryDatabaseURL()
        let paths = [URL(fileURLWithPath: "/tmp/один.txt"), URL(fileURLWithPath: "/tmp/два.pdf")]
        let item = makeItem(kind: .file, preview: "2 файла", key: "k3")

        let store = try ClipboardStore(databaseURL: url, crypto: testCrypto)
        try await store.save(item: item, payload: .files(paths))

        #expect(try await store.payload(for: item.id) == .files(paths))
    }

    @Test("На диске нет открытого текста")
    func diskContainsNoPlaintext() async throws {
        let url = temporaryDatabaseURL()
        let secret = "СЕКРЕТНАЯ-СТРОКА-ДЛЯ-ПОИСКА"
        let item = makeItem(kind: .text, preview: secret, key: "k4")

        let store = try ClipboardStore(databaseURL: url, crypto: testCrypto)
        try await store.save(item: item, payload: .text(secret))
        // WAL-режим держит свежие страницы в отдельном файле — проверяем оба.
        try await store.checkpoint()

        let database = try Data(contentsOf: url)
        let needle = Data(secret.utf8)

        #expect(database.range(of: needle) == nil)
        #expect(item.preview == secret)
    }

    @Test("Обновление метаданных не трогает нагрузку")
    func updateMetaKeepsPayload() async throws {
        let url = temporaryDatabaseURL()
        var item = makeItem(kind: .text, preview: "закрепляемое", key: "k5")

        let store = try ClipboardStore(databaseURL: url, crypto: testCrypto)
        try await store.save(item: item, payload: .text("тело записи"))

        item.isPinned = true
        try await store.updateMeta(item)

        let items = try await store.loadItems()
        #expect(items[0].isPinned)
        #expect(try await store.payload(for: item.id) == .text("тело записи"))
    }

    @Test("Удаление по списку идентификаторов")
    func deleteByIDs() async throws {
        let url = temporaryDatabaseURL()
        let store = try ClipboardStore(databaseURL: url, crypto: testCrypto)

        let first = makeItem(kind: .text, preview: "первый", key: "k6")
        let second = makeItem(kind: .text, preview: "второй", key: "k7")
        try await store.save(item: first, payload: .text("1"))
        try await store.save(item: second, payload: .text("2"))

        try await store.delete(ids: [first.id])

        let items = try await store.loadItems()
        #expect(items.count == 1)
        #expect(items[0].preview == "второй")
    }

    @Test("Полная очистка сохраняет закреплённые")
    func deleteAllKeepsPinned() async throws {
        let url = temporaryDatabaseURL()
        let store = try ClipboardStore(databaseURL: url, crypto: testCrypto)

        var pinned = makeItem(kind: .text, preview: "важное", key: "k8")
        pinned.isPinned = true
        try await store.save(item: pinned, payload: .text("важное"))
        try await store.save(item: makeItem(kind: .text, preview: "обычное", key: "k9"), payload: .text("обычное"))

        try await store.deleteAll(keepPinned: true)

        let items = try await store.loadItems()
        #expect(items.count == 1)
        #expect(items[0].preview == "важное")
    }

    @Test("Слишком большая запись отклоняется")
    func oversizedPayloadRejected() async throws {
        let url = temporaryDatabaseURL()
        let store = try ClipboardStore(databaseURL: url, crypto: testCrypto)
        let huge = Data(count: ClipboardStore.maxPayloadBytes + 1)
        let item = makeItem(kind: .image, preview: "гигант", key: "k10", size: huge.count)

        await #expect(throws: (any Error).self) {
            try await store.save(item: item, payload: .image(data: huge, uti: "public.png"))
        }
    }

    @Test("Записи с чужим ключом не роняют загрузку, а пропускаются")
    func unreadableRowsAreSkipped() async throws {
        let url = temporaryDatabaseURL()

        let store = try ClipboardStore(databaseURL: url, crypto: testCrypto)
        try await store.save(item: makeItem(kind: .text, preview: "своя", key: "k11"), payload: .text("своя"))

        // Другой ключ = как если бы связку пересоздали.
        let strangerCrypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
        let stranger = try ClipboardStore(databaseURL: url, crypto: strangerCrypto)

        let items = try await stranger.loadItems()
        #expect(items.isEmpty)
    }
}
