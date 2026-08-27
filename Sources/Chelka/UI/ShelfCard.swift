import SwiftUI
import ChelkaCore

/// Нижняя карточка виджета: буфер обмена и полка файлов двумя вкладками.
///
/// Буфер открыт по умолчанию — он наполняется сам и нужен чаще; полка
/// требует осознанного действия, туда заходят намеренно.
struct ShelfCard: View {
    @ObservedObject var clipboard: ClipboardService
    @ObservedObject var files: FileShelfService

    enum Tab: Hashable {
        case clipboard
        case files
    }

    @State private var tab: Tab = .clipboard
    /// Файл занесён над карточкой — неважно, какая вкладка открыта.
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tabBar

            switch tab {
            case .clipboard:
                ClipboardPane(service: clipboard, showsHeader: false)
            case .files:
                FileShelfPane(service: files, isTargeted: isDropTargeted)
            }
        }
        .padding(10)
        .background(Color.notchCard, in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .strokeBorder(Color.notchStroke, lineWidth: 1)
        }
        .frame(maxHeight: .infinity)
        // Приём файлов — на всей карточке, а не внутри вкладки «Файлы».
        // Пользователь с зажатым файлом не может переключить вкладку: клик
        // занят самим перетаскиванием. Поэтому карточка принимает файл
        // всегда, а на вкладку «Файлы» переходит сама, как только файл
        // занесли — иначе поднесённый к виджету файл на вкладке «Буфер»
        // просто некуда было отпустить.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            load(providers)
            return true
        }
        .onChange(of: isDropTargeted) { _, targeted in
            guard targeted, tab != .files else { return }
            withAnimation(NotchAnimation.content) { tab = .files }
        }
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
            files.add(urls: urls)
            // Файл долетел — показываем полку, даже если переключение по
            // наведению почему-то не сработало.
            withAnimation(NotchAnimation.content) { tab = .files }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            tabButton(
                .clipboard,
                title: T("card.clipboard", "Буфер"),
                systemImage: "doc.on.clipboard",
                count: clipboard.history.items.count
            )
            tabButton(
                .files,
                title: T("card.files", "Файлы"),
                systemImage: "folder",
                count: files.shelf.items.count
            )

            Spacer(minLength: 8)

            accessory
        }
        .foregroundStyle(Color.notchSecondary)
    }

    /// Правая часть строки вкладок зависит от того, что открыто: у буфера
    /// это счётчик и предупреждения, у полки — действия над выбранным.
    @ViewBuilder
    private var accessory: some View {
        switch tab {
        case .clipboard:
            if let message = clipboard.lastRejection {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.notchTertiary)
                    .lineLimit(1)
            } else if case .memoryOnly = clipboard.persistence {
                Label(T("clipboard.memoryOnly", "только в памяти"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            } else {
                Text(clipboardCounterText)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.notchTertiary)
            }
        case .files:
            if files.selectedIDs.isEmpty {
                if !files.shelf.items.isEmpty {
                    Button(action: { files.clear() }) {
                        Text(T("files.clear", "Очистить"))
                            .font(.system(size: 9, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.notchTertiary)
                }
            } else {
                HStack(spacing: 6) {
                    Text(String(format: T("files.selected", "Выбрано: %d"), files.selectedIDs.count))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.notchTertiary)

                    Button(action: { files.removeSelected() }) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.notchTertiary)
                    .help(T("files.remove", "Убрать с полки"))
                }
            }
        }
    }

    private var clipboardCounterText: String {
        let pinned = clipboard.history.pinned.count
        let regular = clipboard.history.regular.count
        return pinned > 0
            ? "\(regular)/\(ClipboardHistory.regularLimit) · \(pinned) \(T("clipboard.pinnedShort", "закр."))"
            : "\(regular)/\(ClipboardHistory.regularLimit)"
    }

    private func tabButton(_ value: Tab, title: String, systemImage: String, count: Int) -> some View {
        let isActive = tab == value

        return Button {
            withAnimation(NotchAnimation.content) {
                tab = value
                // Выбор живёт внутри своей вкладки: уходя с полки, снимаем
                // его, иначе Delete и вынос пачкой продолжали бы относиться
                // к тому, чего пользователь уже не видит.
                if value != .files { files.clearSelection() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isActive ? Color.notchPrimary : Color.notchTertiary)
                }
            }
            .foregroundStyle(isActive ? Color.notchPrimary : Color.notchTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isActive ? Color.notchStroke.opacity(0.9) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
