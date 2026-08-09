import CoreGraphics

public enum SwipeDirection: Sendable, Equatable {
    case next
    case previous
}

/// Превращает поток дельт горизонтального скролла в одно решение
/// «следующий/предыдущий» за жест.
///
/// AppKit присылает десятки мелких дельт за один свайп, плюс инерционные
/// события после отрыва пальцев. Наивное срабатывание на каждой дельте
/// перелистнуло бы через пять треков одним движением; здесь срабатывание
/// одно — на кадре, где накопленное расстояние впервые пересекло порог,
/// всё остальное до конца жеста игнорируется.
public struct TrackSwipeGesture: Sendable, Equatable {
    public var threshold: CGFloat
    private var accumulated: CGFloat = 0
    private var hasFired = false
    private var isTracking = false

    public init(threshold: CGFloat = 60) {
        self.threshold = threshold
    }

    public mutating func began() {
        accumulated = 0
        hasFired = false
        isTracking = true
    }

    /// Палец влево даёт отрицательную дельту при естественной прокрутке —
    /// то же направление, что у «вперёд» в свайпе Safari по истории:
    /// свайп влево пролистывает к следующему, вправо — к предыдущему.
    @discardableResult
    public mutating func changed(deltaX: CGFloat) -> SwipeDirection? {
        guard isTracking, !hasFired else { return nil }
        accumulated += deltaX

        if accumulated <= -threshold {
            hasFired = true
            return .next
        }
        if accumulated >= threshold {
            hasFired = true
            return .previous
        }
        return nil
    }

    public mutating func ended() {
        isTracking = false
    }
}
