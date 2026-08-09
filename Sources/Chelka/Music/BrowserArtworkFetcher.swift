import AppKit
import ChelkaCore

/// Достаёт обложку для того, что играет в браузере.
///
/// Ходит в сеть, поэтому: только по адресу открытой вкладки, с жёсткими
/// ограничениями по времени и размеру, с кэшем по адресу страницы —
/// опрос идёт каждые две секунды, и качать одно и то же незачем.
/// Отключается в настройках.
final class BrowserArtworkFetcher {

    private let session: URLSession
    private var cache: [String: NSImage?] = [:]
    private var inFlight = Set<String>()
    private let lock = NSLock()

    /// Разметки страниц бывают огромными: og:image лежит в самом начале,
    /// качать мегабайты ради него не нужно.
    private static let maxPageBytes = 512 * 1024
    private static let maxImageBytes = 4 * 1024 * 1024

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.httpMaximumConnectionsPerHost = 2
        // Куки и кэш нам не нужны: приложение не должно оставлять следов
        // и не должно ходить в сеть под учётной записью пользователя.
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration)
    }

    /// Обложка для страницы. `completion` вызывается на главной очереди.
    func artwork(for pageURL: URL, completion: @escaping (NSImage?) -> Void) {
        let key = pageURL.absoluteString

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            DispatchQueue.main.async { completion(cached) }
            return
        }
        guard !inFlight.contains(key) else {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        lock.unlock()

        resolve(pageURL) { [weak self] image in
            guard let self else { return }

            self.lock.lock()
            self.cache[key] = image
            self.inFlight.remove(key)
            // Кэш не должен расти бесконечно: вкладок за день бывают сотни.
            if self.cache.count > 40 { self.cache.removeAll() }
            self.lock.unlock()

            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Загружает картинку по готовому адресу — когда его сообщил браузер.
    func image(at url: URL, completion: @escaping (NSImage?) -> Void) {
        let key = url.absoluteString

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            DispatchQueue.main.async { completion(cached) }
            return
        }
        guard !inFlight.contains(key) else {
            lock.unlock()
            return
        }
        inFlight.insert(key)
        lock.unlock()

        loadImage(url) { [weak self] image in
            guard let self else { return }
            self.lock.lock()
            self.cache[key] = image
            self.inFlight.remove(key)
            if self.cache.count > 40 { self.cache.removeAll() }
            self.lock.unlock()

            DispatchQueue.main.async { completion(image) }
        }
    }

    // MARK: - Разрешение адреса

    private func resolve(_ pageURL: URL, completion: @escaping (NSImage?) -> Void) {
        guard let resolution = BrowserArtwork.resolution(for: pageURL) else {
            completion(nil)
            return
        }

        switch resolution {
        case .direct(let imageURL):
            loadImage(imageURL, completion: completion)

        case .oEmbed(let endpoint):
            load(endpoint, limit: Self.maxPageBytes) { [weak self] data in
                guard let data, let imageURL = BrowserArtwork.thumbnailURL(fromOEmbed: data) else {
                    completion(nil)
                    return
                }
                self?.loadImage(imageURL, completion: completion)
            }

        case .parsePage(let url):
            load(url, limit: Self.maxPageBytes) { [weak self] data in
                guard let data,
                      let html = String(data: data, encoding: .utf8),
                      let imageURL = BrowserArtwork.ogImage(inHTML: html, pageURL: url)
                else {
                    completion(nil)
                    return
                }
                self?.loadImage(imageURL, completion: completion)
            }
        }
    }

    private func loadImage(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        load(url, limit: Self.maxImageBytes) { data in
            guard let data, let image = NSImage(data: data) else {
                completion(nil)
                return
            }
            completion(image)
        }
    }

    private func load(_ url: URL, limit: Int, completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("Chelka", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { data, response, error in
            if let error {
                Log.media.debug("обложка не загрузилась: \(error.localizedDescription, privacy: .public)")
                completion(nil)
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                completion(nil)
                return
            }
            guard let data, data.count <= limit else {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }
}
