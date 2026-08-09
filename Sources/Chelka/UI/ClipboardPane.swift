import AppKit
import SwiftUI
import ChelkaCore
import UniformTypeIdentifiers

/// Лента истории буфера: закреплённые слева, дальше свежие.
struct ClipboardPane: View {
    @ObservedObject var service: ClipboardService
    /// Индекс записи, по которой только что кликнули — для отметки «скопировано».
    @State private var justCopied: UUID?

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
            Text("Буфер")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)

            Spacer(minLength: 8)

            if let message = service.lastRejection {
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.notchTertiary)
                    .lineLimit(1)
            } else if case .memoryOnly = service.persistence {
                Label("только в памяти", systemImage: "exclamationmark.triangle")
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
            ? "\(regular)/\(ClipboardHistory.regularLimit) · \(pinned) закр."
            : "\(regular)/\(ClipboardHistory.regularLimit)"
    }

    private var emptyState: some View {
        RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
            .fill(Color.notchCard)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 14))
                    Text("Скопируй что-нибудь — появится здесь")
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

        Task {
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
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
            let uti = UTType.png.identifier
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Chelka \(formatter.string(from: item.createdAt)).png"
    }
}
