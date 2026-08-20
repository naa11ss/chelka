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
                .frame(width: 26, alignment: .trailing)
                .contentTransition(.numericText())
                // Во время перетаскивания цифра обязана идти в такт пальцу
                // без задержки — анимация включается только на устоявшихся
                // значениях, иначе живая протяжка ощущалась бы вязкой.
                .animation(dragPercent == nil ? .easeOut(duration: 0.25) : nil, value: displayPercent)

            // Отдельная, всегда видимая и всегда нажимаемая кнопка — раньше
            // возврат к автоматике был спрятан за тапом по самой цифре,
            // да ещё с задержкой в 10с после последнего движения регулятора
            // (чтобы не отменить случайным повторным тапом только что
            // выставленное значение). На практике это ощущалось как «то
            // появляется, то нет» — пользователь не мог предсказать, когда
            // именно жест сработает. Раз это отдельная кнопка на своём
            // месте, а не то же место, где только что тянули за трек,
            // тот риск случайной отмены больше не о том же самом жесте —
            // задержка не нужна.
            Button(action: { onSetOverride(nil) }) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isOverridden ? Color.notchSecondary : Color.notchTertiary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(T("fan.auto", "Авто"))
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
                    }
                    .onEnded { value in
                        let percent = percent(atX: value.location.x, width: geometry.size.width)
                        onSetOverride(percent)
                        dragPercent = nil
                    }
            )
        }
        .frame(height: 5)
        .animation(dragPercent == nil ? .easeOut(duration: 0.15) : nil, value: displayPercent)
    }

    private func percent(atX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0 else { return Self.minimumPercent }
        let fraction = min(max(x / width, 0), 1)
        let raw = Int((fraction * 100).rounded())
        return max(FanPercent.snap(raw), Self.minimumPercent)
    }
}
