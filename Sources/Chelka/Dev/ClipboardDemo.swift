import AppKit
import ChelkaCore

/// `Chelka --clipboard-demo` — сквозная проверка буфера обмена на живой системе.
///
/// Кладёт в буфер настоящие данные, ждёт, пока их подхватит монитор, и сверяет
/// историю с ожиданиями. Проверяет всю цепочку разом: NSPasteboard → разбор →
/// дедупликация → лимиты → шифрованная запись на диск.
///
/// Содержимое буфера в конце восстанавливается.
@MainActor
enum ClipboardDemo {

    static func run(service: ClipboardService) {
        let pasteboard = NSPasteboard.general
        let original = pasteboard.string(forType: .string)

        var failures = 0

        func check(_ label: String, _ condition: Bool, detail: String = "") {
            if !condition { failures += 1 }
            print("\(condition ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        func settle(_ seconds: TimeInterval = 0.8) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        func copyText(_ string: String) {
            pasteboard.clearContents()
            pasteboard.setString(string, forType: .string)
            settle()
        }

        print("сквозная проверка буфера обмена")
        print("хранилище: \(service.persistence == .onDisk ? "на диске" : "только в памяти")")
        print("")

        service.clear(keepPinned: false)
        settle(0.4)

        // 1. Обычный текст.
        copyText("первая запись")
        check("текст попадает в историю", service.history.items.first?.preview == "первая запись",
              detail: service.history.items.first?.preview ?? "пусто")

        // 2. Ссылка распознаётся отдельно от простого текста.
        copyText("https://developer.apple.com/documentation")
        check("у ссылки в подписи домен",
              service.history.items.first?.subtitle == "developer.apple.com",
              detail: service.history.items.first?.subtitle ?? "нет")

        // 3. Повтор не плодит дубликат.
        let beforeDuplicate = service.history.items.count
        copyText("первая запись")
        check("повтор не создаёт дубликат",
              service.history.items.count == beforeDuplicate,
              detail: "было \(beforeDuplicate), стало \(service.history.items.count)")
        check("повтор поднимается наверх",
              service.history.items.first?.preview == "первая запись")

        // 4. Картинка.
        pasteboard.clearContents()
        pasteboard.setData(makeImageData(), forType: .png)
        settle()
        check("картинка распознана", service.history.items.first?.kind == .image,
              detail: service.history.items.first?.subtitle ?? "нет")

        // 5. Лимит ленты.
        for index in 1...12 {
            copyText("наполнение \(index)")
        }
        check("в ленте не больше десяти",
              service.history.regular.count == ClipboardHistory.regularLimit,
              detail: "\(service.history.regular.count)")

        // 6. Закрепление переживает вытеснение.
        if let oldest = service.history.regular.last {
            service.togglePin(id: oldest.id)
            let pinnedID = oldest.id
            for index in 1...12 {
                copyText("вытеснение \(index)")
            }
            check("закреплённая запись не вытесняется",
                  service.history.items.contains { $0.id == pinnedID })
            check("закреплённые не занимают места в ленте",
                  service.history.regular.count == ClipboardHistory.regularLimit,
                  detail: "\(service.history.regular.count) обычных + \(service.history.pinned.count) закр.")
        }

        // 7. Своя запись в буфер не считается новым копированием.
        if let target = service.history.items.first(where: { $0.kind == .text }) {
            let countBefore = service.history.items.count
            let topBefore = service.history.regular.first?.id
            service.copyToPasteboard(id: target.id)
            settle()
            check("собственная запись в буфер не меняет историю",
                  service.history.items.count == countBefore && service.history.regular.first?.id == topBefore)
        }

        // 8. Чёрный список.
        //
        // Источником считается приложение, активное в момент копирования,
        // а не то, которое положило данные в буфер: узнать второе система
        // не даёт. Значит и в чёрный список заносим активное приложение.
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        service.settings.addToBlacklist(sourceBundleID)

        let marker = "это-не-должно-сохраниться-\(UUID().uuidString.prefix(8))"
        copyText(marker)
        check("из приложения в чёрном списке не сохраняем",
              !service.history.items.contains { $0.preview.contains("это-не-должно-сохраниться") },
              detail: "источник \(sourceBundleID), верх: \(service.history.items.first?.preview.prefix(30) ?? "пусто")")

        service.settings.removeFromBlacklist(sourceBundleID)
        copyText("после снятия из чёрного списка")
        // Свежая запись — первая в обычной ленте: `items` начинается
        // с закреплённых, а одна запись к этому моменту уже закреплена.
        check("после снятия из чёрного списка снова сохраняем",
              service.history.regular.first?.preview == "после снятия из чёрного списка",
              detail: service.history.regular.first?.preview ?? "пусто")

        // 9. Данные реально на диске, а не только в памяти процесса.
        service.flushSync()
        settle(0.5)

        if case .onDisk = service.persistence {
            let expected = service.history.items.count
            var storedCount = -1

            var timedOut = false
            if let verification = service.makeVerificationStore() {
                let semaphore = DispatchSemaphore(value: 0)
                Task.detached {
                    storedCount = ((try? await verification.loadItems()) ?? []).count
                    semaphore.signal()
                }
                // Ограничено, в отличие от остальных ожиданий в этом файле
                // не было: застрявшая `ClipboardStore` (блокировка файла базы
                // другим процессом, повреждённая база) вешала бы `--clipboard-demo`
                // навсегда — без диагностики, без кода выхода, ничего.
                let deadline = Date().addingTimeInterval(5)
                while semaphore.wait(timeout: .now()) == .timedOut {
                    guard Date() < deadline else { timedOut = true; break }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
            }

            check("история лежит на диске и читается заново",
                  !timedOut && storedCount == expected,
                  detail: timedOut ? "проверка на диске не ответила за 5с" : "в памяти \(expected), на диске \(storedCount)")
        }

        print("")
        print("итог истории:")
        for (index, item) in service.history.items.enumerated() {
            let mark = item.isPinned ? "📌" : "  "
            print("  \(mark) \(index + 1). [\(item.kind.rawValue)] \(item.preview.prefix(52))")
        }

        // Возвращаем пользователю его буфер.
        pasteboard.clearContents()
        if let original { pasteboard.setString(original, forType: .string) }

        print("")
        print(failures == 0 ? "проверка пройдена" : "провалов: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func makeImageData() -> Data {
        let size = CGSize(width: 64, height: 48)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        CGRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return Data() }
        return png
    }
}
