import SwiftUI
import ChelkaCore

/// Плашка события под вырезом: подключили зарядку, сели наушники, пропала сеть.
///
/// Появляется на несколько секунд и уходит сама — поэтому и рисуется
/// подчёркнуто живо: сухую строку текста, мелькнувшую на четыре секунды,
/// человек просто не успевает заметить, а движение ловится боковым зрением.
struct NotchEventPill: View {
    let event: SystemEvent
    /// Пристыкована ли плашка к физическому вырезу.
    ///
    /// На экране с вырезом она продолжает его собой: тот же чёрный, тот же
    /// верхний край экрана, скруглены только те углы, которых вырез не
    /// касается. Получается, что вырез будто раздался вбок и убрался
    /// обратно, а не что над окном всплыла отдельная табличка.
    var attachedToNotch: Bool = false

    /// Уровень для шкалы «доезжает» после появления, а не рисуется сразу
    /// готовым: заполняющаяся полоска читается как «вот сколько заряда»,
    /// нарисованная — как просто ещё одна деталь оформления.
    @State private var fill: Double = 0
    @State private var iconPulse = false

    var body: some View {
        HStack(spacing: 8) {
            icon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 11, weight: .medium))
                        // Фон пристыкованной плашки всегда чёрный — как сам
                        // вырез, — поэтому и текст на ней светлый независимо
                        // от темы: в светлой `notchPrimary` тёмный и пропал бы.
                        .foregroundStyle(attachedToNotch ? Color.white : Color.notchPrimary)
                        .lineLimit(1)

                    if let detail = event.detail {
                        Text(detail)
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(tint)
                            .contentTransition(.numericText())
                    }
                }

                // В пристыкованном виде шкалы нет: плашка держится
                // высоты выреза, а вторая строка в неё уже не влезает,
                // не сделав её выше него и не разрушив всю иллюзию.
                if event.level != nil, !attachedToNotch {
                    gauge
                }
            }
        }
        .padding(.horizontal, attachedToNotch ? 12 : 11)
        .padding(.vertical, 7)
        .background(background)
        .overlay(border)
        .shadow(color: .black.opacity(attachedToNotch ? 0.5 : 0.3), radius: 10, y: 4)
        .fixedSize()
        .onAppear {
            withAnimation(.easeOut(duration: 0.55).delay(0.12)) {
                fill = event.level ?? 0
            }
            iconPulse = true
        }
    }

    /// Пристыкованная плашка — продолжение выреза: тот же чёрный, скруглены
    /// только те углы, которых вырез не касается. Сверху угол прямой —
    /// там кромка экрана, слева тоже: там сам вырез.
    @ViewBuilder
    private var background: some View {
        if attachedToNotch {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: DS.bottomRadius * 0.6,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
        } else {
            Capsule().fill(Color.notchSurface)
        }
    }

    @ViewBuilder
    private var border: some View {
        // У пристыкованной обводки нет: у физического выреза её тоже нет,
        // а контур выдал бы, что это отдельная нарисованная деталь.
        if !attachedToNotch {
            Capsule().strokeBorder(Color.notchStroke, lineWidth: 1)
        }
    }

    private var icon: some View {
        Image(systemName: event.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(tint.opacity(attachedToNotch ? 0.22 : 0.16), in: Circle())
            // Один короткий отскок в момент появления — привлекает
            // внимание ровно настолько, чтобы плашку заметили.
            .symbolEffect(.bounce, value: iconPulse)
    }

    private var gauge: some View {
        Capsule()
            .fill(attachedToNotch ? Color.white.opacity(0.22) : Color.notchStroke)
            .frame(width: 78, height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * min(max(fill, 0), 1))
                }
            }
            .clipShape(Capsule())
    }

    /// Смысл цвета приходит из ядра — здесь только перевод в краску.
    private var tint: Color {
        switch event.tint {
        case .neutral: return .notchSecondary
        case .positive: return .green
        case .warning: return .yellow
        case .danger: return .red
        }
    }
}
