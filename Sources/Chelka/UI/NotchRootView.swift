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
    /// в нём заряд и сеть незачем. Плашка рисуется по центру под вырезом,
    /// а не по обе стороны от него: раскладывать содержимое вокруг
    /// физического выреза значит привязаться к его ширине на конкретной
    /// модели, а она разная (168 pt на Air, 209 pt на Pro).
    @ViewBuilder
    private var eventPill: some View {
        if model.state == .collapsed, let event = events.current {
            let anchor = model.layout.collapsedRectInSwiftUI

            HStack(spacing: 5) {
                Image(systemName: event.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(event.title)
                    .font(.system(size: 10, weight: .medium))
                if let detail = event.detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.notchPrimary)
                }
            }
            .foregroundStyle(Color.notchSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.notchSurface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.notchStroke, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            .fixedSize()
            // По центру выреза и чуть ниже него — в пустую середину
            // меню-бара, ту же, куда свисает зона наведения.
            .frame(width: model.layout.panelFrame.width, alignment: .center)
            .offset(y: anchor.maxY + 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(NotchAnimation.morph, value: event.id)
        }
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
