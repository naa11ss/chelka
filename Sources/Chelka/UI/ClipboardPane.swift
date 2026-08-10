import AppKit
import SwiftUI
import ChelkaCore
import UniformTypeIdentifiers

/// Лента истории буфера: закреплённые слева, дальше свежие.
struct ClipboardPane: View {
    @ObservedObject var service: ClipboardService
    /// Индекс записи, по которой только что кликнули — для отметки «скопировано».
    @State private var justCopied: UUID?
    /// Метка конкретного клика — двух кликов по одной и той же записи
    /// подряд недостаточно отличить сравнением `justCopied == item.id`,
    /// см. `copy(_:)`.
    @State private var justCopiedToken = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if service.history.items.isEmpty {
                emptyState
            } else {
                strip
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 10, weight: .semibold))
            Text(T("card.clipboard", "Буфер"))
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)

            Spacer(minLength: 8)

            if let message = service.lastRejection {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.notchTertiary)
                    .lineLimit(1)
            } else if case .memoryOnly = service.persistence {
                Label(T("clipboard.memoryOnly", "только в памяти"), systemImage: "exclamationmark.triangle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            } else {
                Text(counterText)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.notchTertiary)
            }
        }
        .foregroundStyle(Color.notchSecondary)
    }

    private var counterText: String {
        let pinned = service.history.pinned.count
        let regular = service.history.regular.count
        return pinned > 0
            ? "\(regular)/\(ClipboardHistory.regularLimit) · \(pinned) \(T("clipboard.pinnedShort", "закр."))"
            : "\(regular)/\(ClipboardHistory.regularLimit)"
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
            .fill(Color.notchCard)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 14))
                    Text(T("clipboard.empty", "Скопируй что-нибудь — появится здесь"))
                        .font(.system(size: 10))
                }
                .foregroundStyle(Color.notchTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(service.history.items.enumerated()), id: \.element.id) { index, item in
                    ClipboardCardView(
                        item: item,
                        index: index,
                        thumbnail: service.thumbnail(for: item.id),
                        isCopied: justCopied == item.id,
                        onCopy: { copy(item) },
                        onTogglePin: { service.togglePin(id: item.id) },
                        onRemove: { service.remove(id: item.id) },
                        itemProvider: { provider(for: item) }
                    )
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func copy(_ item: ClipboardItem) {
        service.copyToPasteboard(id: item.id)
        withAnimation(NotchAnimation.content) { justCopied = item.id }

        // Свой токен на каждый клик — двух кликов по одной и той же записи
        // в пределах 1.2с недостаточно отличить одним лишь `item.id`: таймер
        // первого клика нашёл бы `justCopied == item.id` всё ещё истинным
        // (второй клик поставил то же значение) и погасил бы значок раньше
        // срока второго клика. Тот же приём, что уже применён в `MusicCard`
        // для вспышки свайпа.
        let token = UUID()
        justCopiedToken = token

        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                guard justCopiedToken == token else { return }
                withAnimation(NotchAnimation.content) {
                    if justCopied == item.id { justCopied = nil }
                }
            }
        }
    }

    /// Провайдер для перетаскивания записи наружу.
    ///
    /// Данные отдаются лениво: карточка может быть картинкой на несколько
    /// мегабайт, и держать их в памяти ради возможного перетаскивания незачем.
    private func provider(for item: ClipboardItem) -> NSItemProvider {
        let provider = NSItemProvider()
        let service = self.service

        switch item.kind {
        case .text:
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.utf8PlainText.identifier,
                visibility: .all
            ) { completion in
                Task {
                    guard case .text(let string)? = await service.payload(for: item.id) else {
                        completion(nil, ChelkaError.storage("нет текста"))
                        return
                    }
                    completion(Data(string.utf8), nil)
                }
                return nil
            }

        case .image:
            // Записанный при копировании UTI, а не всегда PNG: обычное
            // копирование картинки часто кладёт на буфер TIFF или JPEG,
            // а `handleScreenshotFile` — то, что реально лежит в файле
            // снимка. Объявить системе "это PNG", когда байты на самом
            // деле TIFF, — значит, что принимающее приложение (Finder,
            // любой редактор) не сможет прочитать перетащенные данные:
            // перетаскивание визуально "работает", но ничего не долетает.
            let uti = item.uti ?? UTType.png.identifier
            provider.suggestedName = suggestedImageName(for: item)
            provider.registerDataRepresentation(forTypeIdentifier: uti, visibility: .all) { completion in
                Task {
                    guard case .image(let data, _)? = await service.payload(for: item.id) else {
                        completion(nil, ChelkaError.storage("нет картинки"))
                        return
                    }
                    completion(data, nil)
                }
                return nil
            }

        case .file:
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.fileURL.identifier,
                visibility: .all
            ) { completion in
                Task {
                    guard case .files(let urls)? = await service.payload(for: item.id), let first = urls.first else {
                        completion(nil, ChelkaError.storage("нет файла"))
                        return
                    }
                    completion(first.dataRepresentation, nil)
                }
                return nil
            }
        }

        return provider
    }

    private func suggestedImageName(for item: ClipboardItem) -> String {
        if item.preview.lowercased().hasSuffix(".png") || item.preview.lowercased().hasSuffix(".jpg") {
            return item.preview
        }
        // Расширение — от настоящего UTI, не всегда .png: имя с чужим
        // расширением поверх, скажем, TIFF-байт сбивает с толку то, во что
        // перетащенный файл открывается по умолчанию.
        let ext = item.uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "png"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Chelka \(formatter.string(from: item.createdAt)).\(ext)"
    }
}
