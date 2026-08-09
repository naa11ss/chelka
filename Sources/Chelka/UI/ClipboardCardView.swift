import AppKit
import SwiftUI
import ChelkaCore

/// Одна запись истории.
///
/// Клик кладёт в буфер, перетаскивание вытаскивает содержимое в любое
/// приложение, кнопки появляются только при наведении — иначе шесть иконок
/// на карточке размером со спичечный коробок.
struct ClipboardCardView: View {
    let item: ClipboardItem
    let index: Int
    let thumbnail: NSImage?
    let isCopied: Bool

    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onRemove: () -> Void
    let itemProvider: () -> NSItemProvider

    @State private var isHovered = false

    private static let width: CGFloat = 118

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .padding(7)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(background)
        .overlay(alignment: .topTrailing) { badges }
        .overlay { copiedOverlay }
        .contentShape(RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
        .onHover { hovering in
            withAnimation(NotchAnimation.content) { isHovered = hovering }
        }
        .onTapGesture(perform: onCopy)
        .onDrag(itemProvider)
        .help(tooltip)
    }

    // MARK: - Содержимое

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            imageContent
        case .file:
            fileContent
        case .text:
            textContent
        }
    }

    private var imageContent: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.notchCard)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.notchTertiary)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var fileContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.system(size: 16))
                .foregroundStyle(Color.notchSecondary)
            Text(item.preview)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.notchPrimary)
                .lineLimit(3)
            Spacer(minLength: 0)
        }
    }

    private var textContent: some View {
        Text(item.preview)
            .font(.system(size: 10))
            .foregroundStyle(Color.notchPrimary)
            .lineLimit(3)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Подвал и значки

    private var footer: some View {
        HStack(spacing: 4) {
            if isHovered {
                Button(action: onTogglePin) {
                    Image(systemName: item.isPinned ? "pin.slash.fill" : "pin.fill")
                }
                .help(item.isPinned ? "Открепить" : "Закрепить")

                Button(action: onRemove) {
                    Image(systemName: "trash.fill")
                }
                .help("Удалить")

                Spacer(minLength: 0)
            } else {
                Text(subtitleText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 9))
        .foregroundStyle(Color.notchTertiary)
        .frame(height: 12)
        .padding(.top, 5)
    }

    private var subtitleText: String {
        item.subtitle ?? item.kind.rawValue
    }

    /// Номер записи (для клавиатуры) и метка закрепления.
    private var badges: some View {
        HStack(spacing: 3) {
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 7))
            }
            if index < 9 {
                Text("\(index + 1)")
                    .font(.system(size: 8, weight: .semibold).monospacedDigit())
            }
        }
        .foregroundStyle(Color.notchTertiary)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color.notchCard, in: Capsule())
        .padding(4)
        .opacity(item.isPinned || index < 9 ? 1 : 0)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
            .fill(Color.notchCard)
            .overlay {
                RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                    .strokeBorder(
                        isHovered ? Color.accentColor.opacity(0.6) : Color.notchStroke,
                        lineWidth: 1
                    )
            }
    }

    @ViewBuilder
    private var copiedOverlay: some View {
        if isCopied {
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .fill(.black.opacity(0.55))
                .overlay {
                    Label("Скопировано", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .transition(.opacity)
        }
    }

    private var tooltip: String {
        var parts = [item.preview]
        if let subtitle = item.subtitle { parts.append(subtitle) }
        parts.append("Клик — в буфер · Перетащи, чтобы вынести")
        return parts.joined(separator: "\n")
    }
}
