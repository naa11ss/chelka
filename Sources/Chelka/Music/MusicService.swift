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
        /// Звук идёт из приложения, которое метаданных не отдаёт —
        /// браузер, видеоплеер, что угодно.
        case externalAudio(AudioSource)
    }

    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var status: Status = .idle
    /// Приложение, выводящее звук, когда метаданных получить неоткуда.
    @Published private(set) var audioSource: AudioSource?

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "com.ivan.chelka.music", qos: .utility)
    private var isQuerying = false

    private let clients = MusicSource.allCases.map { MusicSourceClient(source: $0) }
    private let artworkFetcher = BrowserArtworkFetcher()
    /// Настройки буфера заодно хранят и разрешение ходить в сеть за обложкой.
    private let settings: ClipboardSettings

    init(settings: ClipboardSettings) {
        self.settings = settings
    }

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

            // Метаданных от Music и Spotify может не быть вовсе — тогда
            // смотрим, кто вообще выводит звук. Это работает для браузера,
            // локального видео и любого другого источника.
            var external: AudioSource?
            if best == nil || best?.isPlaying != true {
                external = AudioSourceMonitor.currentSources().first

                if let source = external, BrowserTabTitle.isBrowser(source.bundleID) {
                    // Сначала спрашиваем сам браузер: mediaSession знает
                    // название трека и обложку даже когда воспроизведение
                    // идёт внутри ленты и адрес страницы не меняется.
                    if let media = BrowserMediaSession.read(bundleID: source.bundleID) {
                        external?.detail = [media.title, media.artist]
                            .compactMap { $0 }
                            .joined(separator: " — ")
                        external?.artworkURL = media.artworkURL
                    }

                    // Адрес вкладки нужен независимо от того, дал ли
                    // mediaSession название трека — сайты нередко заполняют
                    // title/artist, но не artwork (обычное дело для многих
                    // стриминговых и подкаст-страниц). Раньше адрес
                    // подтягивался только когда `detail` был пуст целиком,
                    // из-за чего обложка для таких сайтов никогда не
                    // находилась через запасной путь `og:image`, хотя он
                    // и сработал бы. Заголовок вкладки при этом не
                    // затирает уже полученное от mediaSession название.
                    if external?.artworkURL == nil, let tab = BrowserTabTitle.currentTab(for: source.bundleID) {
                        if external?.detail == nil { external?.detail = tab.title }
                        external?.pageURL = tab.url
                    }
                }
            }

            // Возврат на главный поток через очередь, а не через `Task`:
            // задачи главного актора не выполняются во вложенном цикле
            // событий, а он встречается и в обычной работе — например,
            // пока открыто модальное окно.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(best: best, denied: denied, anyRunning: anyRunning, external: external)
                }
            }
        }
    }

    private func apply(best: NowPlaying?, denied: MusicSource?, anyRunning: Bool, external: AudioSource?) {
        defer { isQuerying = false }

        audioSource = external

        if best?.isPlaying == true {
            status = .connected
        } else if let external {
            // Играет что-то другое — это важнее, чем поставленный на паузу Music.
            status = .externalAudio(external)
        } else if let denied {
            status = .automationDenied(denied)
        } else if !anyRunning {
            status = .noSupportedPlayer
        } else {
            status = .connected
        }

        // Пока звук идёт из чужого приложения, поставленный на паузу трек
        // показывать нельзя: пользователь слушает не его.
        let effective = (best?.isPlaying == true || external == nil) ? best : nil

        let trackChanged = !(effective?.isSameTrack(as: nowPlaying) ?? (nowPlaying == nil))
        nowPlaying = effective
        let best = effective

        if let best, trackChanged {
            loadArtwork(for: best)
        } else if best == nil {
            loadExternalArtwork(for: external)
        }
    }

    /// Обложка для чужого источника: у браузера её можно найти по адресу
    /// открытой вкладки. Ходит в сеть, поэтому отключается в настройках.
    private func loadExternalArtwork(for source: AudioSource?) {
        guard let source, settings.fetchBrowserArtwork else {
            artwork = nil
            return
        }

        // Прямой адрес обложки от самого браузера — лучший случай:
        // ни разбора страницы, ни угадывания.
        if let artworkURL = source.artworkURL {
            artworkFetcher.image(at: artworkURL) { [weak self] image in
                guard let self, self.audioSource?.artworkURL == artworkURL else { return }
                self.artwork = image
            }
            return
        }

        guard let pageURL = source.pageURL else {
            artwork = nil
            return
        }

        artworkFetcher.artwork(for: pageURL) { [weak self] image in
            guard let self else { return }
            // Пока грузили — источник мог смениться.
            guard self.audioSource?.pageURL == pageURL else { return }
            self.artwork = image
        }
    }

    /// Обложка грузится только при смене трека: у Spotify это сетевой запрос,
    /// у Music — запись файла на диск, каждые две секунды такое не гоняют.
    private func loadArtwork(for playing: NowPlaying) {
        let client = MusicSourceClient(source: playing.source)

        queue.async { [weak self] in
            let data = client.artwork()

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Пока грузили — трек мог смениться. Сверяем источник
                    // и trackID вместе, как и `NowPlaying.isSameTrack(as:)` —
                    // одного trackID недостаточно, если он вообще когда-нибудь
                    // совпадёт между Music и Spotify (числовой ID против
                    // строкового URI Spotify практически исключено, но
                    // сверка по одному полю уже была бы неполной сама по себе).
                    guard self.nowPlaying?.isSameTrack(as: playing) == true else { return }
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
        requestMediaKeyPermissionIfNeeded()
        let source = nowPlaying?.source
        Log.media.debug("команда \(String(describing: command), privacy: .public), источник \(source?.rawValue ?? "нет", privacy: .public)")

        queue.async { [weak self] in
            var handled = false
            if let source {
                handled = MusicSourceClient(source: source).send(command)
            }
            if !handled {
                let keyResult = fallback()
                Log.media.debug("медиа-клавиша отправлена: \(keyResult, privacy: .public) (разрешение: \(MediaKeys.isAuthorized, privacy: .public))")
            }

            // Плеер отвечает на команду не мгновенно.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// Управление доступно только через медиа-клавиши, а разрешения на них нет.
    var needsMediaKeyPermission: Bool {
        nowPlaying == nil && !MediaKeys.isAuthorized
    }

    /// Просит разрешение на медиа-клавиши. Вызывается по нажатию кнопки,
    /// а не при запуске: выпрашивать доступ на пустом месте незачем.
    /// Диалог показывается один раз за запуск.
    func requestMediaKeyPermissionIfNeeded() {
        guard needsMediaKeyPermission else { return }
        MediaKeys.requestAuthorizationOnce()
    }
}
