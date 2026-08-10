import AppKit
import Combine
import CryptoKit
import ChelkaCore
import UniformTypeIdentifiers

/// Связывает захват буфера, историю и хранилище.
///
/// Единственный владелец состояния истории: интерфейс только читает
/// `history` и зовёт методы, монитор только сообщает о новом содержимом.
@MainActor
final class ClipboardService: ObservableObject {

    /// Работает ли сохранение на диск.
    enum Persistence: Equatable {
        case onDisk
        /// Ключ или база недоступны: история живёт до выхода из приложения.
        case memoryOnly(reason: String)
    }

    @Published private(set) var history = ClipboardHistory()
    @Published private(set) var persistence: Persistence = .onDisk
    @Published private(set) var lastRejection: String?

    let settings: ClipboardSettings

    private let monitor = PasteboardMonitor()
    private let screenshots = ScreenshotWatcher()

    private var store: ClipboardStore?
    private var crypto: ClipboardCrypto

    /// Очередь записи в хранилище.
    ///
    /// Раньше каждая операция улетала отдельной `Task`, и порядок их
    /// выполнения не гарантировался: очистка истории успевала выполниться
    /// после нескольких сохранений и стирала только что записанное.
    /// Теперь операции сцеплены в цепочку и выполняются строго по порядку.
    private var writeChain: Task<Void, Never> = Task {}

    /// Нагрузка держится в памяти только когда диск недоступен.
    private var memoryPayloads: [UUID: ClipboardPayload] = [:]
    /// Уменьшенные превью картинок — рисовать список из полноразмерных
    /// снимков нельзя, это мегабайты на каждую перерисовку.
    private var thumbnails: [UUID: NSImage] = [:]

