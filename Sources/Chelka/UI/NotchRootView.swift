import SwiftUI
import ChelkaCore

/// Корневой вид панели.
///
/// Панель всегда одного размера, а виджет внутри неё позиционируется вручную
/// по раскладке. Так анимация идёт по слоям SwiftUI, а окно не двигается —
/// изменение фрейма `NSWindow` в такт анимации даёт рывки.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @ObservedObject var clipboard: ClipboardService
    @ObservedObject var files: FileShelfService
    @ObservedObject var metrics: MetricsService
    @ObservedObject var music: MusicService
    @ObservedObject var devices: DeviceBatteryReader
    @ObservedObject var calendar: CalendarService
    @ObservedObject var events: SystemEventMonitor

    /// Тикает раз в минуту, пока виджет раскрыт: «идёт сейчас» и «через
    /// сколько» в повестке — про время, и без пересчёта устареют молча.
    @State private var clock = Date()
    private let minuteTicker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Прозрачная подложка на всю панель: клики сквозь неё
            // отсекает PassThroughContentView.
            Color.clear

            surface
                .frame(width: surfaceRect.width, height: surfaceRect.height)
                .offset(x: surfaceRect.minX, y: surfaceRect.minY)

            eventPill
        }
        .frame(
            width: model.layout.panelFrame.width,
            height: model.layout.panelFrame.height,
            alignment: .topLeading
        )
        .ignoresSafeArea()
        .onReceive(minuteTicker) { now in
            // Только пока виджет раскрыт: в свёрнутом состоянии повестку
            // никто не видит, а таймер будил бы процессор впустую.
            guard model.state == .expanded else { return }
            clock = now
        }
    }

    // MARK: - Событие в вырезе

    /// Короткое сообщение под вырезом, пока виджет свёрнут.
    ///
    /// Только в свёрнутом виде: раскрытый виджет и так на экране, дублировать
    /// в нём заряд и сеть незачем.
    ///
    /// Выпадает прямо под вырезом, шириной ровно в вырез — не отдельная
    /// табличка сбоку, а как будто сам вырез ненадолго вытянулся вниз
    /// и показал, что хотел сказать.
    ///
    /// Смонтирована всегда (не только пока свёрнуто): `NotchEventPill` сама
    /// решает, показываться ли, по значению `event`. Так раскрытие виджета
    /// во время показа плашки тоже уезжает обратно в вырез тем же жестом,
    /// а не пропадает без анимации.
    private var eventPill: some View {
        let anchor = model.layout.collapsedRectInSwiftUI
        // На реальном вырезе он и задаёт ширину плашки. На экране без
        // выреза свёрнутый вид — кругляш или совсем пусто, недостаточно
        // широкий для дропдауна, поэтому плашка там не уже 230 pt.
        let width = model.layout.kind == .hardware ? anchor.width : max(anchor.width, 230)

        return NotchEventPill(event: model.state == .collapsed ? events.current : nil)
            .frame(width: width)
            .offset(x: anchor.midX - width / 2, y: anchor.maxY)
    }

    // MARK: - Слои

    @ViewBuilder
    private var surface: some View {
        switch (model.layout.kind, model.state) {
        case (.menuBarItem, .collapsed):
            // Свёрнутый вид — это сам значок в меню-баре, рисовать нечего.
            Color.clear
        case (.synthetic, .collapsed):
            syntheticHandle
        default:
            expandedSurface
        }
    }

    /// Кругляш на экранах без выреза: свёрнутый вид должен быть видимым,
    /// иначе наводить не на что.
    private var syntheticHandle: some View {
        Circle()
            .fill(Color.notchSurface)
            .overlay(Circle().strokeBorder(Color.notchStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .transition(.scale.combined(with: .opacity))
    }

    private var expandedSurface: some View {
        NotchShape(bottomRadius: DS.bottomRadius, flare: DS.flare)
            .fill(Color.notchSurface)
            .overlay {
                NotchShape(bottomRadius: DS.bottomRadius, flare: DS.flare)
                    .stroke(Color.notchStroke, lineWidth: 1)
            }
            .overlay {
                if model.state == .expanded {
                    ExpandedContentView(clipboard: clipboard, files: files, metrics: metrics, music: music, devices: devices, calendar: calendar, clock: clock)
                        .padding(.horizontal, DS.flare + DS.contentPadding)
                        // Верхнюю полосу занимает сам вырез (или меню-бар):
                        // содержимое под ней физически не видно.
                        .padding(.top, topInset)
                        .padding(.bottom, DS.contentPadding)
                        .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(model.state == .expanded ? 0.28 : 0), radius: 18, y: 8)
            // В свёрнутом виде на экране с вырезом виджет не рисуется вовсе —
            // сам вырез и есть его свёрнутое состояние.
            .opacity(model.state == .expanded ? 1 : 0)
    }

    /// Высота непригодной для содержимого полосы сверху.
    private var topInset: CGFloat {
        model.layout.collapsedRectScreen.height + 6
    }

    // MARK: - Геометрия

    /// Прямоугольник поверхности в координатах SwiftUI, с полями под завороты.
    private var surfaceRect: CGRect {
        let base = model.state == .expanded
            ? model.layout.expandedRectInSwiftUI
            : model.layout.collapsedRectInSwiftUI

        guard model.state == .expanded else { return base }
        return base.insetBy(dx: -DS.flare, dy: 0)
    }
}
