import Foundation

/// Errors surfaced by the update pipeline.
public enum UpdateError: LocalizedError, Equatable {
    case badResponse(Int)

    public var errorDescription: String? {
        switch self {
        case let .badResponse(code):
            return "GitHub returned an unexpected response (HTTP \(code))."
        }
    }
}

/// Fetches the latest published release. Abstracted so tests can stub it.
public protocol ReleaseChecking: Sendable {
    func latestRelease() async throws -> GitHubRelease
}

/// Queries VagrantBar's latest GitHub release, unauthenticated.
/// `releases/latest` already excludes drafts and pre-releases.
public struct GitHubReleaseService: ReleaseChecking {
    public static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/kloostermanw/vagrant-bar/releases/latest")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func latestRelease() async throws -> GitHubRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw UpdateError.badResponse(status) }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }
}
