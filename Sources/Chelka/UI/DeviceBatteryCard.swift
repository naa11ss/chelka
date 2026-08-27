import SwiftUI
import ChelkaCore

/// Заряд подключённых наушников — по каждому отдельно.
///
/// Карточка рисуется, только когда есть что показать: без подключённых
/// устройств она не занимает место пустой рамкой, а исчезает целиком —
/// см. `ExpandedContentView`.
struct DeviceBatteryCard: View {
    let device: DeviceBattery

    var body: some View {
        Card(title: device.name, systemImage: symbol, stage: nil) {
            if device.isEarbuds {
                HStack(spacing: 0) {
                    level(T("device.left", "Левый"), device.left)
                    level(T("device.right", "Правый"), device.right)
                    level(T("device.case", "Кейс"), device.caseLevel)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let single = device.single {
                level(T("device.charge", "Заряд"), single)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var symbol: String {
        device.isEarbuds ? "airpods.gen3" : "battery.100"
    }

    @ViewBuilder
    private func level(_ label: String, _ percent: Int?) -> some View {
        VStack(spacing: 3) {
            Text(percent.map { "\($0)%" } ?? "—")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(percent == nil ? Color.notchSecondary : tint(percent))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())

            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Color.notchSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    /// Те же пороги, что у событий в вырезе: ниже 20% — тревожно,
    /// ниже 10% — пора искать кейс.
    private func tint(_ percent: Int?) -> Color {
        guard let percent else { return .notchSecondary }
        switch percent {
        case ..<10: return .red
        case ..<20: return .yellow
        default: return .notchPrimary
        }
    }
}
