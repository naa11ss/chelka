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
    @ObservedObject var music: MusicService

    var body: some View {
        VStack(spacing: DS.cardSpacing) {
            HStack(spacing: DS.cardSpacing) {
                MusicCard(service: music)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                MetricsCard(service: metrics)
                    .frame(width: 168)
            }
            // Минимум, не фиксированная высота: карточка метрик растёт,
            // когда на Intel-маке есть вентиляторы и под регулятор нужно
            // больше места, чем занимают три обычных индикатора.
            .frame(minHeight: 78)

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


