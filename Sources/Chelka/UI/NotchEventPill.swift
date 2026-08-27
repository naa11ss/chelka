import SwiftUI
import ChelkaCore

/// Плашка события: выезжает из-под выреза вниз, шириной ровно в вырез —
/// как будто сам вырез ненадолго вытянулся и показал, что хотел сказать,
/// а не отдельная табличка, всплывшая рядом.
///
/// Смонтирована всегда, пока свёрнутый вид виден вообще — сама решает,
/// показываться ли, по тому, пришёл ли `event` не-`nil`. Так появление
/// и исчезновение — один и тот же непрерывный жест (высота растёт из нуля
/// и обратно), а не «появиться transition’ом, исчезнуть без него»: SwiftUI
/// умеет анимировать удаление вида из дерева только с готовой transition,
/// а нужный эффект (расти из-под выреза) описывается проще как внутреннее
/// состояние, которое переживает и появление, и скрытие.
struct NotchEventPill: View {
    let event: SystemEvent?

    /// Последнее непустое событие: рисуем именно его, пока идёт анимация
    /// схлопывания, иначе текст исчез бы мгновенно, а высота ужималась ещё
    /// секунду — несовпадение сразу бросается в глаза.
    @State private var shown: SystemEvent?

    /// Уровень для шкалы «доезжает» после появления, а не рисуется сразу
    /// готовым: заполняющаяся полоска читается как «вот сколько заряда»,
    /// нарисованная — как просто ещё одна деталь оформления.
    @State private var fill: Double = 0
    @State private var iconPulse = false

    /// Высота полностью показанной плашки — измеряется через
    /// `GeometryReader`, а не задаётся числом: шрифт и отступы могут
    /// поменяться, а константа рассинхронизировалась бы с реальным размером.
    @State private var naturalHeight: CGFloat?
    /// Раскрыта ли плашка по высоте. Пока `false`, высота обрезана до нуля.
    @State private var revealed = false
    /// Метка текущего цикла показа/скрытия. Отложенное обнуление `shown`
    /// после скрытия сверяется с ней: если за время задержки успело прийти
    /// новое событие, метка уже другая, и стирать `shown` нельзя — структуры
    /// в SwiftUI копируются по значению, и `self` внутри отложенного
    /// замыкания застыл бы на старом (пустом) `event`, не увидев новый.
    @State private var generation = 0

    var body: some View {
        Group {
            if let shown {
                pill(for: shown)
            } else {
                // Нулевая по умолчанию высота — то, из чего растёт первое
                // появление, и то, во что схлопывается последнее исчезновение.
                Color.clear.frame(height: 0)
            }
        }
        .onAppear {
            // Событие уже могло быть выставлено до монтирования вида
            // (так делают офлайн-снимки интерфейса) — `onChange` в этом
            // случае не сработает, у него ещё нет «предыдущего» значения
            // для сравнения. Синхронизируемся вручную на старте.
            if let event { reveal(event) }
        }
        .onChange(of: event) { _, new in
            if let new {
                reveal(new)
            } else {
                hide()
            }
        }
    }

    private func reveal(_ event: SystemEvent) {
        generation += 1
        shown = event
        naturalHeight = nil
        revealed = false
        // Кадр с нулевой высотой должен успеть отрисоваться до того,
        // как включится анимация роста — иначе первый показ рисуется
        // сразу готовым, без выезда.
        DispatchQueue.main.async {
            // Офлайн-снимки интерфейса (`--snapshot`) рендерят один кадр без
            // работающего display link — анимированная (`withAnimation`)
            // смена состояния так и остаётся на первом кадре перехода,
            // и снимок ловит плашку с нулевой высотой. В этом режиме
            // проставляем финальное значение сразу, без анимации.
            if SnapshotTool.isRendering {
                revealed = true
            } else {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.72)) {
                    revealed = true
                }
            }
        }
        withAnimation(.easeOut(duration: 0.55).delay(0.12)) {
            fill = event.level ?? 0
        }
        iconPulse.toggle()
    }

    private func hide() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) {
            revealed = false
        }
        generation += 1
        let expected = generation
        // Убираем содержимое только после того, как анимация схлопывания
        // успела бы закончиться — раньше он просто исчезнет вместо того,
        // чтобы уехать обратно в вырез.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard generation == expected else { return }
            shown = nil
        }
    }

    @ViewBuilder
    private func pill(for event: SystemEvent) -> some View {
        content(for: event)
            .background {
                GeometryReader { proxy in
                    Color.clear.onAppear { naturalHeight = proxy.size.height }
                }
            }
            .frame(height: revealed ? naturalHeight : 0, alignment: .top)
            .clipped()
            .shadow(color: .black.opacity(revealed ? 0.45 : 0), radius: 12, y: 5)
    }

    private func content(for event: SystemEvent) -> some View {
        HStack(spacing: 8) {
            icon(for: event)

            Text(event.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)

            if let detail = event.detail {
                Text(detail)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint(for: event))
                    .contentTransition(.numericText())
            }

            if event.level != nil {
                gauge(for: event)
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
    }

    private func icon(for event: SystemEvent) -> some View {
        Image(systemName: event.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint(for: event))
            .frame(width: 20, height: 20)
            .background(tint(for: event).opacity(0.22), in: Circle())
            // Один короткий отскок в момент появления — привлекает
            // внимание ровно настолько, чтобы плашку заметили.
            .symbolEffect(.bounce, value: iconPulse)
    }

    private func gauge(for event: SystemEvent) -> some View {
        Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 60, height: 3)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(tint(for: event))
                        .frame(width: geometry.size.width * min(max(fill, 0), 1))
                }
            }
            .clipShape(Capsule())
    }

    /// Смысл цвета приходит из ядра — здесь только перевод в краску.
    private func tint(for event: SystemEvent) -> Color {
        switch event.tint {
        case .neutral: return .notchSecondary
        case .positive: return .green
        case .warning: return .yellow
        case .danger: return .red
        }
    }
}
