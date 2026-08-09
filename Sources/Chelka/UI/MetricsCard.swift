import SwiftUI
import ChelkaCore

/// Карточка состояния системы: загрузка процессора, память, температура.
struct MetricsCard: View {
    @ObservedObject var service: MetricsService

    var body: some View {
        Card(title: "Система", systemImage: "gauge.medium", stage: nil) {
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
        service.snapshot.temperatureCelsius == nil ? "Нагрев" : "°C"
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
private struct MetricGauge: View {
    let label: String
    let value: Double?
    let display: String
    let fraction: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(display)
                .font(.system(size: value == nil ? 10 : 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == nil ? Color.notchSecondary : Color.notchPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(height: 16)

            Capsule()
                .fill(Color.notchStroke)
                .frame(height: 3)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(tint)
                            .frame(width: geometry.size.width * fraction)
                    }
                }
                .clipShape(Capsule())

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Color.notchSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.4), value: fraction)
    }
}
