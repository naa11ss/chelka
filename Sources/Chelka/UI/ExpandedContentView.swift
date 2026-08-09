import SwiftUI
import ChelkaCore

/// Содержимое раскрытого виджета.
///
/// Два ряда: сверху музыка и метрики, снизу лента буфера во всю ширину.
/// Буфер — то, ради чего виджет открывают чаще всего, поэтому ему
/// отдана целая строка, а не треть.
struct ExpandedContentView: View {
    @ObservedObject var clipboard: ClipboardService
    @ObservedObject var metrics: MetricsService

    var body: some View {
        VStack(spacing: DS.cardSpacing) {
            HStack(spacing: DS.cardSpacing) {
                MusicPlaceholder()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                MetricsCard(service: metrics)
                    .frame(width: 168)
            }
            .frame(height: 78)

            ClipboardPane(service: clipboard)
                .padding(10)
                .background(Color.notchCard, in: RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                        .strokeBorder(Color.notchStroke, lineWidth: 1)
                }
                .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Карточка

struct Card<Content: View>: View {
    let title: String
    let systemImage: String
    let stage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                if let stage {
                    Text(stage)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.notchTertiary)
                        .lineLimit(1)
                }
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

// MARK: - Заглушки следующих этапов

private struct MusicPlaceholder: View {
    var body: some View {
        Card(title: "Музыка", systemImage: "music.note", stage: "этап 4") {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.notchCard)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.notchTertiary)
                    }
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Ничего не играет")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.notchPrimary)
                    Text("Music · Spotify")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.notchSecondary)

                    HStack(spacing: 12) {
                        ForEach(["backward.fill", "play.fill", "forward.fill"], id: \.self) { symbol in
                            Image(systemName: symbol)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.notchTertiary)
                        }
                    }
                    .padding(.top, 1)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

