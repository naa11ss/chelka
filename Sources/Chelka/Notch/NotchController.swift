import AppKit
import Carbon.HIToolbox
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
    private let widgetSize: WidgetSizeController
    private let hoverMonitor = HoverMonitor()
    private var mouseButtonMonitor: Any?

    /// Пока зажата кнопка мыши — окно, поймавшее `mouseDown`, обязано
    /// доиграть жест до `mouseUp`, что бы курсор ни делал в промежутке.
    /// Без этого флага перетаскивание тонкого регулятора вентилятора
    /// (5pt высотой) обрывалось на первом же вертикальном дрожании:
    /// `updateMousePassThrough` реагирует на каждый `leftMouseDragged` —
    /// см. `HoverMonitor` — и выставляет `ignoresMouseEvents = true`,
    /// как только точка на миллиметр выходит за `expandedRectScreen`,
    /// а SwiftUI `DragGesture` после этого просто не получает продолжения:
    /// клик (без промежуточных `leftMouseDragged`) эту цепочку не задевает
    /// и поэтому всегда работал, а протяжка — нет.
    ///
    /// Есть случай, когда `mouseUp` до этого монитора вообще не доходит:
    /// перетаскивание записи буфера наружу (`.onDrag` в `ClipboardCardView`)
    /// запускает настоящую `NSDraggingSession` — как только порог перетаскивания
    /// пройден, менеджер перетаскивания забирает событие себе, и завершающий
    /// `mouseUp` уходит источнику как `NSDraggingSource`, а не как обычное
    /// `NSEvent` через `sendEvent:`. Без страховки `isMouseButtonDown` застрял
    /// бы в `true` навсегда после первого же вытаскивания записи из буфера —
    /// `mouseButtonDownWatchdog` снимает его сам, если `mouseUp` не пришёл
    /// за разумное время.
    private var isMouseButtonDown = false
    private var mouseButtonDownWatchdog: DispatchWorkItem?
    private static let mouseButtonDownWatchdogDelay: TimeInterval = 2

    private var stateMachine = HoverStateMachine()
    private var viewModel: NotchViewModel
    private var panel: NotchPanel?
    private var contentView: PassThroughContentView?
    private var hostingView: NSHostingView<NotchRootView>?

    /// Тикает только пока есть отложенный переход. В покое таймеров нет.
    private var pendingTimer: Timer?

    /// Пересчитывает пропуск кликов, пока виджет раскрыт.
    ///
    /// `HoverMonitor` знает о курсоре только из событий движения, а во время
    /// перетаскивания файла из Finder система ведёт свой сеанс, и события
    /// эти до нас могут не доходить вовсе. Тогда `ignoresMouseEvents`
    /// остаётся с последнего известного положения — то есть «панель
    /// прозрачна для мыши», — и до виджета не долетает не только клик,
    /// но и перетаскивание: окно, прозрачное для мыши, не может быть
    /// приёмником файла. Опрос `NSEvent.mouseLocation` работает независимо
    /// от событий и это чинит.
    private var passThroughPollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var screenChangeDebounce: DispatchWorkItem?

    /// Временные сочетания «1…9» и Esc, живущие только пока виджет
    /// открыт хоткеем. Регистрировать их постоянно нельзя — цифры
    /// перестали бы набираться во всей системе.
    private var quickPickHotkeys: [UInt32] = []
    /// Закреплённое раскрытие само закрывается: забытый открытым виджет
    /// не должен вечно перехватывать цифры.
    private var pinnedAutoCloseTimer: Timer?
    private static let pinnedAutoCloseDelay: TimeInterval = 15

    private var layout: NotchLayout

    /// Источник позиции курсора. Подменяется в сценарных прогонах:
    /// синтезировать настоящие события мыши нельзя без разрешения
    /// «Универсальный доступ», а таймер дозревания обязан опрашивать
    /// ту же позицию, что и обработчик событий — иначе они спорят.
    var cursorProvider: () -> NSPoint = { NSEvent.mouseLocation }

    /// Где стоит значок в меню-баре. На экранах без выреза виджет
    /// открывается от него: пользователь сам решил, где ему быть,
    /// и искать середину верхней кромки не должен.
    var anchorProvider: () -> CGRect? = { nil }

    private let clipboard: ClipboardService
    private let files: FileShelfService
    private let metrics: MetricsService
    private let music: MusicService
    private let devices: DeviceBatteryReader
    private let calendar: CalendarService
    private let events: SystemEventMonitor

    init(
        theme: ThemeController,
        widgetSize: WidgetSizeController,
        clipboard: ClipboardService,
        files: FileShelfService,
        metrics: MetricsService,
        music: MusicService,
        devices: DeviceBatteryReader,
        calendar: CalendarService,
        events: SystemEventMonitor
    ) {
        self.theme = theme
        self.widgetSize = widgetSize
        self.clipboard = clipboard
        self.files = files
        self.metrics = metrics
        self.music = music
        self.devices = devices
        self.calendar = calendar
        self.events = events
        let screenMetrics = NSScreen.chelkaTarget?.chelkaMetrics ?? Self.fallbackMetrics
        self.layout = NotchGeometry.layout(for: screenMetrics, metrics: widgetSize.metrics)
        self.viewModel = NotchViewModel(layout: layout)
    }

    // MARK: - Жизненный цикл

    func start() {
        layout = computeLayout()
        buildPanel()
        applyTheme()

        hoverMonitor.onMove = { [weak self] point in
            self?.handleMouseMoved(to: point)
        }
        hoverMonitor.start()

        // Локальный монитор: если панель получила mouseDown, она уже
        // приняла решение принимать события — держим его до mouseUp
        // независимо от того, что покажет курсор в промежутке.
        mouseButtonMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                self.isMouseButtonDown = true
                self.mouseButtonDownWatchdog?.cancel()
                let watchdog = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.isMouseButtonDown = false
                    self.updateMousePassThrough(for: self.cursorProvider())
                }
                self.mouseButtonDownWatchdog = watchdog
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.mouseButtonDownWatchdogDelay, execute: watchdog)
            case .leftMouseUp, .rightMouseUp, .otherMouseUp:
                self.mouseButtonDownWatchdog?.cancel()
                self.mouseButtonDownWatchdog = nil
                self.isMouseButtonDown = false
                self.updateMousePassThrough(for: self.cursorProvider())
            default:
                break
            }
            return event
        }

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.scheduleScreenRebuild() }
            .store(in: &cancellables)

        theme.$theme
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyTheme() }
            .store(in: &cancellables)

        widgetSize.$scale
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildForSizeChange() }
            .store(in: &cancellables)

        clipboard.$selectedIDs
            .receive(on: RunLoop.main)
            .sink { [weak self] ids in self?.updateSelectionHotkeys(hasSelection: !ids.isEmpty) }
            .store(in: &cancellables)

        clipboard.$canUndo
            .receive(on: RunLoop.main)
            .sink { [weak self] canUndo in self?.updateUndoHotkey(canUndo: canUndo) }
            .store(in: &cancellables)

        // Курсор может уже стоять на вырезе к моменту запуска — событий движения
        // тогда не будет, и виджет остался бы свёрнутым до первого шевеления мышью.
        handleMouseMoved(to: cursorProvider())

        Log.notch.info("виджет запущен, тип выреза: \(String(describing: self.layout.kind), privacy: .public)")
    }

    func stop() {
        metrics.stopSampling()
        music.stopPolling()
        unregisterQuickPickHotkeys()
        unregisterSelectionHotkeys()
        updateUndoHotkey(canUndo: false)
        pinnedAutoCloseTimer?.invalidate()
        hoverMonitor.stop()
        if let mouseButtonMonitor {
            NSEvent.removeMonitor(mouseButtonMonitor)
            self.mouseButtonMonitor = nil
        }
        pendingTimer?.invalidate()
        pendingTimer = nil
        stopPassThroughPoll()
        screenChangeDebounce?.cancel()
        panel?.orderOut(nil)
    }

    /// Пункт меню «Показать виджет» — раскрывает и закрепляет,
    /// повторный вызов снимает закрепление.
    func toggleFromMenu() {
        if stateMachine.isPinned {
            closePinned()
        } else {
            openPinned()
        }
    }

    /// Открытие по глобальному сочетанию: раскрываем, закрепляем
    /// и включаем выбор записи цифрами.
    func openPinned() {
        guard !stateMachine.isPinned else { return }

        stateMachine.pinOpen()
        applyState(animated: true)
        registerQuickPickHotkeys()
        scheduleAutoClose()

        Log.notch.info("виджет открыт хоткеем")
    }

    func closePinned() {
        unregisterQuickPickHotkeys()
        pinnedAutoCloseTimer?.invalidate()
        pinnedAutoCloseTimer = nil

        stateMachine.unpin(inside: isCursorInside(cursorProvider()), now: MonotonicClock.now)
        if !isCursorInside(cursorProvider()) {
            stateMachine.forceCollapse()
        }
        applyState(animated: true)
    }

    // MARK: - Быстрый выбор с клавиатуры

    /// Раскладка цифрового ряда в кодах клавиш: порядок не совпадает
    /// с числовым, 6 и 7 идут не подряд.
    private static let digitKeyCodes: [UInt32] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    private func registerQuickPickHotkeys() {
        unregisterQuickPickHotkeys()

        for (index, keyCode) in Self.digitKeyCodes.enumerated() {
            let binding = HotkeyCenter.Binding(keyCode: keyCode, modifiers: 0)
            let id = HotkeyCenter.shared.register(binding, action: { [weak self] in
                self?.pickItem(at: index)
            })
            if let id { quickPickHotkeys.append(id) }
        }

        // Escape закрывает.
        let escape = HotkeyCenter.Binding(keyCode: 53, modifiers: 0)
        let escapeID = HotkeyCenter.shared.register(escape, action: { [weak self] in
            self?.closePinned()
        })
        if let escapeID { quickPickHotkeys.append(escapeID) }
    }

    private func unregisterQuickPickHotkeys() {
        for id in quickPickHotkeys { HotkeyCenter.shared.unregister(id) }
        quickPickHotkeys.removeAll()
    }

    // MARK: - Пакетное удаление и отмена (Cmd+клик по записям буфера)

    /// Delete/⌫ глобально перехватывают клавишу, которую использует весь
    /// остальной интерфейс системы — риск настоящий (клик мимо виджета,
    /// Delete в Finder попадёт сюда, если выбор не сброшен), поэтому
    /// регистрация живёт ровно пока выбор не пуст, а не постоянно, и
    /// `applyState` сбрасывает выбор сразу при сворачивании виджета —
    /// та же страховка, ради которой просили Cmd+Z с отложенным удалением.
    private var selectionHotkeys: [UInt32] = []
    private var undoHotkeyID: UInt32?

    private func updateSelectionHotkeys(hasSelection: Bool) {
        guard hasSelection != !selectionHotkeys.isEmpty else { return }
        if hasSelection {
            let bindings = [
                HotkeyCenter.Binding(keyCode: UInt32(kVK_Delete), modifiers: 0),
                HotkeyCenter.Binding(keyCode: UInt32(kVK_ForwardDelete), modifiers: 0),
            ]
            for binding in bindings {
                if let id = HotkeyCenter.shared.register(binding, action: { [weak self] in
                    self?.clipboard.removeSelected()
                }) {
                    selectionHotkeys.append(id)
                }
            }
        } else {
            unregisterSelectionHotkeys()
        }
    }

    private func unregisterSelectionHotkeys() {
        for id in selectionHotkeys { HotkeyCenter.shared.unregister(id) }
        selectionHotkeys.removeAll()
    }

    private func updateUndoHotkey(canUndo: Bool) {
        guard canUndo != (undoHotkeyID != nil) else { return }
        if canUndo {
            let binding = HotkeyCenter.Binding(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey))
            undoHotkeyID = HotkeyCenter.shared.register(binding) { [weak self] in
                self?.clipboard.undoLastDeletion()
            }
        } else if let id = undoHotkeyID {
            HotkeyCenter.shared.unregister(id)
            undoHotkeyID = nil
        }
    }

    private func pickItem(at index: Int) {
        let items = clipboard.history.items
        guard index < items.count else { return }

        clipboard.copyToPasteboard(id: items[index].id)
        closePinned()
    }

    /// См. комментарий у `passThroughPollTimer`: пока виджет раскрыт,
    /// состояние пропуска кликов пересчитывается по реальному положению
    /// курсора, а не только по приходящим событиям движения.
    private func startPassThroughPoll() {
        guard passThroughPollTimer == nil else { return }

        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateMousePassThrough(for: self.cursorProvider())
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        passThroughPollTimer = timer
    }

    private func stopPassThroughPoll() {
        passThroughPollTimer?.invalidate()
        passThroughPollTimer = nil
    }

    private func scheduleAutoClose() {
        pinnedAutoCloseTimer?.invalidate()

        let timer = Timer(timeInterval: Self.pinnedAutoCloseDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePinned() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pinnedAutoCloseTimer = timer
    }

    // MARK: - Окно

    private func buildPanel() {
        let panel = NotchPanel(contentRect: layout.panelFrame)

        let container = PassThroughContentView(frame: CGRect(origin: .zero, size: layout.panelFrame.size))
        container.autoresizingMask = [.width, .height]

        // Приём файлов — на уровне AppKit: SwiftUI-drop внутри хостинга
        // в borderless nonactivatingPanel до вида проверенно не доходил.
        container.onFileDrop = { [weak self] urls in
            self?.files.add(urls: urls)
        }
        container.onDragTargetingChange = { [weak self] targeted in
            self?.files.setDragTargeted(targeted)
        }

        let root = NotchRootView(model: viewModel, clipboard: clipboard, files: files, metrics: metrics, music: music, devices: devices, calendar: calendar, events: events)
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

        // До первого движения мыши окно не должно перехватывать ничего.
        panel.ignoresMouseEvents = true

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
        updateMousePassThrough(for: cursorProvider())
    }

    /// Пропускает клики сквозь окно, когда курсор не над самим виджетом.
    ///
    /// Отсечь событие в `hitTest` вида недостаточно: окно всё равно считает
    /// клик своим, и до приложения под ним он не доходит. Пока виджет свёрнут,
    /// панель занимает 768×296 точек поверх всех окон — без этого в верхней
    /// части экрана просто нельзя было ничего нажать.
    private func updateMousePassThrough(for point: NSPoint) {
        guard let panel else { return }

        let shouldReceiveClicks = isCursorOverWidget(point)
        // Начинать пропускать клики посреди зажатой кнопки нельзя — это
        // и есть тот обрыв протяжки, см. комментарий у `isMouseButtonDown`.
        // Разрешить событиям снова доходить до окна — можно всегда,
        // опасна только противоположная сторона переключателя.
        if isMouseButtonDown && !shouldReceiveClicks { return }
        if panel.ignoresMouseEvents == shouldReceiveClicks {
            panel.ignoresMouseEvents = !shouldReceiveClicks
        }
    }

    /// Курсор над видимым телом виджета, а не просто внутри окна-панели.
    private func isCursorOverWidget(_ point: NSPoint) -> Bool {
        switch stateMachine.state {
        case .expanded:
            return visibleExpandedRectScreen.contains(point)
        case .collapsed:
            // Свёрнутый виджет на экране с вырезом не нарисован вовсе,
            // на экране без выреза — кругляш, но и он открывается наведением.
            return false
        }
    }

    /// `NotchRootView.surfaceRect` рисует раскрытую поверхность шире
    /// `expandedRectScreen` на `DS.flare` по горизонтали — под скруглённые
    /// "уши" виджета. Без этого поправки курсор, ушедший за узкий
    /// `expandedRectScreen`, но всё ещё над нарисованным телом виджета,
    /// сворачивал бы его раньше времени — видимая граница и та, что решает
    /// «внутри/снаружи», не совпадали.
    private var visibleExpandedRectScreen: CGRect {
        layout.expandedRectScreen.insetBy(dx: -DS.flare, dy: 0)
    }

    private func applyTheme() {
        panel?.appearance = theme.appearance
    }

    // MARK: - Курсор и состояние

    /// Подача позиции курсора в обход системы — для сценарных проверок
    /// (`--hover-demo`). Синтезировать настоящие события мыши нельзя без
    /// разрешения «Универсальный доступ», а проверять связку надо.
    func simulateCursor(at point: NSPoint) {
        handleMouseMoved(to: point)
    }

    /// Текущее состояние — для проверок и отладки.
    var currentState: NotchState { stateMachine.state }

    /// Раскладка на текущем экране.
    var currentLayout: NotchLayout { layout }

    /// Пропускает ли окно клики насквозь прямо сейчас.
    var panelIgnoresMouseEvents: Bool { panel?.ignoresMouseEvents ?? true }

    private func computeLayout() -> NotchLayout {
        let screenMetrics = NSScreen.chelkaTarget?.chelkaMetrics ?? Self.fallbackMetrics
        return NotchGeometry.layout(for: screenMetrics, metrics: widgetSize.metrics, anchor: anchorProvider())
    }

    /// Пользователь подвинул ползунок размера в настройках — пересобираем
    /// раскладку немедленно, тем же путём, что при смене экранов, только
    /// без дебаунса: это разовое действие, а не пачка системных уведомлений.
    private func rebuildForSizeChange() {
        let newLayout = computeLayout()
        guard newLayout != layout else { return }

        layout = newLayout
        applyLayoutToPanel()
        applyState(animated: true)
        panel?.orderFrontRegardless()
    }

    /// Значок в меню-баре ездит, когда соседи появляются и исчезают.
    /// Пересобираем раскладку, только если он действительно уехал.
    private func syncAnchorIfNeeded() {
        guard layout.kind != .hardware else { return }
        guard let anchor = anchorProvider() else { return }

        let current = layout.collapsedRectScreen
        let moved = abs(anchor.minX - current.minX) > 1
            || abs(anchor.minY - current.minY) > 1
            || abs(anchor.width - current.width) > 1

        guard moved else { return }

        let newLayout = computeLayout()
        guard newLayout != layout else { return }

        layout = newLayout
        applyLayoutToPanel()
    }

    private func handleMouseMoved(to point: NSPoint) {
        syncAnchorIfNeeded()
        let inside = isCursorInside(point)
        let previous = stateMachine.state
        let next = stateMachine.update(inside: inside, now: MonotonicClock.now)

        if next != previous {
            applyState(animated: true)
        } else {
            updateMousePassThrough(for: point)
        }
        syncPendingTimer()
    }

    /// В раскрытом виде «внутри» — это вся панель целиком, а не только
    /// видимая поверхность (даже с поправкой на `DS.flare`).
    ///
    /// Держать виджет раскрытым надо щедро: панель уже включает разумный
    /// запас (panelPadding, расширенный под флare) вокруг видимого тела —
    /// курсор, идущий к кнопке у самого края карточки (например, к «закрепить»
    /// на последней видимой записи буфера), не должен читаться как «снаружи»
    /// даже на волосок раньше, чем пользователь успеет кликнуть. Строгая
    /// граница видимой поверхности (`isCursorOverWidget`) для решения
    /// «сворачивать ли» не годится — только для решения «пропускать ли клик»,
    /// где точность обязательна: иначе панель начала бы перехватывать клики,
    /// предназначенные другим приложениям, в невидимой краевой зоне.
    private func isCursorInside(_ point: NSPoint) -> Bool {
        if stateMachine.state == .expanded {
            return layout.panelFrame.contains(point)
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
                    let next = self.stateMachine.update(inside: self.isCursorInside(self.cursorProvider()), now: MonotonicClock.now)
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
        Log.notch.info("состояние: \(String(describing: self.stateMachine.state), privacy: .public)")

        // Метрики опрашиваются только пока виджет виден: в свёрнутом
        // состоянии на них никто не смотрит, а батарею они едят.
        if stateMachine.state == .expanded {
            metrics.startSampling()
            music.startPolling()
            devices.startPolling()
            startPassThroughPoll()
        } else {
            metrics.stopSampling()
            music.stopPolling()
            devices.stopPolling()
            stopPassThroughPoll()
            files.setDragTargeted(false)
            // Выбор записей не должен пережить сворачивание — иначе Delete/⌫
            // и Cmd+Z остаются глобально перехваченными для виджета, который
            // пользователь уже не видит и не собирался трогать.
            clipboard.clearSelection()
        }

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
        let newLayout = computeLayout()
        guard newLayout != layout else { return }

        Log.notch.info("конфигурация экранов изменилась, пересобираю раскладку")
        layout = newLayout

        // Пересборка визуально сворачивает виджет через `forceCollapse()`
        // ниже, но сама по себе не трогает то, что держит закреплённое
        // открытие — глобальные хоткеи 1…9/Esc и таймер автозакрытия.
        // Без этой очистки следующая цифра, набранная где угодно в системе
        // после переподключения монитора, тихо выбирала бы запись из буфера
        // вместо того, чтобы просто напечататься.
        if stateMachine.isPinned {
            unregisterQuickPickHotkeys()
            pinnedAutoCloseTimer?.invalidate()
            pinnedAutoCloseTimer = nil
        }

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
