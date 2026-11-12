import Foundation

/// The subset of a GitHub `/releases/latest` payload the updater needs.
public struct GitHubRelease: Equatable, Sendable, Decodable {
    public let tagName: String
    public let name: String
    public let body: String
    public let htmlURL: URL
    /// The first asset whose name ends in `.dmg`, if any.
    public let dmgAsset: Asset?

    public struct Asset: Equatable, Sendable {
        public let name: String
        public let downloadURL: URL
    }

    public var version: AppVersion { AppVersion(tagName) }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, body
        case htmlURL = "html_url"
        case assets
    }

    private struct AssetDTO: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? tagName
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        htmlURL = try c.decode(URL.self, forKey: .htmlURL)
        let assets = try c.decodeIfPresent([AssetDTO].self, forKey: .assets) ?? []
        dmgAsset = assets
            .first { $0.name.lowercased().hasSuffix(".dmg") }
            .map { Asset(name: $0.name, downloadURL: $0.browserDownloadURL) }
    }
}
