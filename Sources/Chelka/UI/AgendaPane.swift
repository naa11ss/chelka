import SwiftUI
import ChelkaCore

/// Сегодняшний день из настоящего Календаря.
struct AgendaPane: View {
    @ObservedObject var service: CalendarService
    /// Тикает раз в минуту: «идёт сейчас» и «через сколько» — про время,
    /// и без пересчёта они устареют молча.
    let clock: Date

    var body: some View {
        Group {
            switch service.access {
            case .denied:
                message(
                    symbol: "calendar.badge.exclamationmark",
                    text: T("agenda.denied", "Нет доступа к Календарю. Системные настройки → Конфиденциальность → Календари.")
                )
            case .unknown:
                message(
                    symbol: "calendar",
                    text: T("agenda.asking", "Спрашиваем доступ к Календарю…")
                )
            case .granted:
                if service.events.isEmpty {
                    message(symbol: "calendar", text: T("agenda.empty", "На сегодня встреч нет"))
                } else {
                    strip
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(symbol: String, text: String) -> some View {
        RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
            .fill(Color.notchCard)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: symbol)
                        .font(.system(size: 14))
                    Text(text)
                        .font(.system(size: 10))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(Color.notchTertiary)
                .padding(.horizontal, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(service.events) { event in
                    AgendaCardView(event: event, now: clock)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Одна встреча.
private struct AgendaCardView: View {
    let event: AgendaEvent
    let now: Date

    private static let width: CGFloat = 150

    private var isRunning: Bool { event.isRunning(at: now) }
    private var isOver: Bool { event.isOver(at: now) }

    var body: some View {
        HStack(spacing: 7) {
            // Полоска цвета календаря — единственное, что отличает
            // рабочую встречу от личной, не тратя на это слов.
            Capsule()
                .fill(accent)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isOver ? Color.notchTertiary : Color.notchPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(subtitle)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(isRunning ? Color.accentColor : Color.notchTertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(7)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .fill(Color.notchCard)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DS.cardRadius, style: .continuous)
                .strokeBorder(isRunning ? Color.accentColor.opacity(0.8) : Color.notchStroke, lineWidth: 1)
        }
        .opacity(isOver ? 0.55 : 1)
    }

    private var accent: Color {
        guard let hex = event.colorHex, let color = Color(hex: hex) else { return .accentColor }
        return color
    }

    private var subtitle: String {
        if event.isAllDay { return T("agenda.allDay", "Весь день") }
        if isRunning { return T("agenda.running", "идёт сейчас") }
        if let startsIn = DayAgenda.startsIn(event, now: now) {
            return "\(Self.time.string(from: event.start)) · \(startsIn)"
        }
        return Self.time.string(from: event.start)
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

extension Color {
    /// Цвет календаря приходит из EventKit строкой — см. `CalendarService`.
    init?(hex: String) {
        var value: UInt64 = 0
        guard Scanner(string: hex).scanHexInt64(&value), hex.count == 6 else { return nil }
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
