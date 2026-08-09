import AppKit
import SwiftUI
import ChelkaCore

/// Карточка музыки: обложка, трек, полоса воспроизведения, управление.
struct MusicCard: View {
    @ObservedObject var service: MusicService

    /// Тикает раз в секунду, чтобы полоска ползла между опросами плеера.
    @State private var clock = MonotonicClock.now

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Card(title: "Музыка", systemImage: "music.note", stage: nil) {
            HStack(spacing: 10) {
                artwork

                VStack(alignment: .leading, spacing: 3) {
                    title
                    subtitle
                    Spacer(minLength: 0)
                    controls
                }

                Spacer(minLength: 0)
            }
        }
        .onReceive(ticker) { _ in clock = MonotonicClock.now }
    }

    // MARK: - Части

    private var artwork: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.notchCard)
            .overlay {
                if let image = service.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.notchTertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .frame(width: 44, height: 44)
    }

    private var title: some View {
        Text(service.nowPlaying?.title ?? placeholderTitle)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(service.nowPlaying == nil ? Color.notchSecondary : Color.notchPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var placeholderTitle: String {
        switch service.status {
        case .automationDenied(let source):
            return "Нет доступа к \(source.displayName)"
        case .noSupportedPlayer:
            return "Ничего не играет"
        default:
            return "Ничего не играет"
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let playing = service.nowPlaying {
            HStack(spacing: 5) {
                Text(playing.artist)
                    .lineLimit(1)
                Text("·")
                Text(TimeFormatting.trackTime(playing.position(at: clock)))
                    .monospacedDigit()
                Text("/")
                Text(TimeFormatting.trackTime(playing.duration))
                    .monospacedDigit()
            }
            .font(.system(size: 9))
            .foregroundStyle(Color.notchSecondary)
        } else {
            Text(hintText)
                .font(.system(size: 9))
                .foregroundStyle(Color.notchTertiary)
                .lineLimit(1)
        }
    }

    private var hintText: String {
        switch service.status {
        case .automationDenied:
            return "Разреши управление в Настройках → Конфиденциальность"
        case .noSupportedPlayer where !MediaKeys.isAuthorized:
            return "Кнопки работают с Music и Spotify"
        default:
            return "Music · Spotify"
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 5) {
            progressBar

            HStack(spacing: 14) {
                controlButton("backward.fill", action: service.previous)
                controlButton(
                    service.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                    action: service.playPause
                )
                controlButton("forward.fill", action: service.next)
            }
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if let playing = service.nowPlaying, playing.duration > 0 {
            Capsule()
                .fill(Color.notchStroke)
                .frame(height: 2)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(Color.notchPrimary.opacity(0.7))
                            .frame(width: geometry.size.width * playing.progress(at: clock))
                    }
                }
                .clipShape(Capsule())
                .animation(.linear(duration: 1), value: playing.progress(at: clock))
        }
    }

    private func controlButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(Color.notchSecondary)
                .contentShape(Rectangle())
                .frame(width: 18, height: 14)
        }
        .buttonStyle(.plain)
    }
}
