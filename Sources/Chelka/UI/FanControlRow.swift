import SwiftUI
import ChelkaCore

/// Регулятор оборотов одного вентилятора: перетаскиваемая полоска
/// в 0…100% с шагом 5, плюс возврат к автоматике прошивки.
///
/// 0% доступен намеренно — у пользователя должен быть полный ручной
/// диапазон. Страховка от перегрева при остановленном вентиляторе —
/// не в этом регуляторе, а в `MetricsService`: она следит за температурой
/// независимо от того, что здесь выставлено, и предупреждает уведомлением,
/// не отбирая у пользователя выбор молча.
struct FanControlRow: View {
    let fan: FanSpeed
    /// `nil` — вернуть автоматике, иначе процент от паспортного диапазона.
    let onSetOverride: (Int?) -> Void

    /// Живое значение во время перетаскивания — до отпускания на SMC
    /// ничего не уходит, чтобы не заваливать контроллер вентилятора
    /// записью на каждый пиксель движения пальца.
    @State private var dragPercent: Int?

    /// Возврат к автоматике тапом по цифре доступен не сразу после
    /// движения регулятора — иначе смахнуть на нужный процент и тут же
    /// случайно попасть по той же цифре означало бы отменить то, что
    /// только что выставили.
    @State private var canTapToAuto = false
    @State private var autoAvailabilityWorkItem: DispatchWorkItem?
    private static let autoAvailabilityDelay: TimeInterval = 10

    private static let minimumPercent = 0

    private var isOverridden: Bool {
        dragPercent != nil || fan.override != .auto
    }

    /// Во время перетаскивания — то, что под пальцем. При активном ручном
    /// режиме — именно запрошенная цель, не то, что успели раскрутить
    /// обороты: у вентилятора есть инерция, разгон до цели занимает
    /// секунду-две, и если в это время показывать текущие обороты вместо
    /// цели, регулятор будет выглядеть так, будто не расслышал команду.
    /// В автоматическом режиме честно показываем, куда прошивка сама
    /// сейчас поставила скорость — там это как раз содержательно.
    private var displayPercent: Int {
        if let dragPercent { return dragPercent }
        if case .percent(let target) = fan.override { return target }
        return fan.currentPercent
    }

    var body: some View {
        if fan.hasKnownRange {
            regulator
        } else {
            // Паспортный диапазон не прочитался (незнакомый на этой модели
            // тип ключа F{i}Mn/F{i}Mx) — крутить нечем, но сам факт, что
            // вентилятор существует и его обороты видны, показать всё
            // равно стоит: это уже полезнее, чем полное молчание.
            readOnlyRow
        }
    }

    private var readOnlyRow: some View {
        HStack(spacing: 5) {
            Image(systemName: "fan")
                .font(.system(size: 8))
                .foregroundStyle(Color.notchTertiary)
                .frame(width: 9)

            Text("\(Int(fan.rpm.rounded())) " + T("fan.rpm", "об/мин"))
                .font(.system(size: 9))
                .foregroundStyle(Color.notchSecondary)

            Spacer(minLength: 0)
        }
        .frame(height: 12)
    }

    private var regulator: some View {
        HStack(spacing: 5) {
            Image(systemName: "fan")
                .font(.system(size: 8))
                .foregroundStyle(isOverridden ? Color.notchPrimary : Color.notchTertiary)
                .frame(width: 9)

            track

            Text(isOverridden ? "\(displayPercent)%" : T("fan.auto", "Авто"))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.notchSecondary)
                .frame(width: 30, alignment: .trailing)
                .contentTransition(.numericText())
                // Во время перетаскивания цифра обязана идти в такт пальцу
                // без задержки — анимация включается только на устоявшихся
                // значениях, иначе живая протяжка ощущалась бы вязкой.
                .animation(dragPercent == nil ? .easeOut(duration: 0.25) : nil, value: displayPercent)
                // Тап по числу — самый быстрый путь назад к автоматике,
                // без отдельной кнопки, отъедающей место в узкой карточке.
                // Доступен не сразу после движения — см. `canTapToAuto`.
                .onTapGesture {
                    guard isOverridden, canTapToAuto else { return }
                    dragPercent = nil
                    onSetOverride(nil)
                }
        }
        .frame(height: 12)
    }

    private var track: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.notchStroke)

                Capsule()
                    .fill(isOverridden ? Color.accentColor : Color.notchTertiary)
                    .frame(width: geometry.size.width * CGFloat(displayPercent) / 100)
            }
            .contentShape(Rectangle())
            .gesture(
                // Без .global здесь: `value.location` уже в координатах
                // этого GeometryReader и не зависит от того, где именно
                // внутри трека началось нажатие — кликнуть можно в любую
                // точку шкалы и сразу тянуть дальше в любую сторону.
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        dragPercent = percent(atX: value.location.x, width: geometry.size.width)
                        scheduleAutoAvailability()
                    }
                    .onEnded { value in
                        let percent = percent(atX: value.location.x, width: geometry.size.width)
                        onSetOverride(percent)
                        dragPercent = nil
                        scheduleAutoAvailability()
                    }
            )
        }
        .frame(height: 5)
        .animation(dragPercent == nil ? .easeOut(duration: 0.15) : nil, value: displayPercent)
    }

    /// Тап по цифре снова начинает отсчёт: 10 секунд простоя регулятора
    /// подряд, не 10 секунд с первого движения жеста.
    private func scheduleAutoAvailability() {
        autoAvailabilityWorkItem?.cancel()
        canTapToAuto = false
        let workItem = DispatchWorkItem { canTapToAuto = true }
        autoAvailabilityWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoAvailabilityDelay, execute: workItem)
    }

    private func percent(atX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return Self.minimumPercent }
        let fraction = min(max(x / width, 0), 1)
        let raw = Int((fraction * 100).rounded())
        return max(FanPercent.snap(raw), Self.minimumPercent)
    }
}
