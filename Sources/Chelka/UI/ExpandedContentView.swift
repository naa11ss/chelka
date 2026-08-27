import SwiftUI
import ChelkaCore

/// Содержимое раскрытого виджета.
///
/// Два ряда: сверху музыка и метрики, снизу буфер и полка файлов во всю
/// ширину. Это то, ради чего виджет открывают чаще всего, поэтому им
/// отдана целая строка, а не треть.
struct ExpandedContentView: View {
    @ObservedObject var clipboard: ClipboardService
    @ObservedObject var files: FileShelfService
    @ObservedObject var metrics: MetricsService
    @ObservedObject var music: MusicService
    @ObservedObject var devices: DeviceBatteryReader

    var body: some View {
        VStack(spacing: DS.cardSpacing) {
            HStack(spacing: DS.cardSpacing) {
                MusicCard(service: music)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Только когда наушники (или мышь, клавиатура) реально
                // подключены и сообщают заряд: пустая рамка «устройств нет»
                // отъедала бы место у музыки постоянно, а сказать ей нечего.
                if let device = devices.devices.first(where: \.hasAnyLevel) {
                    DeviceBatteryCard(device: device)
                        .frame(width: 150)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                MetricsCard(service: metrics)
                    .frame(width: 168)
            }
            .animation(NotchAnimation.content, value: devices.devices)
            // Минимум, не фиксированная высота: карточка метрик растёт,
            // когда на Intel-маке есть вентиляторы и под регулятор нужно
            // больше места, чем занимают три обычных индикатора.
            .frame(minHeight: 78)

            ShelfCard(clipboard: clipboard, files: files)
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


