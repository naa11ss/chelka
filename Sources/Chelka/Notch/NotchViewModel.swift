import AppKit
import Combine
import ChelkaCore

/// Всё, что нужно знать SwiftUI-слою. Контроллер пишет — вид читает.
final class NotchViewModel: ObservableObject {
    @Published var state: NotchState = .collapsed
    @Published var layout: NotchLayout

    init(layout: NotchLayout) {
        self.layout = layout
    }
}
