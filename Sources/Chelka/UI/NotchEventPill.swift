import SwiftUI
import ChelkaCore

/// Плашка события: выпадает прямо под вырезом, шириной ровно в вырез —
/// как будто сам вырез ненадолго вытянулся вниз и показал, что хотел
/// сказать, а не отдельная табличка сбоку.
///
/// Появляется на несколько секунд и уходит сама — поэтому и рисуется
/// подчёркнуто живо: сухую строку текста, мелькнувшую на четыре секунды,
/// человек просто не успевает заметить, а движение ловится боковым зрением.
struct NotchEventPill: View {
    let event: SystemEvent

    /// Уровень для шкалы «доезжает» после появления, а не рисуется сразу
    /// готовым: заполняющаяся полоска читается как «вот сколько заряда»,
    /// нарисованная — как просто ещё одна деталь оформления.
    @State private var fill: Double = 0
    @State private var iconPulse = false

    var body: some View {
        HStack(spacing: 8) {
            icon

            Text(event.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let detail = event.detail {
                Text(detail)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }

            if event.level != nil {
                gauge
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black, in: UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: DS.bottomRadius,
            bottomTrailingRadius: DS.bottomRadius,
            topTrailingRadius: 0,
            style: .continuous
        ))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
        .onAppear {
            withAnimation(.easeOut(duration: 0.55).delay(0.12)) {
                fill = event.level ?? 0
            }
            iconPulse = true
        }
    }

    private var icon: some View {
        Image(systemName: event.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 20, height: 20)
            .background(tint.opacity(0.22), in: Circle())
            // Один короткий отскок в момент появления — привлекает
            // внимание ровно настолько, чтобы плашку заметили.
            .symbolEffect(.bounce, value: iconPulse)
    }

    private var gauge: some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 60, height: 3)
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