    static var databaseURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Chelka", isDirectory: true)
            .appendingPathComponent("history.sqlite")
    }

    init(settings: ClipboardSettings = ClipboardSettings()) {
        self.settings = settings
        // Временный ключ на случай, если связка недоступна: история тогда
        // не переживёт перезапуск, но дедупликация и шифрование в памяти работают.
        self.crypto = ClipboardCrypto(key: SymmetricKey(size: .bits256))
    }

    // MARK: - Запуск

    func start() {
        setUpStorage()

        monitor.onChange = { [weak self] pasteboard, bundleID in
            self?.handlePasteboardChange(pasteboard, sourceBundleID: bundleID)
        }
        monitor.start()

        screenshots.onNewFile = { [weak self] url in
            self?.handleScreenshotFile(url)
        }
        if settings.captureScreenshots {
            screenshots.start()
        }
    }

    func stop() {
        monitor.stop()
        screenshots.stop()
        flushSync()
    }

    /// Дожидается фоновых записей и сбрасывает журнал базы.
    ///
    /// Записи уходят в хранилище асинхронно, чтобы копирование не тормозило
    /// интерфейс. При выходе это оборачивается потерей последних записей —
    /// поэтому на завершении ждём явно.
    func flushSync(timeout: TimeInterval = 3) {
        guard let store else { return }

        enqueueWrite { store in
            try? await store.checkpoint()
        }

        let chain = writeChain
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await chain.value
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    /// Ставит операцию в очередь записи. Порядок вызовов сохраняется.
    private func enqueueWrite(_ operation: @escaping @Sendable (ClipboardStore) async -> Void) {
        guard let store else { return }

        let previous = writeChain
        // Именно detached: обычная `Task` унаследовала бы главный актор,
        // и запись на диск встала бы намертво, стоит главному потоку
        // на что-нибудь отвлечься. Хранилищу главный актор не нужен.
        writeChain = Task.detached(priority: .utility) {
            await previous.value
            await operation(store)
        }
    }

    /// Новое соединение с той же базой и тем же ключом — для проверок,
    /// что данные реально легли на диск, а не остались в памяти процесса.
    func makeVerificationStore() -> ClipboardStore? {
        try? ClipboardStore(databaseURL: Self.databaseURL, crypto: crypto)
    }

    private func setUpStorage() {
        do {
            let key = try ClipboardKeychain.loadOrCreateKey()
            let crypto = ClipboardCrypto(key: key)
            let store = try ClipboardStore(databaseURL: Self.databaseURL, crypto: crypto)

            self.crypto = crypto
            self.store = store
            self.persistence = .onDisk

            Task { await loadHistory(from: store) }

        } catch {
            persistence = .memoryOnly(reason: String(describing: error))
            Log.clipboard.error("хранилище недоступно: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadHistory(from store: ClipboardStore) async {
        do {
            let items = try await store.loadItems()
            var loaded = ClipboardHistory(items: items)

            // Пока шла асинхронная загрузка с диска, монитор мог успеть
            // захватить и вставить в `history` что-то новое (оно уже
            // сохранено на диск через отдельную цепочку записи) — без
            // этого слияния слепая подмена ниже стёрла бы его из
            // видимой истории до следующего перезапуска.
            let loadedIDs = Set(items.map(\.id))
            for capturedDuringLoad in history.items where !loadedIDs.contains(capturedDuringLoad.id) {
                loaded.insert(capturedDuringLoad)
            }

            history = loaded
            Log.clipboard.info("история загружена: \(items.count) записей")
            warmThumbnails()
        } catch {
            Log.clipboard.error("не удалось загрузить историю: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Захват

    private func handlePasteboardChange(_ pasteboard: NSPasteboard, sourceBundleID: String?) {
        let result = PasteboardReader.read(pasteboard, sourceBundleID: sourceBundleID, settings: settings)

        switch result {
        case .accepted(let reading):
            ingest(reading, sourceApp: sourceBundleID)
        case .rejected(let reason):
            note(rejection: reason)
        }
    }

    private func handleScreenshotFile(_ url: URL) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return }
        guard data.count <= ClipboardStore.maxPayloadBytes else {
            note(rejection: .tooLarge(data.count))
            return
        }

        let uti = UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.png.identifier
        let rep = NSBitmapImageRep(data: data)

        let reading = PasteboardReader.Reading(
            payload: .image(data: data, uti: uti),
            preview: url.lastPathComponent,
            subtitle: rep.map { "Снимок \($0.pixelsWide)×\($0.pixelsHigh)" } ?? "Снимок экрана",
            pixelWidth: rep?.pixelsWide,
            pixelHeight: rep?.pixelsHigh
        )
        ingest(reading, sourceApp: "com.apple.screencapture")
    }

    private func ingest(_ reading: PasteboardReader.Reading, sourceApp: String?) {
        let contentKey = crypto.contentKey(for: reading.payload.hashableBytes)

        let item = ClipboardItem(
            kind: reading.payload.kind,
            createdAt: Date(),
            contentKey: contentKey,
            preview: reading.preview,
            subtitle: reading.subtitle,
            sourceApp: sourceApp,
            byteSize: reading.payload.byteSize,
            pixelWidth: reading.pixelWidth,
            pixelHeight: reading.pixelHeight
        )

        let outcome = history.insert(item)
        lastRejection = nil

        switch outcome {
        case .inserted(let evicted):
            cacheThumbnail(for: item, payload: reading.payload)
            if store == nil { memoryPayloads[item.id] = reading.payload }
            persistInsert(item: item, payload: reading.payload, evicted: evicted)

        case .movedToTop(let existing):
            // Дубликат: тело уже сохранено, обновляем только время.
            persistMeta(existing)
        }
    }

    private func note(rejection: PasteboardReader.Rejection) {
        switch rejection {
        case .ownWrite, .empty:
            return
        case .transient:
            Log.clipboard.debug("пропущено: помечено как временное")
        case .concealed:
            lastRejection = T("clipboard.rejected.concealed", "Пропущено содержимое менеджера паролей")
        case .blacklisted(let bundleID):
            lastRejection = String(format: T("clipboard.rejected.blacklisted", "%@ в чёрном списке"), appName(for: bundleID))
        case .tooLarge(let size):
            lastRejection = String(format: T("clipboard.rejected.tooLarge", "Слишком большая запись — %@"), PasteboardReader.formatBytes(size))
        }
    }

    // MARK: - Действия пользователя

    /// Кладёт запись в буфер. Вставляет пользователь сам —
    /// приложение не трогает чужие окна и не требует разрешений.
    func copyToPasteboard(id: UUID) {
        Task { [weak self] in
            guard let self, let payload = await self.payload(for: id) else { return }
            self.write(payload, to: .general)
        }
    }

    func write(_ payload: ClipboardPayload, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        switch payload {
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .image(let data, let uti):
            pasteboard.setData(data, forType: NSPasteboard.PasteboardType(uti))
        case .files(let urls):
            pasteboard.writeObjects(urls as [NSURL])
        }

        // Своя метка, чтобы монитор не принял собственную запись за новое
        // копирование и не поднял запись наверх без действия пользователя.
        pasteboard.setData(Data(), forType: PasteboardReader.autoGeneratedType)
        monitor.acknowledgeOwnWrite()
    }

    func togglePin(id: UUID) {
        guard let item = history.item(id: id) else { return }

        if item.isPinned {
            let evicted = history.unpin(id: id)
            persistEviction(evicted)
        } else {
            guard history.pin(id: id) else {
                lastRejection = String(format: T("clipboard.pinLimit", "Закреплено максимум — %d"), ClipboardHistory.pinnedLimit)
                return
            }
        }

        if let updated = history.item(id: id) {
            persistMeta(updated)
        }
    }

    func remove(id: UUID) {
        guard history.remove(id: id) != nil else { return }
        thumbnails[id] = nil
        memoryPayloads[id] = nil

        enqueueWrite { store in
            try? await store.delete(ids: [id])
        }
    }

    func clear(keepPinned: Bool = true) {
        let removed = history.clear(keepPinned: keepPinned)
        for item in removed {
            thumbnails[item.id] = nil
            memoryPayloads[item.id] = nil
        }

        enqueueWrite { store in
            try? await store.deleteAll(keepPinned: keepPinned)
        }
    }

    // MARK: - Доступ к данным

    func payload(for id: UUID) async -> ClipboardPayload? {
        if let cached = memoryPayloads[id] { return cached }
        guard let store else { return nil }

        do {
            return try await store.payload(for: id)
        } catch {
            Log.clipboard.error("нагрузка не читается: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func thumbnail(for id: UUID) -> NSImage? {
        thumbnails[id]
    }

    /// Догружает превью для записей, поднятых из базы при запуске.
    func warmThumbnails() {
        let missing = history.items.filter { $0.kind == .image && thumbnails[$0.id] == nil }
        guard !missing.isEmpty, let store else { return }

        Task { [weak self] in
            for item in missing {
                guard let payload = try? await store.payload(for: item.id) else { continue }
                await MainActor.run { self?.cacheThumbnail(for: item, payload: payload) }
            }
        }
    }

    func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }

    // MARK: - Демонстрационные данные

    /// Сервис с примерами записей — для офлайн-снимков интерфейса.
    /// Ничего не пишет на диск и не следит за буфером.
    static func makeDemo() -> ClipboardService {
        let service = ClipboardService(settings: ClipboardSettings(defaults: UserDefaults(suiteName: "chelka.demo")!))
        service.persistence = .memoryOnly(reason: "демо")
        service.seedDemo()
        return service
    }

    private func seedDemo() {
        let samples: [PasteboardReader.Reading] = [
            .init(
                payload: .text("https://developer.apple.com/documentation/appkit/nspasteboard"),
                preview: "https://developer.apple.com/documentation/appkit/nspasteboard",
                subtitle: "developer.apple.com",
                pixelWidth: nil,
                pixelHeight: nil
            ),
            .init(
                payload: .image(data: Self.demoImageData(hue: 0.58), uti: "public.png"),
                preview: "Снимок экрана.png",
                subtitle: "Снимок 1710×1112",
                pixelWidth: 1710,
                pixelHeight: 1112
            ),
            .init(
                payload: .text("git rebase -i HEAD~3 && git push --force-with-lease"),
                preview: "git rebase -i HEAD~3 && git push --force-with-lease",
                subtitle: "52 симв.",
                pixelWidth: nil,
                pixelHeight: nil
            ),
            .init(
                payload: .files([URL(fileURLWithPath: "/Users/demo/Documents/договор.pdf")]),
                preview: "договор.pdf",
                subtitle: "/Users/demo/Documents",
                pixelWidth: nil,
                pixelHeight: nil
            ),
            .init(
                payload: .image(data: Self.demoImageData(hue: 0.92), uti: "public.png"),
                preview: "IMG_4821.HEIC",
                subtitle: "Фото с iPhone 4032×3024",
                pixelWidth: 4032,
                pixelHeight: 3024
            ),
            .init(
                payload: .text("Встреча перенесена на четверг, 15:30. Ссылка придёт отдельно."),
                preview: "Встреча перенесена на четверг, 15:30. Ссылка придёт отдельно.",
                subtitle: "61 симв.",
                pixelWidth: nil,
                pixelHeight: nil
            ),
        ]

        for sample in samples {
            ingest(sample, sourceApp: "com.apple.Safari")
        }
        if let first = history.items.last?.id {
            _ = history.pin(id: first)
        }
    }

    /// Простая заливка вместо настоящей картинки — снимкам интерфейса
    /// достаточно цветного прямоугольника.
    private static func demoImageData(hue: CGFloat) -> Data {
        let size = CGSize(width: 240, height: 160)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(hue: hue, saturation: 0.45, brightness: 0.7, alpha: 1).setFill()
        CGRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }

    // MARK: - Внутреннее

    private func cacheThumbnail(for item: ClipboardItem, payload: ClipboardPayload) {
        guard case .image(let data, _) = payload, let image = NSImage(data: data) else { return }

        let target = CGSize(width: 160, height: 160)
        let scale = min(target.width / image.size.width, target.height / image.size.height, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let thumbnail = NSImage(size: size)
        thumbnail.lockFocus()
        image.draw(in: CGRect(origin: .zero, size: size))
        thumbnail.unlockFocus()

        thumbnails[item.id] = thumbnail
    }

    private func persistInsert(item: ClipboardItem, payload: ClipboardPayload, evicted: [ClipboardItem]) {
        for evictedItem in evicted {
            thumbnails[evictedItem.id] = nil
            memoryPayloads[evictedItem.id] = nil
        }
        let evictedIDs = evicted.map(\.id)

        enqueueWrite { store in
            do {
                try await store.save(item: item, payload: payload)
                if !evictedIDs.isEmpty {
                    try await store.delete(ids: evictedIDs)
                }
            } catch {
                Log.clipboard.error("не удалось сохранить запись: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func persistMeta(_ item: ClipboardItem) {
        enqueueWrite { store in
            try? await store.updateMeta(item)
        }
    }

    private func persistEviction(_ evicted: [ClipboardItem]) {
        guard !evicted.isEmpty else { return }
        for item in evicted {
            thumbnails[item.id] = nil
            memoryPayloads[item.id] = nil
        }
        let ids = evicted.map(\.id)
        enqueueWrite { store in
            try? await store.delete(ids: ids)
        }
    }
}
