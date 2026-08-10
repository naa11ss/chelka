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
    private struct CacheEntry {
        let image: NSImage?
        let cachedAt: Date
    }
    private var cache: [String: CacheEntry] = [:]
    private var inFlight = Set<String>()
    private let lock = NSLock()

    /// Разметки страниц бывают огромными: og:image лежит в самом начале,
    /// качать мегабайты ради него не нужно.
    private static let maxPageBytes = 512 * 1024
    private static let maxImageBytes = 4 * 1024 * 1024
    /// Успешно найденная обложка кэшируется, пока не вытеснится по объёму —
    /// картинка по тому же адресу не появится другой. Отказ — совсем другое
    /// дело: единственный сетевой сбой (обрыв, таймаут) иначе "отравлял" бы
    /// адрес навсегда, пока не накопится 40 других адресов и кэш не сотрётся
    /// целиком, — тот же принцип backoff, что уже применён в `BrowserTabTitle`
    /// и `BrowserMediaSession`, просто с более коротким сроком: здесь нет
    /// сигнала о разрешениях, только временный сетевой сбой.
    private static let negativeCacheTTL: TimeInterval = 120

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
        if let entry = cache[key], entry.image != nil || Date().timeIntervalSince(entry.cachedAt) < Self.negativeCacheTTL {
            lock.unlock()
            DispatchQueue.main.async { completion(entry.image) }
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
            self.cache[key] = CacheEntry(image: image, cachedAt: Date())
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
        if let entry = cache[key], entry.image != nil || Date().timeIntervalSince(entry.cachedAt) < Self.negativeCacheTTL {
            lock.unlock()
            DispatchQueue.main.async { completion(entry.image) }
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
            self.cache[key] = CacheEntry(image: image, cachedAt: Date())
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

    /// Загрузки, у которых сейчас есть собственный делегат — держим их живыми
    /// до завершения задачи, иначе делегат освободился бы раньше отклика.
    private var activeDownloads: [ObjectIdentifier: SizeLimitedDownload] = [:]

    /// `dataTask(with:completionHandler:)` буферизует весь ответ целиком,
    /// прежде чем передать управление замыканию — проверка `data.count <= limit`
    /// после этого не ограничивает ни память, ни трафик, а только решает,
    /// использовать ли то, что уже целиком скачано. Страница (или недобросовестный
    /// сервер), ответившая мегабайтами HTML в пределах `timeoutIntervalForResource`,
    /// была бы полностью загружена в память прежде, чем отброшена. Отдельный
    /// делегат на задачу может оборвать закачку в момент превышения лимита —
    /// это и есть настоящая защита, а не только видимость её.
    private func load(_ url: URL, limit: Int, completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue("Chelka", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request)
        let delegate = SizeLimitedDownload(limit: limit) { [weak self] data in
            completion(data)
            self?.lock.lock()
            self?.activeDownloads.removeValue(forKey: ObjectIdentifier(task))
            self?.lock.unlock()
        }
        task.delegate = delegate

        lock.lock()
        activeDownloads[ObjectIdentifier(task)] = delegate
        lock.unlock()

        task.resume()
    }
}

/// Делегат одной закачки: копит байты, обрывает задачу, как только их
/// стало больше лимита, и отвечает `nil` вместо частично скачанных данных —
/// обрезанный кусок HTML/картинки всё равно ни на что не годен.
private final class SizeLimitedDownload: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private var buffer = Data()
    private var rejected = false
    private var onComplete: ((Data?) -> Void)?

    init(limit: Int, completion: @escaping (Data?) -> Void) {
        self.limit = limit
        self.onComplete = completion
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            rejected = true
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !rejected else { return }
        buffer.append(data)
        if buffer.count > limit {
            rejected = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            Log.media.debug("обложка не загрузилась: \(error.localizedDescription, privacy: .public)")
        }
        let result = (rejected || error != nil) ? nil : buffer
        onComplete?(result)
        onComplete = nil
    }
}
