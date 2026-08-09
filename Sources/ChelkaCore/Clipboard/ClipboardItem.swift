import Foundation

/// Тип записи в истории.
public enum ClipboardKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case file
}

/// Полезная нагрузка записи. Хранится зашифрованной, в открытом виде
/// существует только в памяти и только пока нужна интерфейсу.
public enum ClipboardPayload: Sendable, Equatable {
    case text(String)
    /// Данные картинки в исходном формате (PNG/TIFF/JPEG) + UTI.
    case image(data: Data, uti: String)
    /// Ссылки на файлы: сами файлы не копируются, хранится только путь.
    case files([URL])

    public var kind: ClipboardKind {
        switch self {
        case .text: return .text
        case .image: return .image
        case .files: return .file
        }
    }

    /// Байты, по которым считается хэш дедупликации.
    public var hashableBytes: Data {
        switch self {
        case .text(let string):
            return Data(string.utf8)
        case .image(let data, _):
            return data
        case .files(let urls):
            return Data(urls.map(\.path).joined(separator: "\n").utf8)
        }
    }

    public var byteSize: Int {
        switch self {
        case .text(let string): return string.utf8.count
        case .image(let data, _): return data.count
        case .files(let urls): return urls.reduce(0) { $0 + $1.path.utf8.count }
        }
    }
}

/// Запись истории без полезной нагрузки: то, что нужно списку в интерфейсе.
/// Нагрузка подтягивается по требованию — иначе десять скриншотов
/// висели бы в памяти постоянно.
public struct ClipboardItem: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let kind: ClipboardKind
    public var createdAt: Date
    public var isPinned: Bool

    /// Ключ дедупликации: HMAC содержимого. Открытый текст по нему не восстановить.
    public let contentKey: String

    /// Короткая строка для списка: начало текста, имя файла, размер картинки.
    public let preview: String

    /// Дополнительная строка: домен ссылки, расширение файла, формат картинки.
    public let subtitle: String?

    /// Bundle ID приложения, из которого скопировано.
    public let sourceApp: String?

    public let byteSize: Int

    /// Размеры картинки в точках — чтобы список не декодировал данные ради подписи.
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        id: UUID = UUID(),
        kind: ClipboardKind,
        createdAt: Date,
        isPinned: Bool = false,
        contentKey: String,
        preview: String,
        subtitle: String? = nil,
        sourceApp: String? = nil,
        byteSize: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.isPinned = isPinned
        self.contentKey = contentKey
        self.preview = preview
        self.subtitle = subtitle
        self.sourceApp = sourceApp
        self.byteSize = byteSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}
