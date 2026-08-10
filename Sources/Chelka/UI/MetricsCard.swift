import SwiftUI
import ChelkaCore

/// Карточка состояния системы: загрузка процессора, память, температура.
struct MetricsCard: View {
    @ObservedObject var service: MetricsService

    var body: some View {
        Card(title: T("card.system", "Система"), systemImage: "gauge.medium", stage: nil) {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    MetricGauge(
                        label: "CPU",
                        value: service.snapshot.cpuPercent,
                        display: percent(service.snapshot.cpuPercent),
                        fraction: fraction(service.snapshot.cpuPercent),
                        tint: load(service.snapshot.cpuPercent)
                    )

                    MetricGauge(
                        label: "RAM",
                        value: service.snapshot.memory?.usedPercent,
                        display: percent(service.snapshot.memory?.usedPercent),
                        fraction: fraction(service.snapshot.memory?.usedPercent),
                        tint: load(service.snapshot.memory?.usedPercent)
                    )

                    MetricGauge(
                        label: temperatureLabel,
                        value: service.snapshot.temperatureCelsius,
                        display: temperatureDisplay,
                        fraction: temperatureFraction,
                        tint: temperatureTint
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Пусто на моделях без вентилятора — блок просто не рисуется,
                // карточка не оставляет под него дыру.
                if !service.snapshot.fans.isEmpty {
                    VStack(spacing: 3) {
                        ForEach(service.snapshot.fans) { fan in
                            FanControlRow(fan: fan) { percent in
                                service.setFanOverride(index: fan.index, percent: percent)
                            }
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Форматирование

    private func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private func fraction(_ value: Double?) -> Double {
        guard let value else { return 0 }
        return min(max(value / 100, 0), 1)
    }

    /// Цвет по нагрузке: до 60% спокойный, дальше жёлтый, за 85% красный.
    private func load(_ value: Double?) -> Color {
        guard let value else { return .notchTertiary }
        switch value {
        case ..<60: return .green
        case ..<85: return .yellow
        default: return .red
        }
    }

    private var temperatureLabel: String {
        service.snapshot.temperatureCelsius == nil ? T("metrics.heat", "Нагрев") : "°C"
    }

    /// Без градусов показываем публичный уровень теплового давления:
    /// приватный API мог не отработать, но совсем без сведений оставлять нельзя.
    private var temperatureDisplay: String {
        if let celsius = service.snapshot.temperatureCelsius {
            return "\(Int(celsius.rounded()))"
        }
        return service.snapshot.thermalPressure.localizedTitle
    }

    /// Шкала от 30 до 100 °C: ниже тридцати не бывает, выше ста — уже пожар.
    private var temperatureFraction: Double {
        guard let celsius = service.snapshot.temperatureCelsius else {
            switch service.snapshot.thermalPressure {
            case .nominal: return 0.25
            case .fair: return 0.5
            case .serious: return 0.75
            case .critical: return 1
            }
        }
        return min(max((celsius - 30) / 70, 0), 1)
    }

    private var temperatureTint: Color {
        if let celsius = service.snapshot.temperatureCelsius {
            switch celsius {
            case ..<70: return .green
            case ..<90: return .yellow
            default: return .red
            }
        }
        switch service.snapshot.thermalPressure {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious, .critical: return .red
        }
    }
}

/// Один показатель: число, подпись и полоска заполнения.
///
/// Первое появление настоящего значения (после `nil` — виджет только что
/// раскрылся, замер ещё не подоспел) полоска сперва «разгоняет» до упора,
/// как самопроверка тахометра при запуске машины, и только потом
/// подстраивается под настоящую цифру — чисто декоративный штрих, чтобы
/// открытие виджета не выглядело так, будто он молча ждёт данных.
private struct MetricGauge: View {
    let label: String
    let value: Double?
    let display: String
    let fraction: Double
    let tint: Color

    @State private var animatedFraction: Double = 0
    @State private var hasPlayedIntro = false

    var body: some View {
        VStack(spacing: 4) {
            Text(display)
                .font(.system(size: value == nil ? 10 : 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? Color.notchSecondary : Color.notchPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 16)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.4), value: display)

            Capsule()
                .fill(Color.notchStroke)
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(tint)
                            .frame(width: geometry.size.width * animatedFraction)
                    }
                }
                .clipShape(Capsule())

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Color.notchSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .onAppear { updateAnimatedFraction() }
        .onChange(of: value) { _, _ in updateAnimatedFraction() }
    }

    private func updateAnimatedFraction() {
        guard value != nil else { return }
        guard !hasPlayedIntro else {
            withAnimation(.easeOut(duration: 0.4)) { animatedFraction = fraction }
            return
        }
        hasPlayedIntro = true
        withAnimation(.easeIn(duration: 0.35)) { animatedFraction = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeOut(duration: 0.5)) { animatedFraction = fraction }
        }
    }
}
