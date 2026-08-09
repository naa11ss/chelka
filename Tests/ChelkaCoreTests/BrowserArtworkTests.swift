import Foundation
import Testing

@testable import ChelkaCore

private func url(_ string: String) -> URL { URL(string: string)! }

@Suite("Обложка из браузера")
struct BrowserArtworkTests {

    @Test("Идентификатор ролика YouTube достаётся из обычной ссылки")
    func youTubeWatchLink() {
        let id = BrowserArtwork.youTubeVideoID(for: url("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s"))
        #expect(id == "dQw4w9WgXcQ")
    }

    @Test("Короткая ссылка и shorts тоже понимаются")
    func youTubeShortLinks() {
        #expect(BrowserArtwork.youTubeVideoID(for: url("https://youtu.be/dQw4w9WgXcQ")) == "dQw4w9WgXcQ")
        #expect(BrowserArtwork.youTubeVideoID(for: url("https://www.youtube.com/shorts/abcdefgh123")) == "abcdefgh123")
        #expect(BrowserArtwork.youTubeVideoID(for: url("https://www.youtube.com/embed/dQw4w9WgXcQ")) == "dQw4w9WgXcQ")
    }

    @Test("Ссылки не на ролик идентификатора не дают")
    func youTubeNonVideoLinks() {
        #expect(BrowserArtwork.youTubeVideoID(for: url("https://www.youtube.com/")) == nil)
        #expect(BrowserArtwork.youTubeVideoID(for: url("https://www.youtube.com/feed/subscriptions")) == nil)
        #expect(BrowserArtwork.youTubeVideoID(for: url("https://example.com/watch?v=dQw4w9WgXcQ")) == nil)
    }

    @Test("Мусор вместо идентификатора отбрасывается")
    func youTubeRejectsGarbageID() {
        #expect(BrowserArtwork.youTubeVideoID(for: url("https://youtu.be/x")) == nil)
        #expect(BrowserArtwork.youTubeVideoID(for: url("https://www.youtube.com/watch?v=../../etc/passwd")) == nil)
    }

    @Test("Для ролика адрес обложки известен сразу, без запросов")
    func youTubeResolvesDirectly() {
        let resolution = BrowserArtwork.resolution(for: url("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))

        guard case .direct(let thumbnail)? = resolution else {
            Issue.record("ожидался прямой адрес, получено \(String(describing: resolution))")
            return
        }
        #expect(thumbnail.absoluteString.contains("dQw4w9WgXcQ"))
    }

    @Test("Трек SoundCloud уходит в oEmbed")
    func soundCloudUsesOEmbed() {
        let page = url("https://soundcloud.com/plohoyparen/samosval")
        let resolution = BrowserArtwork.resolution(for: page)

        guard case .oEmbed(let endpoint)? = resolution else {
            Issue.record("ожидался oEmbed, получено \(String(describing: resolution))")
            return
        }
        #expect(endpoint.absoluteString.hasPrefix("https://soundcloud.com/oembed"))
        #expect(endpoint.absoluteString.contains("soundcloud.com%2Fplohoyparen%2Fsamosval"))
        #expect(!endpoint.absoluteString.contains("url=https://"))
    }

    @Test("Лента SoundCloud обложки не имеет")
    func soundCloudFeedHasNoArtwork() {
        let resolution = BrowserArtwork.resolution(for: url("https://soundcloud.com/discover"))
        // Одного сегмента пути мало для трека — идём общим путём.
        if case .oEmbed = resolution {
            Issue.record("лента не должна уходить в oEmbed")
        }
    }

    @Test("Ответ oEmbed разбирается")
    func parsesOEmbedResponse() {
        let json = #"{"title":"трек","thumbnail_url":"https://i1.sndcdn.com/artworks-abc-t500x500.jpg"}"#
        let thumbnail = BrowserArtwork.thumbnailURL(fromOEmbed: Data(json.utf8))

        #expect(thumbnail?.absoluteString == "https://i1.sndcdn.com/artworks-abc-t500x500.jpg")
    }

    @Test("Битый ответ oEmbed ничего не ломает")
    func brokenOEmbedIsSafe() {
        #expect(BrowserArtwork.thumbnailURL(fromOEmbed: Data("не json".utf8)) == nil)
        #expect(BrowserArtwork.thumbnailURL(fromOEmbed: Data(#"{"title":"без обложки"}"#.utf8)) == nil)
    }

    @Test("og:image находится независимо от порядка атрибутов")
    func findsOGImageEitherOrder() {
        let page = url("https://example.com/track")

        let direct = #"<meta property="og:image" content="https://cdn.example.com/a.jpg">"#
        #expect(BrowserArtwork.ogImage(inHTML: direct, pageURL: page)?.absoluteString == "https://cdn.example.com/a.jpg")

        let reversed = #"<meta content="https://cdn.example.com/b.jpg" property="og:image"/>"#
        #expect(BrowserArtwork.ogImage(inHTML: reversed, pageURL: page)?.absoluteString == "https://cdn.example.com/b.jpg")
    }

    @Test("Относительный адрес обложки достраивается от страницы")
    func resolvesRelativeArtwork() {
        let page = url("https://example.com/music/track")
        let html = #"<meta property="og:image" content="/covers/1.png">"#

        #expect(BrowserArtwork.ogImage(inHTML: html, pageURL: page)?.absoluteString == "https://example.com/covers/1.png")
    }

    @Test("Страница без обложки не выдумывает адрес")
    func noArtworkMeansNil() {
        let html = "<html><head><title>ничего</title></head></html>"
        #expect(BrowserArtwork.ogImage(inHTML: html, pageURL: url("https://example.com")) == nil)
    }

    @Test("Не-веб адреса вообще не рассматриваются")
    func ignoresNonWebURLs() {
        #expect(BrowserArtwork.resolution(for: url("file:///Users/me/video.mp4")) == nil)
        #expect(BrowserArtwork.resolution(for: url("about:blank")) == nil)
    }
}
