import Foundation

/// Источник музыки.
public enum MusicSource: String, Sendable, Equatable, CaseIterable {
    case appleMusic
    case spotify

    public var bundleID: String {
        switch self {
        case .appleMusic: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    public var displayName: String {
        switch self {
        case .appleMusic: return "Music"
        case .spotify: return "Spotify"
        }
    }
}

/// Что играет прямо сейчас.
public struct NowPlaying: Sendable, Equatable {
    public let source: MusicSource
    public let trackID: String
    public let title: String
    public let artist: String
    public let album: String
    public let isPlaying: Bool
    public let duration: TimeInterval
    /// Позиция на момент замера.
    public let position: TimeInterval
    /// Монотонная метка замера — по ней позиция достраивается между опросами.
    public let sampledAt: TimeInterval

    public init(
        source: MusicSource,
        trackID: String,
        title: String,
        artist: String,
        album: String,
        isPlaying: Bool,
        duration: TimeInterval,
        position: TimeInterval,
        sampledAt: TimeInterval
    ) {
        self.source = source
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.duration = duration
        self.position = position
        self.sampledAt = sampledAt
    }

    /// Позиция, достроенная до текущего момента.
    ///
    /// Опрашивать плеер каждую долю секунды ради ползущей полоски —
    /// расточительно: пока идёт воспроизведение, позиция предсказуема,
    /// и между опросами её достаточно досчитать по часам.
    public func position(at now: TimeInterval) -> TimeInterval {
        guard isPlaying else { return clamp(position) }
        let elapsed = max(0, now - sampledAt)
        return clamp(position + elapsed)
    }

    public func progress(at now: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(position(at: now) / duration, 0), 1)
    }

    private func clamp(_ value: TimeInterval) -> TimeInterval {
        guard duration > 0 else { return max(0, value) }
        return min(max(value, 0), duration)
    }

    /// Один и тот же трек, даже если позиция уехала.
    public func isSameTrack(as other: NowPlaying?) -> Bool {
        guard let other else { return false }
        return other.source == source && other.trackID == trackID
    }
}

public enum NowPlayingSelection {
    /// Выбирает, что показывать, когда отвечают несколько плееров.
    ///
    /// Играющий всегда важнее поставленного на паузу: если Spotify играет,
    /// а в Music открыт трек на паузе — пользователь слушает Spotify.
    /// Среди равных берём самый свежий замер.
    public static func best(from candidates: [NowPlaying]) -> NowPlaying? {
        let playing = candidates.filter(\.isPlaying)
        let pool = playing.isEmpty ? candidates : playing
        return pool.max { $0.sampledAt < $1.sampledAt }
    }
}

public enum TimeFormatting {
    /// Время трека в привычном виде: 3:07, 1:02:33.
    public static func trackTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }

        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
