import Foundation

/// Откуда взять обложку для того, что играет в браузере.
///
/// Системный Now Playing закрыт, обложку взять неоткуда — кроме самой
/// страницы. Для больших сервисов адрес картинки выводится из адреса
/// страницы без единого запроса; для остальных приходится читать
/// разметку и искать `og:image`.
public enum BrowserArtwork {

    /// Что делать с конкретной страницей.
    public enum Resolution: Sendable, Equatable {
        /// Адрес картинки известен сразу.
        case direct(URL)
        /// Нужен запрос к oEmbed-ручке сервиса.
        case oEmbed(URL)
        /// Придётся скачать страницу и поискать в ней `og:image`.
        case parsePage(URL)
    }

    public static func resolution(for pageURL: URL) -> Resolution? {
        if let thumbnail = youTubeThumbnail(for: pageURL) {
            return .direct(thumbnail)
        }
        if let oEmbed = soundCloudOEmbed(for: pageURL) {
            return .oEmbed(oEmbed)
        }
        guard let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return .parsePage(pageURL)
    }

    // MARK: - YouTube

    /// Обложка ролика выводится прямо из его идентификатора —
    /// ни запроса к странице, ни разбора разметки не нужно.
    public static func youTubeThumbnail(for pageURL: URL) -> URL? {
        guard let id = youTubeVideoID(for: pageURL) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
    }

    public static func youTubeVideoID(for pageURL: URL) -> String? {
        guard let host = pageURL.host?.lowercased() else { return nil }

        // Короткая ссылка youtu.be/<id>
        if host.hasSuffix("youtu.be") {
            let id = pageURL.lastPathComponent
            return isValidVideoID(id) ? id : nil
        }

        guard host.hasSuffix("youtube.com") else { return nil }

        // Обычная ссылка youtube.com/watch?v=<id>
        if let components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false),
           let id = components.queryItems?.first(where: { $0.name == "v" })?.value,
           isValidVideoID(id) {
            return id
        }

        // Короткие ролики и встраивания: /shorts/<id>, /embed/<id>
        let parts = pageURL.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, ["shorts", "embed", "live"].contains(parts[0]), isValidVideoID(parts[1]) {
            return parts[1]
        }

        return nil
    }

    private static func isValidVideoID(_ id: String) -> Bool {
        guard id.count >= 8, id.count <= 20 else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // MARK: - SoundCloud

    /// У SoundCloud идентификатор трека в адресе не лежит, зато есть
    /// открытая ручка oEmbed, отдающая ссылку на обложку.
    public static func soundCloudOEmbed(for pageURL: URL) -> URL? {
        guard let host = pageURL.host?.lowercased(), host.hasSuffix("soundcloud.com") else { return nil }
        // Лента и профиль трека не содержат — обложке взяться неоткуда.
        guard pageURL.pathComponents.filter({ $0 != "/" }).count >= 2 else { return nil }

        // Кодируем адрес вручную: URLComponents оставляет «:» и «/» как есть,
        // и не всякая ручка это переваривает.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")

        guard let encoded = pageURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "https://soundcloud.com/oembed?format=json&url=\(encoded)")
    }

    /// Достаёт `thumbnail_url` из ответа oEmbed.
    public static func thumbnailURL(fromOEmbed data: Data) -> URL? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let string = object["thumbnail_url"] as? String
        else { return nil }
        return URL(string: string)
    }

    // MARK: - Разметка страницы

    /// Ищет `og:image` в разметке. Порядок атрибутов у всех разный,
    /// поэтому ищем оба варианта написания.
    public static func ogImage(inHTML html: String, pageURL: URL) -> URL? {
        let patterns = [
            #"<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:image["']"#,
            #"<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)

            guard let match = regex.firstMatch(in: html, options: [], range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: html)
            else { continue }

            let value = String(html[valueRange])
            if let url = URL(string: value), url.scheme != nil { return url }
            // Относительный адрес — достраиваем от страницы.
            if let url = URL(string: value, relativeTo: pageURL)?.absoluteURL { return url }
        }

        return nil
    }
}
