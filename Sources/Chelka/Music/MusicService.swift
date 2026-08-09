import AppKit
import Combine
import ChelkaCore

/// Что играет и чем управлять.
///
/// Опрос плееров стоит запуска процесса `osascript`, поэтому идёт он редко
/// и только пока виджет раскрыт. Мгновенную реакцию на смену трека даёт
/// не опрос, а рассылка уведомлений, которую плееры шлют сами.
@MainActor
final class MusicService: ObservableObject {

    enum Status: Equatable {
        case idle
        /// Плеер отвечает, всё в порядке.
        case connected
        /// Пользователь запретил управлять приложением.
        case automationDenied(MusicSource)
        /// Ни Music, ни Spotify не запущены: остаются медиа-клавиши.
        case noSupportedPlayer
    }

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var status: Status = .idle

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "com.ivan.chelka.music", qos: .utility)
    private var isQuerying = false

    private let clients = MusicSource.allCases.map { MusicSourceClient(source: $0) }

    var isPolling: Bool { timer != nil }

    // MARK: - Жизненный цикл

    func start() {
        // Плееры сообщают о смене трека сами — это даёт мгновенную реакцию
        // без частого опроса.
        let center = DistributedNotificationCenter.default()
        let names = ["com.apple.iTunes.playerInfo", "com.spotify.client.PlaybackStateChanged"]

        for name in names {
            let observer = center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.append(observer)
        }
    }

    func stop() {
        stopPolling()
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
    }

    func startPolling(interval: TimeInterval = 2.0) {
        guard timer == nil else { return }
        refresh()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }

    // MARK: - Опрос

    func refresh() {
        // Опрос идёт во внешнем процессе и может занять до пары секунд:
        // накладывать один опрос на другой смысла нет.
        guard !isQuerying else { return }
        isQuerying = true

        let clients = self.clients

        queue.async { [weak self] in
            var found: [NowPlaying] = []
            var denied: MusicSource?
            var anyRunning = false

            for client in clients {
                guard client.isRunning else { continue }
                anyRunning = true

                switch client.query() {
                case .success(let playing):
                    if let playing { found.append(playing) }
                case .failure(let failure):
                    if failure == .automationDenied { denied = client.source }
                    Log.media.error("\(client.source.displayName, privacy: .public): \(String(describing: failure), privacy: .public)")
                }
            }

            let best = NowPlayingSelection.best(from: found)

            // Возврат на главный поток через очередь, а не через `Task`:
            // задачи главного актора не выполняются во вложенном цикле
            // событий, а он встречается и в обычной работе — например,
            // пока открыто модальное окно.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(best: best, denied: denied, anyRunning: anyRunning)
                }
            }
        }
    }

    private func apply(best: NowPlaying?, denied: MusicSource?, anyRunning: Bool) {
        defer { isQuerying = false }

        if let denied {
            status = .automationDenied(denied)
        } else if !anyRunning {
            status = .noSupportedPlayer
        } else {
            status = .connected
        }

        let trackChanged = !(best?.isSameTrack(as: nowPlaying) ?? (nowPlaying == nil))
        nowPlaying = best

        if best == nil {
            artwork = nil
        } else if trackChanged {
            loadArtwork(for: best!)
        }
    }

    /// Обложка грузится только при смене трека: у Spotify это сетевой запрос,
    /// у Music — запись файла на диск, каждые две секунды такое не гоняют.
    private func loadArtwork(for playing: NowPlaying) {
        let client = MusicSourceClient(source: playing.source)
        let trackID = playing.trackID

        queue.async { [weak self] in
            let data = client.artwork()

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Пока грузили — трек мог смениться.
                    guard self.nowPlaying?.trackID == trackID else { return }
                    self.artwork = data.flatMap(NSImage.init(data:))
                }
            }
        }
    }

    // MARK: - Управление

    /// Команда уходит тому плееру, который сейчас играет. Если такого нет —
    /// глобальным медиа-клавишам: их слышат браузер и остальные плееры.
    func playPause() { send(.playPause, fallback: MediaKeys.playPause) }
    func next() { send(.next, fallback: MediaKeys.next) }
    func previous() { send(.previous, fallback: MediaKeys.previous) }

    private func send(_ command: MusicSourceClient.Command, fallback: @escaping () -> Bool) {
        let source = nowPlaying?.source

        queue.async { [weak self] in
            var handled = false
            if let source {
                handled = MusicSourceClient(source: source).send(command)
            }
            if !handled {
                _ = fallback()
            }

            // Плеер отвечает на команду не мгновенно.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// Нужны ли пользователю дополнительные разрешения для управления.
    var needsMediaKeyPermission: Bool {
        nowPlaying == nil && !MediaKeys.isAuthorized
    }
}
