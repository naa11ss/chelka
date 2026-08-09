import SwiftUI

/// Содержимое раскрытого виджета.
///
/// На этом этапе три блока — заглушки с финальной раскладкой: музыка слева,
/// метрики по центру, буфер справа. Следующие этапы заменяют внутренности
/// каждой карточки, не трогая композицию.
struct ExpandedContentView: View {
    var body: some View {
        HStack(spacing: DS.cardSpacing) {
            MusicPlaceholder()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            MetricsPlaceholder()
                .frame(width: 158)

            ClipboardPlaceholder()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Карточка

private struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    let stage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                Text(stage)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.notchTertiary)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.notchSecondary)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(10)
        .background(Color.notchCard, in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .strokeBorder(Color.notchStroke, lineWidth: 1)
        }
    }
}

// MARK: - Заглушки этапов

private struct MusicPlaceholder: View {
    var body: some View {
        Card(title: "Музыка", systemImage: "music.note", stage: "этап 4") {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.notchCard)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 18))
                            .foregroundStyle(Color.notchTertiary)
                    }
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Ничего не играет")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.notchPrimary)
                    Text("Music · Spotify")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.notchSecondary)

                    HStack(spacing: 14) {
                        ForEach(["backward.fill", "play.fill", "forward.fill"], id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.notchTertiary)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct MetricsPlaceholder: View {
    var body: some View {
        Card(title: "Система", systemImage: "gauge.medium", stage: "этап 3") {
            VStack(spacing: 7) {
                MetricRow(label: "CPU", value: "—")
                MetricRow(label: "RAM", value: "—")
                MetricRow(label: "Темп.", value: "—")
            }
            .padding(.top, 2)
        }
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.notchSecondary)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.notchPrimary)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.notchStroke)
                .frame(height: 1)
                .offset(y: 5)
        }
    }
}

private struct ClipboardPlaceholder: View {
    var body: some View {
        Card(title: "Буфер", systemImage: "doc.on.clipboard", stage: "этап 2") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.notchCard)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Color.notchStroke, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            }
                            .frame(height: 40)
                    }
                }
                Text("История появится здесь: 10 записей + 5 закреплённых")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.notchTertiary)
                    .lineLimit(2)
            }
        }
    }
}
