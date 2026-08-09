import Foundation

/// Сериализация нагрузки для хранения. Пишется в базу только зашифрованной.
extension ClipboardPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, text, data, uti, paths
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(ClipboardKind.self, forKey: .kind)

        switch kind {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .image:
            self = .image(
                data: try container.decode(Data.self, forKey: .data),
                uti: try container.decode(String.self, forKey: .uti)
            )
        case .file:
            let paths = try container.decode([String].self, forKey: .paths)
            self = .files(paths.map { URL(fileURLWithPath: $0) })
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)

        switch self {
        case .text(let string):
            try container.encode(string, forKey: .text)
        case .image(let data, let uti):
            try container.encode(data, forKey: .data)
            try container.encode(uti, forKey: .uti)
        case .files(let urls):
            try container.encode(urls.map(\.path), forKey: .paths)
        }
    }
}
