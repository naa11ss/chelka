import AppKit
import SwiftUI
import ChelkaCore

/// Ловит горизонтальный свайв двумя пальцами и превращает его в решение
/// «следующий/предыдущий» через `TrackSwipeGesture`.
///
/// Ставится в `.background()` карточки музыки, а не поверх нёе: SwiftUI
/// кладёт `.background()` за содержимым по глубине, поэтому клики по кнопкам
/// play/pause/next/prev, лежащим в `.content`, долетают до них первыми,
/// а этот вид получает scrollWheel только там, где под курсором нет
/// интерактивного элемента SwiftUI.
struct TrackSwipeCatcher: NSViewRepresentable {
    let onSwipe: (SwipeDirection) -> Void

    func makeNSView(context: Context) -> SwipeCatcherView {
        let view = SwipeCatcherView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: SwipeCatcherView, context: Context) {
        nsView.onSwipe = onSwipe
    }
}

final class SwipeCatcherView: NSView {
    var onSwipe: ((SwipeDirection) -> Void)?
    private var gesture = TrackSwipeGesture()

    override func scrollWheel(with event: NSEvent) {
        Log.media.debug(
            "своп: событие получено, phase=\(event.phase.rawValue, privacy: .public) momentum=\(event.momentumPhase.rawValue, privacy: .public) dx=\(event.scrollingDeltaX, format: .fixed(precision: 1)) dy=\(event.scrollingDeltaY, format: .fixed(precision: 1))"
        )

        // event.phase пуст у чисто инерционных событий после отрыва пальцев —
        // их отбрасываем целиком, иначе инерция долистывала бы ещё на трек-два
        // сверх того, что реально сделали пальцы.
        guard event.phase != [] else {
            Log.media.debug("своп: пропущено — пустая фаза (инерция)")
            return
        }

        switch event.phase {
        case .began:
            gesture.began()
            Log.media.debug("своп: began")

        case .changed:
            // Жест обязан быть явно горизонтальным — иначе обычная
            // вертикальная прокрутка над карточкой перелистывала бы трек.
            guard abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) else {
                Log.media.debug("своп: не горизонтально, пропускаю дальше")
                super.scrollWheel(with: event)
                return
            }
            if let direction = gesture.changed(deltaX: event.scrollingDeltaX) {
                Log.media.info("своп: сработало направление \(String(describing: direction), privacy: .public)")
                onSwipe?(direction)
            }

        case .ended, .cancelled:
            gesture.ended()
            Log.media.debug("своп: ended")

        default:
            super.scrollWheel(with: event)
        }
    }
}
