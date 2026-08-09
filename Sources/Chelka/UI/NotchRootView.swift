import SwiftUI
import ChelkaCore

/// Корневой вид панели.
///
/// Панель всегда одного размера, а виджет внутри неё позиционируется вручную
/// по раскладке. Так анимация идёт по слоям SwiftUI, а окно не двигается —
/// изменение фрейма `NSWindow` в такт анимации даёт рывки.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Прозрачная подложка на всю панель: клики сквозь неё
            // отсекает PassThroughContentView.
            Color.clear

            surface
                .frame(width: surfaceRect.width, height: surfaceRect.height)
                .offset(x: surfaceRect.minX, y: surfaceRect.minY)
        }
        .frame(
            width: model.layout.panelFrame.width,
            height: model.layout.panelFrame.height,
            alignment: .topLeading
        )
        .ignoresSafeArea()
    }

    // MARK: - Слои

    @ViewBuilder
    private var surface: some View {
        switch (model.layout.kind, model.state) {
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
                    ExpandedContentView()
                        .padding(.horizontal, DS.flare + DS.contentPadding)
                        .padding(.top, DS.contentPadding * 0.7)
                        .padding(.bottom, DS.contentPadding)
                        .transition(.opacity)
                }
            }
            .shadow(color: .black.opacity(model.state == .expanded ? 0.28 : 0), radius: 18, y: 8)
            // В свёрнутом виде на экране с вырезом виджет не рисуется вовсе —
            // сам вырез и есть его свёрнутое состояние.
            .opacity(model.state == .expanded ? 1 : 0)
    }

    // MARK: - Геометрия

    /// Прямоугольник поверхности в координатах SwiftUI, с полями под завороты.
    private var surfaceRect: CGRect {
        let base = model.state == .expanded
            ? model.layout.expandedRectInSwiftUI
            : model.layout.collapsedRectInSwiftUI

        guard model.layout.kind == .hardware || model.state == .expanded else {
            return base
        }
        return base.insetBy(dx: -DS.flare, dy: 0)
    }
}
