import AppKit
import Combine
import SwiftUI
import ChelkaCore

/// Связывает экран, окно, курсор и состояние виджета.
///
/// Единственное место, где встречаются AppKit и машина состояний.
/// Вся логика решений живёт в `HoverStateMachine`, здесь только доставка
/// событий и применение результата к окну.
@MainActor
final class NotchController {
    private let theme: ThemeController
    private let hoverMonitor = HoverMonitor()

    private var stateMachine = HoverStateMachine()
    private var viewModel: NotchViewModel
    private var panel: NotchPanel?
    private var contentView: PassThroughContentView?
    private var hostingView: NSHostingView<NotchRootView>?

    /// Тикает только пока есть отложенный переход. В покое таймеров нет.
    private var pendingTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var screenChangeDebounce: DispatchWorkItem?

    private var layout: NotchLayout

    init(theme: ThemeController) {
        self.theme = theme
        let metrics = NSScreen.chelkaTarget?.chelkaMetrics ?? Self.fallbackMetrics
        self.layout = NotchGeometry.layout(for: metrics)
        self.viewModel = NotchViewModel(layout: layout)
    }

    // MARK: - Жизненный цикл

    func start() {
        buildPanel()
        applyTheme()

        hoverMonitor.onMove = { [weak self] point in
            self?.handleMouseMoved(to: point)
        }
        hoverMonitor.start()

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.scheduleScreenRebuild() }
            .store(in: &cancellables)

        theme.$theme
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyTheme() }
            .store(in: &cancellables)

        Log.notch.info("виджет запущен, тип выреза: \(String(describing: self.layout.kind), privacy: .public)")
    }

    func stop() {
        hoverMonitor.stop()
        pendingTimer?.invalidate()
        pendingTimer = nil
        screenChangeDebounce?.cancel()
        panel?.orderOut(nil)
    }

    /// Пункт меню «Показать виджет» — раскрывает и закрепляет,
    /// повторный вызов снимает закрепление.
    func toggleFromMenu() {
        if stateMachine.isPinned {
            stateMachine.unpin(inside: isCursorInside(NSEvent.mouseLocation), now: MonotonicClock.now)
        } else {
            stateMachine.pinOpen()
        }
        applyState(animated: true)
    }

    // MARK: - Окно

    private func buildPanel() {
        let panel = NotchPanel(contentRect: layout.panelFrame)

        let container = PassThroughContentView(frame: CGRect(origin: .zero, size: layout.panelFrame.size))
        container.autoresizingMask = [.width, .height]

        let root = NotchRootView(model: viewModel)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        // Иначе SwiftUI подкладывает непрозрачный фон и панель становится белым прямоугольником.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        container.addSubview(hosting)
        panel.contentView = container

        self.panel = panel
        self.contentView = container
        self.hostingView = hosting

        applyLayoutToPanel()
        panel.orderFrontRegardless()
    }

    private func applyLayoutToPanel() {
        guard let panel, let contentView else { return }

        panel.setFrame(layout.panelFrame, display: true)
        contentView.frame = CGRect(origin: .zero, size: layout.panelFrame.size)
        hostingView?.frame = contentView.bounds

        viewModel.layout = layout
        updateInteractiveRect()
    }

    /// Зона, принимающая клики, зависит от состояния: в свёрнутом виде это
    /// только вырез, в раскрытом — вся панель виджета.
    private func updateInteractiveRect() {
        guard let contentView else { return }
        let rect = stateMachine.state == .expanded
            ? layout.expandedRectInView.union(layout.hoverRectInView)
            : layout.hoverRectInView
        contentView.interactiveRect = rect
    }

    private func applyTheme() {
        panel?.appearance = theme.appearance
    }

    // MARK: - Курсор и состояние

    private func handleMouseMoved(to point: NSPoint) {
        let inside = isCursorInside(point)
        let previous = stateMachine.state
        let next = stateMachine.update(inside: inside, now: MonotonicClock.now)

        if next != previous {
            applyState(animated: true)
        }
        syncPendingTimer()
    }

    /// В раскрытом виде «внутри» — это ещё и вся панель виджета,
    /// иначе курсор, спустившийся к содержимому, сворачивал бы его.
    private func isCursorInside(_ point: NSPoint) -> Bool {
        if stateMachine.state == .expanded {
            return layout.hoverRectScreen.contains(point) || layout.expandedRectScreen.contains(point)
        }
        return layout.hoverRectScreen.contains(point)
    }

    /// Таймер нужен только чтобы досчитать задержку, когда курсор замер.
    /// Как только переход разрешился — таймер умирает.
    private func syncPendingTimer() {
        if stateMachine.hasPendingTransition {
            guard pendingTimer == nil else { return }
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let previous = self.stateMachine.state
                    let next = self.stateMachine.update(inside: self.isCursorInside(NSEvent.mouseLocation), now: MonotonicClock.now)
                    if next != previous { self.applyState(animated: true) }
                    self.syncPendingTimer()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            pendingTimer = timer
        } else {
            pendingTimer?.invalidate()
            pendingTimer = nil
        }
    }

    private func applyState(animated: Bool) {
        updateInteractiveRect()

        if animated {
            withAnimation(NotchAnimation.morph) {
                viewModel.state = stateMachine.state
            }
        } else {
            viewModel.state = stateMachine.state
        }
    }

    // MARK: - Смена конфигурации экранов

    /// Подключение монитора генерирует пачку уведомлений подряд —
    /// пересобираем один раз, когда поток утих.
    private func scheduleScreenRebuild() {
        screenChangeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rebuildForCurrentScreens() }
        }
        screenChangeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func rebuildForCurrentScreens() {
        let metrics = NSScreen.chelkaTarget?.chelkaMetrics ?? Self.fallbackMetrics
        let newLayout = NotchGeometry.layout(for: metrics)
        guard newLayout != layout else { return }

        Log.notch.info("конфигурация экранов изменилась, пересобираю раскладку")
        layout = newLayout
        stateMachine.forceCollapse()
        applyLayoutToPanel()
        applyState(animated: false)
        panel?.orderFrontRegardless()
    }

    private static let fallbackMetrics = ScreenMetrics(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        safeAreaTop: 0,
        auxiliaryLeftWidth: nil,
        auxiliaryRightWidth: nil,
        menuBarHeight: 24
    )
}
